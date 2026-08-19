# ---------------------------------------------------------------------------
# Tunnel secret — generated here so the whole credentials.json can be built
# and handed to the cluster without ever running `cloudflared tunnel login`
# or shelling out. 32 random bytes, base64 std-encoded, matches the format
# cloudflared expects for TunnelSecret.
# ---------------------------------------------------------------------------
resource "random_id" "tunnel_secret" {
  byte_length = 32
}

# cloudflare_tunnel was renamed cloudflare_zero_trust_tunnel_cloudflared
# upstream; this is the current resource for the same concept. config_src =
# "local" means cloudflared reads its ingress rules from the config file we
# mount below (localConfig.ingress), not from Cloudflare-managed remote
# config — so no cloudflare_zero_trust_tunnel_cloudflared_config resource.
resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id    = var.cloudflare_account_id
  name          = var.tunnel_name
  config_src    = "local"
  tunnel_secret = random_id.tunnel_secret.b64_std
}

# One CNAME per public hostname -> the tunnel. Proxied through Cloudflare's
# edge, which is what makes the tunnel reachable without any public listener
# on our side.
resource "cloudflare_dns_record" "public" {
  for_each = var.public_routes

  zone_id = var.cloudflare_zone_id
  name    = each.value.hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # required by the API when proxied = true (Cloudflare manages actual TTL)
}

resource "kubernetes_namespace_v1" "cloudflared" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "cloudflared"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# credentials.json for the tunnel, built entirely from values already known
# to Terraform — cloudflared never needs to authenticate interactively.
resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = "cloudflared-credentials"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
  }

  data = {
    "credentials.json" = jsonencode({
      AccountTag   = var.cloudflare_account_id
      TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.this.id
      TunnelSecret = random_id.tunnel_secret.b64_std
    })
  }
}

locals {
  # Every public hostname forwards to the same internal-ingress Service —
  # nginx does the actual host/path -> backend Service routing from there.
  # Order is irrelevant except for the mandatory trailing catch-all.
  ingress_rules = concat(
    [
      for route in var.public_routes : {
        hostname = route.hostname
        service  = var.internal_ingress_service_url
      }
    ],
    [{ service = "http_status:404" }]
  )
}

resource "kubernetes_config_map_v1" "config" {
  metadata {
    name      = "cloudflared-config"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
  }

  data = {
    "config.yaml" = yamlencode({
      tunnel             = cloudflare_zero_trust_tunnel_cloudflared.this.id
      "credentials-file" = "/etc/cloudflared/creds/credentials.json"
      metrics            = "0.0.0.0:2000"
      "no-autoupdate"    = true
      ingress            = local.ingress_rules
    })
  }
}

# Outbound-only by design: 3 replicas each dial out to the Cloudflare edge.
# Deliberately no kubernetes_service_v1 for this workload — there is nothing
# to expose in-cluster and nothing for the tunnel to listen on.
resource "kubernetes_deployment_v1" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "cloudflared"
    }
  }

  spec {
    replicas = var.replica_count

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "cloudflared"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "cloudflared"
        }
      }

      spec {
        automount_service_account_token = false

        container {
          name  = "cloudflared"
          image = var.image
          args = [
            "tunnel",
            "--config", "/etc/cloudflared/config/config.yaml",
            "--metrics", "0.0.0.0:2000",
            "run",
          ]

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/cloudflared/config"
            read_only  = true
          }

          volume_mount {
            name       = "creds"
            mount_path = "/etc/cloudflared/creds"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.config.metadata[0].name
          }
        }

        volume {
          name = "creds"
          secret {
            secret_name = kubernetes_secret_v1.credentials.metadata[0].name
          }
        }
      }
    }
  }
}
