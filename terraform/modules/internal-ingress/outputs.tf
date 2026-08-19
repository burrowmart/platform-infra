output "namespace" {
  description = "Namespace ingress-nginx is installed into."
  value       = var.namespace
}

output "ingress_class_name" {
  description = "IngressClass name for per-service Ingress resources to target."
  value       = var.ingress_class_name
}

output "controller_service_fqdn" {
  description = "In-cluster FQDN of the controller Service — what the Cloudflare Tunnel forwards to."
  value       = "ingress-nginx-internal.${var.namespace}.svc.cluster.local"
}
