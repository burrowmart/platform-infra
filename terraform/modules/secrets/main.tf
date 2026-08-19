locals {
  keys = ["mongo-uri", "rabbit-url", "redis-url", "cognito-issuer", "cognito-audience"]

  defaults = {
    for k in local.keys : k => "CHANGEME-set-via-secret_values-var"
  }

  # service -> key -> value, defaults merged under any per-service override
  resolved = {
    for svc in var.services :
    svc => merge(local.defaults, lookup(var.secret_values, svc, {}))
  }

  # flatten to "<service>/<key>" => { service, key, value } for a single
  # for_each map across both resources below
  entries = merge([
    for svc, kv in local.resolved : {
      for k, v in kv : "${svc}/${k}" => {
        service = svc
        key     = k
        value   = v
      }
    }
  ]...)
}

# Metadata only — no value lives on this resource, so plans/diffs of it never
# show a secret value even in the "will be created" summary.
resource "aws_secretsmanager_secret" "this" {
  for_each = local.entries

  name                    = "${var.secrets_prefix}/${each.value.service}/${each.value.key}"
  description             = "${each.value.key} for ${each.value.service}, synced into the cluster via External Secrets Operator."
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

# The value itself — sourced from the sensitive secret_values var, never a
# literal in this file. Terraform state will still contain it in plaintext
# (an inherent Terraform limitation); see the root README for mitigations
# (encrypted remote state, restricted state access).
resource "aws_secretsmanager_secret_version" "this" {
  for_each = local.entries

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = each.value.value
}
