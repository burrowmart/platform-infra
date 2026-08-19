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
# its ServiceAccount (eks.amazonaws.com/role-arn) by the base-service chart.
resource "aws_iam_role" "this" {
  for_each = var.services

  name               = "${each.key}-irsa"
  assume_role_policy = data.aws_iam_policy_document.assume_role[each.key].json
  tags               = var.tags
}

data "aws_iam_policy_document" "secrets_read" {
  for_each = var.services

  statement {
    sid       = "ReadOwnSecretsOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.secrets_prefix}/${each.key}/*"]
  }
}

resource "aws_iam_role_policy" "secrets_read" {
  for_each = var.services

  name   = "secrets-manager-read"
  role   = aws_iam_role.this[each.key].id
  policy = data.aws_iam_policy_document.secrets_read[each.key].json
}
