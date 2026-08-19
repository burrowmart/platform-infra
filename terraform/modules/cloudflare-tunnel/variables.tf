variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the tunnel."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID the public hostnames' DNS records are created in."
  type        = string
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel."
  type        = string
}

variable "public_routes" {
  description = "Public hostname -> route. Every hostname is forwarded to the same in-cluster internal-ingress Service; nginx does the host/path -> backend Service fan-out from there."
  type = map(object({
    hostname = string
  }))
}

variable "internal_ingress_service_url" {
  description = "In-cluster URL of the internal ingress-nginx controller Service that every tunnel ingress rule forwards to."
  type        = string
  default     = "http://ingress-nginx-internal.ingress.svc"
}

variable "namespace" {
  description = "Namespace the cloudflared Deployment runs in."
  type        = string
  default     = "cloudflared"
}

variable "replica_count" {
  description = "cloudflared replica count. Multiple replicas each open their own outbound connections to the edge for HA — there is still no inbound listener."
  type        = number
  default     = 3
}

variable "image" {
  description = "cloudflared container image. Pin to a digest (not a floating tag) in production."
  type        = string
}

variable "resources" {
  description = "Resource requests/limits for the cloudflared container."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "50m", memory = "64Mi" }
    limits   = { cpu = "250m", memory = "128Mi" }
  }
}
