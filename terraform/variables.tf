# ---------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region hosting the EKS cluster and every resource in this tree."
  type        = string
}

variable "aws_account_id" {
  description = <<-EOT
    AWS account ID that owns the EKS cluster. Pinned explicitly (rather than
    read via a data source) so an `apply` fails fast against the wrong
    account instead of silently succeeding in it.
  EOT
  type        = string
}

variable "aws_partition" {
  description = "AWS partition (aws, aws-us-gov, aws-cn). Only override outside the standard partition."
  type        = string
  default     = "aws"
}

variable "tags" {
  description = "Common tags applied to every taggable resource in this tree."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# EKS (existing cluster — looked up, never created here)
# ---------------------------------------------------------------------------

variable "eks_cluster_name" {
  description = "Name of the pre-existing EKS cluster this tree wires infra around."
  type        = string
}

# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the tunnel and DNS zone."
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (Tunnel:Edit, DNS:Edit on the target zone). Never a Global API Key."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Zone ID for the domain the public hostnames live under."
  type        = string
}

variable "base_domain" {
  description = "Base domain suffix for every public hostname routed through the tunnel."
  type        = string
  default     = "internal.archtenet.com"
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel."
  type        = string
  default     = "archtenet-internal"
}

variable "cloudflared_image" {
  description = "cloudflared container image. Pin to a digest (not a tag) before running this in production."
  type        = string
  default     = "cloudflare/cloudflared:2025.8.0"
}

variable "public_routes" {
  description = <<-EOT
    Public hostname -> in-cluster route. Every entry becomes a cloudflared
    ingress rule (all forwarding to the internal nginx ingress controller,
    which does the actual host/path -> Service routing) and a DNS CNAME to
    the tunnel. This is the ONLY way traffic reaches the cluster.
  EOT
  type = map(object({
    hostname = string
  }))
  default = {
    user-bff             = { hostname = "user-bff.internal.archtenet.com" }
    catalog-bff          = { hostname = "catalog-bff.internal.archtenet.com" }
    order-bff            = { hostname = "order-bff.internal.archtenet.com" }
    cart-bff             = { hostname = "cart-bff.internal.archtenet.com" }
    payment-bff          = { hostname = "payment-bff.internal.archtenet.com" }
    ws-gateway           = { hostname = "ws-gateway.internal.archtenet.com" }
    notification-service = { hostname = "notification-service.internal.archtenet.com" }
  }
}

# ---------------------------------------------------------------------------
# Internal ingress (ingress-nginx)
# ---------------------------------------------------------------------------

variable "ingress_namespace" {
  description = "Namespace the internal ingress-nginx release is installed into."
  type        = string
  default     = "ingress"
}

variable "ingress_class_name" {
  description = "IngressClass name every service's per-service Ingress resource targets."
  type        = string
  default     = "nginx-internal"
}

# ---------------------------------------------------------------------------
# GitHub OIDC (CI auth)
# ---------------------------------------------------------------------------

variable "github_owner" {
  description = "GitHub org/user that owns every service repo."
  type        = string
}

variable "github_repo_patterns" {
  description = "Repo patterns (as GitHub OIDC `sub` subjects) allowed to assume the deploy role. Defaults to every repo under github_owner on main."
  type        = list(string)
  default     = null
}

# ---------------------------------------------------------------------------
# Per-service domain services (IRSA + Secrets Manager)
# ---------------------------------------------------------------------------

variable "domain_services" {
  description = "Every service that gets an IRSA role + Secrets Manager entries. Namespace defaults to the service name."
  type = map(object({
    namespace = string
  }))
  default = {
    user-service         = { namespace = "user-service" }
    catalog-service      = { namespace = "catalog-service" }
    order-service        = { namespace = "order-service" }
    payment-service      = { namespace = "payment-service" }
    notification-service = { namespace = "notification-service" }
    chat-service         = { namespace = "chat-service" }
    user-bff             = { namespace = "user-bff" }
    catalog-bff          = { namespace = "catalog-bff" }
    order-bff            = { namespace = "order-bff" }
    cart-bff             = { namespace = "cart-bff" }
    payment-bff          = { namespace = "payment-bff" }
    ws-gateway           = { namespace = "ws-gateway" }
  }
}

variable "secrets_prefix" {
  description = "Secrets Manager path prefix. Entries land at <prefix>/<service>/<key>; IRSA read policies are scoped to <prefix>/<service>/*."
  type        = string
  default     = "svc"
}

variable "secret_values" {
  description = <<-EOT
    Per-service secret values, keyed by service then by
    mongo-uri|rabbit-url|redis-url|cognito-issuer|cognito-audience. Populate
    via a gitignored *.auto.tfvars file or TF_VAR_secret_values — never
    commit real values, and never add them here as literal defaults.
  EOT
  type        = map(map(string))
  sensitive   = true
  default     = {}
}

# ---------------------------------------------------------------------------
# OPA bundle bucket
# ---------------------------------------------------------------------------

variable "opa_bundle_bucket_name" {
  description = "Globally-unique S3 bucket name for OPA policy bundles."
  type        = string
}

variable "opa_policies_repo" {
  description = "owner/repo for the opa-policies CI writer role. Defaults to <github_owner>/opa-policies."
  type        = string
  default     = null
}

variable "opa_namespace" {
  description = "Namespace the OPA PDP DaemonSet runs in."
  type        = string
  default     = "opa-system"
}

variable "opa_service_account" {
  description = "ServiceAccount name the OPA PDP DaemonSet runs as (IRSA-annotated)."
  type        = string
  default     = "opa-pdp"
}
