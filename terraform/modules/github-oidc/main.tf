locals {
  patterns = coalesce(var.repo_patterns, ["${var.github_owner}/*"])

  # arbitrary/wildcard characters aren't valid in IAM role names
  role_names = {
    for p in local.patterns :
    p => "${var.role_name_prefix}-${replace(replace(p, "/", "-"), "*", "wildcard")}"
  }
}

# One OIDC identity provider per AWS account for GitHub Actions — every
# assume-role below trusts this same provider, scoped down by its own
# `sub` condition.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list intentionally omitted: the AWS provider derives and
  # keeps it current automatically (since GitHub's TLS chain rotates and a
  # hardcoded thumbprint would silently go stale).
}

data "aws_iam_policy_document" "assume_role" {
  for_each = local.role_names

  statement {
    sid     = "GithubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${each.key}:ref:${var.allowed_ref}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = local.role_names

  name               = each.value
  assume_role_policy = data.aws_iam_policy_document.assume_role[each.key].json
  tags               = var.tags
}

# ---------------------------------------------------------------------------
# Least-privilege deploy policy.
#
# There is no EKS here, so there is no `aws eks update-kubeconfig` and no EKS
# access entry. CI reaches the API server exactly the way a developer does:
# read the kubeconfig out of SSM, then open a Session Manager port-forward to
# 6443 on the node. That means the cluster still has zero inbound
# security-group rules, and Kubernetes-level authorization comes from the
# kubeconfig's client certificate rather than from IAM.
#
# Caveat worth stating plainly: that certificate is k3s's cluster-admin. EKS
# access policies gave finer-grained scoping (AmazonEKSEditPolicy) that a
# single-node k3s box cannot reproduce without issuing per-repo client certs
# and RBAC bindings. Acceptable for a demo cluster; not for production.
# No ECR permissions anywhere — images are published to ghcr.io.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "ReadKubeconfig"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter${var.kubeconfig_parameter_name}"]
  }

  statement {
    sid       = "DecryptKubeconfig"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "DescribeClusterNode"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"] # ec2:DescribeInstances does not support resource-level constraints
  }

  # Port-forward only — AWS-StartPortForwardingSession cannot open a shell.
  statement {
    sid     = "PortForwardToApiServer"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/${var.cluster_instance_id}",
      "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
    ]

    condition {
      test     = "StringEquals"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  statement {
    sid       = "TerminateOwnSession"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:session/*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = aws_iam_role.deploy

  name   = "cluster-deploy"
  role   = each.value.id
  policy = data.aws_iam_policy_document.deploy.json
}
