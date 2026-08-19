terraform {
  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}
