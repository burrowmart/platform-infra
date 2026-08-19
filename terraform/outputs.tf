output "tunnel_id" {
  value = module.cloudflare_tunnel.tunnel_id
}

output "public_hostnames" {
  description = "Every public hostname routed through the tunnel — the entire public surface of the cluster."
  value       = module.cloudflare_tunnel.public_hostnames
}

output "internal_ingress_class_name" {
  value = module.internal_ingress.ingress_class_name
}

output "github_deploy_role_arns" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN repository variable in each matching service repo."
  value       = module.github_oidc.deploy_role_arns
}

output "irsa_role_arns" {
  description = "Set as irsaRoleArn in each service's Helm values."
  value       = module.irsa.role_arns
}

output "secret_arns" {
  value = module.secrets.secret_arns
}

output "opa_bundle_bucket_name" {
  value = module.opa_bundle_bucket.bucket_name
}

output "opa_bundle_writer_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN (or a dedicated variable) in the opa-policies repo's CI."
  value       = module.opa_bundle_bucket.writer_role_arn
}

output "opa_bundle_reader_role_arn" {
  description = "Set as irsaRoleArn on the OPA PDP DaemonSet's ServiceAccount."
  value       = module.opa_bundle_bucket.reader_role_arn
}
