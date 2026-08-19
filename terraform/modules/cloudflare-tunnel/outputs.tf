output "tunnel_id" {
  description = "Cloudflare Tunnel ID."
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "tunnel_cname" {
  description = "CNAME target every public hostname resolves to."
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
}

output "namespace" {
  description = "Namespace the cloudflared Deployment runs in."
  value       = kubernetes_namespace_v1.cloudflared.metadata[0].name
}

output "public_hostnames" {
  description = "Every public hostname routed through the tunnel."
  value       = [for route in var.public_routes : route.hostname]
}
