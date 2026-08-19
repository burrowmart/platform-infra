output "role_arns" {
  description = "Map of service name -> IRSA role ARN. Feed into each service's Helm values as irsaRoleArn."
  value       = { for name, role in aws_iam_role.this : name => role.arn }
}

output "service_accounts" {
  description = "Map of service name -> the ServiceAccount name its trust policy is scoped to."
  value       = local.service_accounts
}
