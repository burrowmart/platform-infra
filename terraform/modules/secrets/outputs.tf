output "secret_arns" {
  description = "Map of '<service>/<key>' -> Secrets Manager secret ARN."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}

output "service_secret_path_prefixes" {
  description = "Map of service -> the Secrets Manager path prefix its secrets live under. The irsa module's read policy is scoped to this same '<prefix>/<service>/*' pattern."
  value = {
    for svc in var.services :
    svc => "${var.secrets_prefix}/${svc}/"
  }
}
