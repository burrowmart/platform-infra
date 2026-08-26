output "backend" {
  description = "Which store the secrets landed in. Set as the External Secrets ClusterSecretStore's `service` field: ssm -> ParameterStore, secretsmanager -> SecretsManager."
  value       = var.backend
}

output "secret_arns" {
  description = "Map of '<service>/<key>' -> ARN, whichever backend is active."
  value = merge(
    { for k, s in aws_secretsmanager_secret.this : k => s.arn },
    { for k, p in aws_ssm_parameter.this : k => p.arn },
  )
}

output "service_secret_path_prefixes" {
  description = "Map of service -> the path prefix its secrets live under. The irsa module's read policy is scoped to this same '<prefix>/<service>/*' pattern."
  value = {
    for svc in var.services :
    svc => var.backend == "ssm" ? "/${var.secrets_prefix}/${svc}/" : "${var.secrets_prefix}/${svc}/"
  }
}
