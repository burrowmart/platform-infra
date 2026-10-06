variable "bucket_name" {
  description = "Globally-unique S3 bucket name for Loki's log chunks and TSDB index."
  type        = string
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete a non-empty bucket. Leave false outside throwaway/demo environments."
  type        = bool
  default     = false
}

variable "expiration_days" {
  description = "Lifecycle backstop, in days. MUST stay longer than Loki's limits_config.retention_period (14d in k8s/observability/loki/loki-config.yaml) — a shorter value deletes chunks the index still references."
  type        = number
  default     = 30

  validation {
    condition     = var.expiration_days >= 21
    error_message = "expiration_days must leave a margin over Loki's 14-day retention_period; use at least 21."
  }
}

# ---------------------------------------------------------------------------
# IRSA — the Loki pod's ServiceAccount
# ---------------------------------------------------------------------------

variable "cluster_oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC identity provider (terraform/cluster output oidc_provider_arn)."
  type        = string
}

variable "cluster_oidc_provider_url" {
  description = "Service-account token issuer URL of the cluster (terraform/cluster output oidc_provider_url)."
  type        = string
}

variable "loki_namespace" {
  description = "Namespace Loki runs in."
  type        = string
  default     = "observability"
}

variable "loki_service_account" {
  description = "ServiceAccount name Loki runs as (see k8s/observability/loki/serviceaccount.yaml)."
  type        = string
  default     = "loki"
}

variable "tags" {
  type    = map(string)
  default = {}
}
