variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster's IAM OIDC identity provider."
  type        = string
}

variable "oidc_provider_url" {
  description = "Issuer URL of the EKS cluster's OIDC provider (with https://), e.g. data.aws_eks_cluster.this.identity[0].oidc[0].issuer."
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
