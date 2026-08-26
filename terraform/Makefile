# ---------------------------------------------------------------------------
# archtenet demo cluster
#
# Two Terraform roots, applied in order:
#   cluster/   single-node k3s on a spot EC2 instance + the OIDC discovery
#              bucket that makes IRSA work without EKS
#   platform/  everything that runs on or around it: ingress-nginx, the
#              Cloudflare Tunnel, IRSA roles, secrets, the OPA bundle bucket
#
# platform/ talks to the API server through an SSM Session Manager
# port-forward, so the cluster needs no inbound security-group rule at all.
# `make apply` opens that tunnel for you; `make tunnel` opens it standalone
# for kubectl/helm.
# ---------------------------------------------------------------------------

SHELL := /bin/bash
# Region comes from the cluster root's own output, so nothing here has to be
# kept in sync with terraform.tfvars by hand.
REGION = $(shell cd cluster && terraform output -raw aws_region)
# After `terraform destroy` the cluster state is empty, so the output above is
# gone; fall back to the tfvars file for post-destroy checks.
REGION_FALLBACK = $(shell grep -E '^[[:space:]]*aws_region' cluster/terraform.tfvars 2>/dev/null | sed 's/.*=[[:space:]]*"\(.*\)"/\1/' | head -1)
ifeq ($(strip $(REGION_FALLBACK)),)
REGION_FALLBACK := $(AWS_REGION)
endif

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- phase 1: the cluster --------------------------------------------------

.PHONY: cluster-init
cluster-init: ## terraform init for the cluster root
	cd cluster && terraform init

.PHONY: cluster-apply
cluster-apply: ## Create the k3s node (~5 min; blocks until the API server is up)
	cd cluster && terraform apply

# --- phase 2: the platform -------------------------------------------------

.PHONY: platform-init
platform-init: ## terraform init for the platform root
	cd platform && terraform init

.PHONY: platform-apply
platform-apply: tunnel ## Install ingress, tunnel, IRSA roles and secrets (needs the SSM tunnel)
	cd platform && terraform apply

.PHONY: up
up: cluster-apply platform-apply ## Full bring-up: cluster, then platform

# --- day-to-day ------------------------------------------------------------

.PHONY: tunnel
tunnel: ## Open the SSM port-forward to the Kubernetes API on localhost:6443
	@./scripts/tunnel.sh

.PHONY: kubeconfig
kubeconfig: ## Write the cluster kubeconfig to ./kubeconfig (gitignored)
	@aws ssm get-parameter \
	  --name "$$(cd cluster && terraform output -raw kubeconfig_parameter_name)" \
	  --region "$(REGION)" \
	  --with-decryption --query Parameter.Value --output text > kubeconfig
	@chmod 600 kubeconfig
	@echo "export KUBECONFIG=$$(pwd)/kubeconfig"

.PHONY: shell
shell: ## Open a root shell on the node (Session Manager)
	aws ssm start-session --target "$$(cd cluster && terraform output -raw instance_id)" --region "$(REGION)"

.PHONY: logs
logs: ## Tail the k3s bootstrap log on the node
	aws ssm start-session --target "$$(cd cluster && terraform output -raw instance_id)" --region "$(REGION)" \
	  --document-name AWS-StartInteractiveCommand \
	  --parameters '{"command":["sudo tail -f /var/log/k3s-bootstrap.log"]}'

# --- cost control ----------------------------------------------------------

.PHONY: stop
stop: ## Stop the node between demos. Keeps all cluster state; drops the bill to EBS + EIP only.
	aws ec2 stop-instances --region "$(REGION)" --instance-ids "$$(cd cluster && terraform output -raw instance_id)"

.PHONY: start
start: ## Start the node again. k3s comes back with every workload intact.
	aws ec2 start-instances --region "$(REGION)" --instance-ids "$$(cd cluster && terraform output -raw instance_id)"

.PHONY: down
down: ## Destroy everything. Irreversible — the cluster and its data are gone.
	cd platform && terraform destroy
	cd cluster && terraform destroy
	@$(MAKE) --no-print-directory check-orphans

.PHONY: check-orphans
check-orphans: ## Verify no persistent spot request survived the destroy (it would relaunch a node)
	@echo "checking for open spot requests..."
	@aws ec2 describe-spot-instance-requests 	  --region "$(REGION_FALLBACK)" 	  --filters "Name=state,Values=open,active" 	  --query 'SpotInstanceRequests[].[SpotInstanceRequestId,State]' 	  --output text || true
	@echo "Anything listed above is still live and will relaunch a node — cancel it with:"
	@echo "  aws ec2 cancel-spot-instance-requests --spot-instance-request-ids <id>"
