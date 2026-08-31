locals {
  keys = ["mongo-uri", "rabbit-url", "redis-url"]

  defaults = {
    for k in local.keys : k => "CHANGEME-set-via-secret_values-var"
  }

  # service -> key -> value, defaults merged under any per-service override
  resolved = {
    for svc in var.services :
    svc => merge(local.defaults, lookup(var.secret_values, svc, {}))
  }

  # flatten to "<service>/<key>" => { service, key, value } for a single
  # for_each map across the resources below
  entries = merge([
    for svc, kv in local.resolved : {
      for k, v in kv : "${svc}/${k}" => {
        service = svc
        key     = k
        value   = v
      }
    }
  ]...)

  # Exactly one backend is populated; the other's for_each collapses to {}.
  sm_entries  = var.backend == "secretsmanager" ? local.entries : {}
  ssm_entries = var.backend == "ssm" ? local.entries : {}
}

# ---------------------------------------------------------------------------
# Backend: SSM Parameter Store (default)
#
# Standard-tier parameters are free — the reason this is the default. Stored
# as SecureString under the AWS-managed alias/aws/ssm key. External Secrets
# Operator reads these with provider `aws`, service `ParameterStore`.
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "this" {
  for_each = local.ssm_entries

  name        = "/${var.secrets_prefix}/${each.value.service}/${each.value.key}"
  description = "${each.value.key} for ${each.value.service}, synced into the cluster via External Secrets Operator."
  type        = "SecureString"
  value       = each.value.value
  tier        = "Standard"
  tags        = var.tags
}

# ---------------------------------------------------------------------------
# Backend: Secrets Manager
#
# $0.40 per secret per month. With the default service list that is 60
# secrets, so ~$24/month — see the platform root's secrets_backend variable
# before switching to this.
# ---------------------------------------------------------------------------

# Metadata only — no value lives on this resource, so plans/diffs of it never
# show a secret value even in the "will be created" summary.
resource "aws_secretsmanager_secret" "this" {
  for_each = local.sm_entries

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
  for_each = local.sm_entries

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = each.value.value
}
