# ---------------------------------------------------------------------------
# EKS OIDC provider — required for IRSA. The cluster itself already exists
# (see data.tf); this registers its OIDC issuer as an IAM identity provider
# so pod ServiceAccounts can assume roles. Separate from the GitHub Actions
# OIDC provider created inside modules.github_oidc.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "eks" {
  url            = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list intentionally omitted — provider-managed.
}

# ---------------------------------------------------------------------------
# Private networking — the only path into the cluster
# ---------------------------------------------------------------------------

module "internal_ingress" {
  source = "./modules/internal-ingress"

  namespace          = var.ingress_namespace
  ingress_class_name = var.ingress_class_name
}

module "cloudflare_tunnel" {
  source = "./modules/cloudflare-tunnel"

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
  source = "./modules/github-oidc"

  github_owner     = var.github_owner
  repo_patterns    = var.github_repo_patterns
  eks_cluster_name = var.eks_cluster_name
  eks_cluster_arn  = data.aws_eks_cluster.this.arn
  tags             = var.tags
}

module "irsa" {
  source = "./modules/irsa"

  oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
  oidc_provider_url = aws_iam_openid_connect_provider.eks.url
  services          = var.domain_services
  secrets_prefix    = var.secrets_prefix
  aws_region        = var.aws_region
  aws_account_id    = var.aws_account_id
  aws_partition     = var.aws_partition
  tags              = var.tags
}

module "secrets" {
  source = "./modules/secrets"

  services       = toset(keys(var.domain_services))
  secrets_prefix = var.secrets_prefix
  secret_values  = var.secret_values
  tags           = var.tags
}

module "opa_bundle_bucket" {
  source = "./modules/opa-bundle-bucket"

  bucket_name = var.opa_bundle_bucket_name

  github_oidc_provider_arn = module.github_oidc.oidc_provider_arn
  opa_policies_repo        = coalesce(var.opa_policies_repo, "${var.github_owner}/opa-policies")

  eks_oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
  eks_oidc_provider_url = aws_iam_openid_connect_provider.eks.url
  opa_namespace         = var.opa_namespace
  opa_service_account   = var.opa_service_account

  tags = var.tags
}
