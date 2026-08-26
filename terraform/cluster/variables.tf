# ---------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "Region the cluster instance and every resource in this root lives in."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID. Pinned explicitly so an apply fails fast against the wrong account."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every taggable resource."
  type        = map(string)
  default = {
    Project   = "archtenet"
    ManagedBy = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Cluster identity
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name for the cluster. Used as the resource name prefix and in the SSM parameter paths."
  type        = string
  default     = "archtenet-demo"
}

variable "k3s_version" {
  description = <<-EOT
    k3s release to install (INSTALL_K3S_VERSION). Pinned so a rebuilt
    instance lands on the same Kubernetes version — the '+k3s1' suffix is
    part of the tag. v1.29.x matches the version the eksctl command this
    replaced was pinning.
  EOT
  type        = string
  default     = "v1.29.15+k3s1"
}

# ---------------------------------------------------------------------------
# Compute — the entire cost story lives here
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = <<-EOT
    Single-node instance type. t3.large (8 GiB) is the default because the
    full stack — 12 services, each with an Envoy PEP sidecar, plus Mongo,
    Redis, RabbitMQ, OPA, ingress-nginx and cloudflared — does not fit in
    4 GiB. Drop to t3.medium (~half the price) only if you scale replicas
    to 1 and skip the observability stack.

    Stay on x86 (t3.*): the service CI builds linux/amd64 images only. A
    Graviton type (t4g.*) is ~15% cheaper but needs `platforms:
    linux/amd64,linux/arm64` added to the docker/build-push-action step in
    every service first.
  EOT
  type        = string
  default     = "t3.large"
}

variable "use_spot" {
  description = <<-EOT
    Run the node as a Spot instance (~70% off on-demand). Interruption
    behaviour is 'stop', not 'terminate', and the request is persistent —
    AWS stops the box when capacity is reclaimed and starts it again when
    capacity returns, so the EBS root volume (and therefore all cluster
    state) survives. Set false if a demo must not be interrupted mid-run.
  EOT
  type        = bool
  default     = true
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. Holds the OS, every container image, and all local-path PVC data (Mongo/Redis/RabbitMQ)."
  type        = number
  default     = 40
}

variable "vpc_cidr" {
  description = "CIDR for the demo VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "api_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API on 6443 directly. Defaults to
    EMPTY — the security group has no inbound rules at all, and API access
    goes through an SSM Session Manager port-forward instead (`make tunnel`).
    That keeps the "no public inbound" property the architecture claims.
    Only populate this if you specifically want to bypass the tunnel.
  EOT
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# IRSA-over-OIDC
# ---------------------------------------------------------------------------

variable "oidc_bucket_name" {
  description = <<-EOT
    Globally-unique S3 bucket name hosting the cluster's OIDC discovery
    document and JWKS. This bucket is PUBLICLY READABLE by design — it
    contains only the API server's public signing key, exactly like the
    EKS-managed OIDC endpoint it stands in for. Leave null to derive
    '<cluster_name>-oidc-<random suffix>'.
  EOT
  type        = string
  default     = null
}
