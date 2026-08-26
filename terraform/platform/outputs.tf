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

# ---------------------------------------------------------------------------
# GitHub Actions repository variables.
#
# Set all four on every service repo (Settings -> Secrets and variables ->
# Actions -> Variables). service-ci.yml's deploy job reads them to assume the
# role, fetch the kubeconfig, and open the port-forward to the API server.
# ---------------------------------------------------------------------------

output "github_deploy_role_arns" {
  description = "Repository variable AWS_DEPLOY_ROLE_ARN, per matching repo pattern."
  value       = module.github_oidc.deploy_role_arns
}

output "github_actions_variables" {
  description = "The repo variables that are the same for every service repo: AWS_REGION, KUBECONFIG_PARAM, K3S_INSTANCE_ID."
  value = {
    AWS_REGION       = var.aws_region
    KUBECONFIG_PARAM = data.terraform_remote_state.cluster.outputs.kubeconfig_parameter_name
    K3S_INSTANCE_ID  = local.cluster_instance_id
  }
}

output "irsa_role_arns" {
  description = "Set as irsaRoleArn in each service's Helm values."
  value       = module.irsa.role_arns
}

output "secret_arns" {
  value = module.secrets.secret_arns
}

output "secrets_backend" {
  description = "Which store the service secrets landed in. The External Secrets ClusterSecretStore must be configured for the same one: ssm -> service: ParameterStore, secretsmanager -> service: SecretsManager."
  value       = module.secrets.backend
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
