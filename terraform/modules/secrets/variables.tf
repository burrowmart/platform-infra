variable "services" {
  description = "Services to create Secrets Manager entries for."
  type        = set(string)
}

variable "secrets_prefix" {
  description = "Path prefix. Entries land at <prefix>/<service>/<key>. Must match the irsa module's secrets_prefix — that's what its read policy is scoped to."
  type        = string
  default     = "svc"
}

variable "secret_values" {
  description = <<-EOT
    Per-service overrides, keyed by service then by
    mongo-uri|rabbit-url|redis-url|cognito-issuer|cognito-audience. Any key
    left unset falls back to a "CHANGEME" placeholder so `apply` never fails
    for missing input — set real values via a gitignored *.auto.tfvars file
    or TF_VAR_secret_values, never as a literal default in this repo.
  EOT
  type        = map(map(string))
  sensitive   = true
  default     = {}
}

variable "recovery_window_in_days" {
  description = "Secrets Manager recovery window before permanent deletion. 0 disables recovery (deletes immediately) — useful in throwaway/demo environments, never in production."
  type        = number
  default     = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
