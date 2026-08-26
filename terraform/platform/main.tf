# ---------------------------------------------------------------------------
# The cluster's IAM OIDC provider is created by the ../cluster root (it has to
# be: it is registered against the k3s API server's own service-account
# signing key, published to a public S3 discovery bucket). This root just
# consumes it — see data.tf. Nothing about modules/irsa changed in the move
# off EKS; it still just needs an OIDC provider ARN and issuer URL.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Private networking — the only path into the cluster
# ---------------------------------------------------------------------------

module "internal_ingress" {
  source = "../modules/internal-ingress"

  namespace          = var.ingress_namespace
  ingress_class_name = var.ingress_class_name
}

module "cloudflare_tunnel" {
  source = "../modules/cloudflare-tunnel"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_zone_id           = var.cloudflare_zone_id
  tunnel_name                  = var.tunnel_name
  public_routes                = var.public_routes
  image                        = var.cloudflared_image
  internal_ingress_service_url = "http://${module.internal_ingress.controller_service_fqdn}"

  depends_on = [module.internal_ingress]
}

# ---------------------------------------------------------------------------
# Secrets & CI auth
# ---------------------------------------------------------------------------

module "github_oidc" {
  source = "../modules/github-oidc"

  github_owner  = var.github_owner
  repo_patterns = var.github_repo_patterns

  # CI reaches the API server the same way a human does: read the kubeconfig
  # from SSM, then port-forward 6443 over a Session Manager session. No EKS
  # access entries, no inbound security-group rule.
  cluster_instance_id       = local.cluster_instance_id
  kubeconfig_parameter_name = data.terraform_remote_state.cluster.outputs.kubeconfig_parameter_name
  aws_region                = var.aws_region
  aws_account_id            = var.aws_account_id

  tags = var.tags
}

module "irsa" {
  source = "../modules/irsa"

  oidc_provider_arn = local.cluster_oidc_provider_arn
  oidc_provider_url = local.cluster_oidc_provider_url
  services          = var.domain_services
  secrets_prefix    = var.secrets_prefix
  secrets_backend   = var.secrets_backend
  aws_region        = var.aws_region
  aws_account_id    = var.aws_account_id
  aws_partition     = var.aws_partition
  tags              = var.tags
}

module "secrets" {
  source = "../modules/secrets"

  services       = toset(keys(var.domain_services))
  secrets_prefix = var.secrets_prefix
  secret_values  = var.secret_values
  backend        = var.secrets_backend
  tags           = var.tags
}

module "opa_bundle_bucket" {
  source = "../modules/opa-bundle-bucket"

  bucket_name = var.opa_bundle_bucket_name

  github_oidc_provider_arn = module.github_oidc.oidc_provider_arn
  opa_policies_repo        = coalesce(var.opa_policies_repo, "${var.github_owner}/opa-policies")

  cluster_oidc_provider_arn = local.cluster_oidc_provider_arn
  cluster_oidc_provider_url = local.cluster_oidc_provider_url
  opa_namespace             = var.opa_namespace
  opa_service_account       = var.opa_service_account

  tags = var.tags
}
