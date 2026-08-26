# ---------------------------------------------------------------------------
# The cluster is created by the sibling `../cluster` root (a single-node k3s
# box on a spot EC2 instance). It cannot be created here: the kubernetes and
# helm providers below are configured from the cluster's kubeconfig, and
# Terraform must be able to configure a provider before it plans the
# resources that use it. Hence two roots — apply ../cluster first.
# ---------------------------------------------------------------------------
data "terraform_remote_state" "cluster" {
  backend = "local"

  config = {
    path = var.cluster_state_path
  }
}

# The kubeconfig the bootstrap script published. SecureString, so this is a
# short-lived read of an encrypted parameter rather than a checked-in file.
data "aws_ssm_parameter" "kubeconfig" {
  name            = data.terraform_remote_state.cluster.outputs.kubeconfig_parameter_name
  with_decryption = true
}

locals {
  # nonsensitive() is required to index into the decoded structure. The
  # client cert/key inside are still written to state — the same exposure
  # any Terraform-managed cluster credential has. Keep state encrypted and
  # access-restricted (see README).
  kubeconfig = yamldecode(nonsensitive(data.aws_ssm_parameter.kubeconfig.value))

  kubeconfig_cluster = local.kubeconfig.clusters[0].cluster
  kubeconfig_user    = local.kubeconfig.users[0].user

  # The published kubeconfig points at https://127.0.0.1:6443, which is
  # correct when reached through the SSM port-forward (`make tunnel`).
  # Override k8s_api_url only if you opened 6443 via api_allowed_cidrs.
  k8s_api_url = coalesce(var.k8s_api_url, local.kubeconfig_cluster.server)

  cluster_oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
  cluster_oidc_provider_url = data.terraform_remote_state.cluster.outputs.oidc_provider_url
  cluster_instance_id       = data.terraform_remote_state.cluster.outputs.instance_id
}
