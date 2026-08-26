provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# k3s issues a client certificate rather than the STS-backed bearer token EKS
# used. Both come from the same place — a short-lived read of the encrypted
# kubeconfig parameter; there is still no kubeconfig file on disk and no
# static AWS credential anywhere.
provider "kubernetes" {
  host                   = local.k8s_api_url
  cluster_ca_certificate = base64decode(local.kubeconfig_cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kubeconfig_user["client-certificate-data"])
  client_key             = base64decode(local.kubeconfig_user["client-key-data"])
}

provider "helm" {
  kubernetes = {
    host                   = local.k8s_api_url
    cluster_ca_certificate = base64decode(local.kubeconfig_cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kubeconfig_user["client-certificate-data"])
    client_key             = base64decode(local.kubeconfig_user["client-key-data"])
  }
}
