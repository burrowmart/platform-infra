locals {
  # OIDC condition keys are written without the "https://" scheme.
  oidc_host = trimprefix(var.oidc_provider_url, "https://")

  service_accounts = {
    for name, svc in var.services :
    name => coalesce(svc.service_account, name)
  }
}

data "aws_iam_policy_document" "assume_role" {
  for_each = var.services

  statement {
    sid     = "IRSA"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${local.service_accounts[each.key]}"]
    }
  }
}

# Referenced by each service's Helm release as `irsaRoleArn`, annotated onto
# its ServiceAccount by the base-service chart. Since this cluster has no
# EKS pod-identity webhook, that chart also mounts the projected
# sts.amazonaws.com token and sets AWS_ROLE_ARN itself.
resource "aws_iam_role" "this" {
  for_each = var.services

  name               = "${each.key}-irsa"
  assume_role_policy = data.aws_iam_policy_document.assume_role[each.key].json
  tags               = var.tags
}

# Read scope follows the secrets module's backend. Either way a service can
# only read its own <prefix>/<service>/* path — never another service's.
data "aws_iam_policy_document" "secrets_read" {
  for_each = var.services

  dynamic "statement" {
    for_each = var.secrets_backend == "secretsmanager" ? [1] : []

    content {
      sid       = "ReadOwnSecretsOnly"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = ["arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.secrets_prefix}/${each.key}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.secrets_backend == "ssm" ? [1] : []

    content {
      sid    = "ReadOwnParametersOnly"
      effect = "Allow"
      actions = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:DescribeParameters",
      ]
      resources = ["arn:${var.aws_partition}:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.secrets_prefix}/${each.key}/*"]
    }
  }

  # SecureString parameters are encrypted with the AWS-managed alias/aws/ssm
  # key; reading one needs kms:Decrypt, constrained to calls made through SSM.
  dynamic "statement" {
    for_each = var.secrets_backend == "ssm" ? [1] : []

    content {
      sid       = "DecryptViaParameterStoreOnly"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "secrets_read" {
  for_each = var.services

  name   = "service-secrets-read"
  role   = aws_iam_role.this[each.key].id
  policy = data.aws_iam_policy_document.secrets_read[each.key].json
}
