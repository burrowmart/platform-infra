output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider — reused by modules that need their own GitHub-trusted role (e.g. opa-bundle-bucket's writer role)."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "deploy_role_arns" {
  description = "Map of repo pattern -> deploy role ARN. Set as the AWS_DEPLOY_ROLE_ARN repository variable for every matching service repo."
  value       = { for pattern, role in aws_iam_role.deploy : pattern => role.arn }
}
