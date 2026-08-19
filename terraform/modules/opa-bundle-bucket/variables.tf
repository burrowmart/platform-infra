variable "bucket_name" {
  description = "Globally-unique S3 bucket name for OPA policy bundles."
  type        = string
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete a non-empty bucket. Leave false outside throwaway/demo environments."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Writer role — opa-policies CI, publishes bundles via GitHub OIDC
# ---------------------------------------------------------------------------

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (from the github-oidc module) — reused rather than recreated, since only one can exist per account."
  type        = string
}

variable "opa_policies_repo" {
  description = "owner/repo of the opa-policies CI writer, e.g. myorg/opa-policies."
  type        = string
}

variable "writer_allowed_ref" {
  description = "Git ref allowed to assume the writer role."
  type        = string
  default     = "refs/heads/main"
}

# ---------------------------------------------------------------------------
# Reader role — OPA PDP DaemonSet, pulls bundles via EKS IRSA
# ---------------------------------------------------------------------------

variable "eks_oidc_provider_arn" {
  description = "ARN of the EKS cluster's IAM OIDC identity provider."
  type        = string
}

variable "eks_oidc_provider_url" {
  description = "Issuer URL of the EKS cluster's OIDC provider (with https://)."
  type        = string
}

variable "opa_namespace" {
  description = "Namespace the OPA PDP DaemonSet runs in."
  type        = string
  default     = "opa-system"
}

variable "opa_service_account" {
  description = "ServiceAccount name the OPA PDP DaemonSet runs as."
  type        = string
  default     = "opa-pdp"
}

variable "tags" {
  type    = map(string)
  default = {}
}
