variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC identity provider. On EKS that is the managed one; on this k3s cluster it is registered against the API server's own signing key (terraform/cluster/oidc.tf). The module is identical either way."
  type        = string
}

variable "oidc_provider_url" {
  description = "Service-account token issuer URL (with https://) — terraform/cluster output oidc_provider_url."
  type        = string
}

variable "services" {
  description = "Service name -> the namespace/ServiceAccount its pods run as. service_account defaults to the service name (matches the base-service Helm chart's fullname)."
  type = map(object({
    namespace       = string
    service_account = optional(string)
  }))
}

variable "secrets_prefix" {
  description = "Secrets Manager path prefix. Read policy is scoped to <prefix>/<service>/*."
  type        = string
  default     = "svc"
}

variable "aws_partition" {
  type    = string
  default = "aws"
}

variable "aws_region" {
  type = string
}

variable "aws_account_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "secrets_backend" {
  description = "Must match the secrets module's `backend`: \"ssm\" or \"secretsmanager\". Determines which read permissions each IRSA role gets."
  type        = string
  default     = "ssm"

  validation {
    condition     = contains(["ssm", "secretsmanager"], var.secrets_backend)
    error_message = "secrets_backend must be \"ssm\" or \"secretsmanager\"."
  }
}
