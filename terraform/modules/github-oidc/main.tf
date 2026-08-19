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

# Least-privilege IAM policy: only what `aws eks update-kubeconfig` needs.
# No ECR permissions anywhere — images are published to ghcr.io. Actual
# Kubernetes-level deploy permissions (helm/kubectl) come from the EKS
# access entry + policy association below, not from IAM policy.
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EKSDescribeOnly"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [var.eks_cluster_arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = aws_iam_role.deploy

  name   = "eks-describe"
  role   = each.value.id
  policy = data.aws_iam_policy_document.deploy.json
}

# EKS access entries are the modern (non aws-auth-ConfigMap) way to grant a
# principal Kubernetes API access. This is what actually authorizes
# `helm upgrade` / `kubectl apply` — the IAM policy above only gets the role
# far enough to resolve cluster connection details.
resource "aws_eks_access_entry" "deploy" {
  for_each = aws_iam_role.deploy

  cluster_name  = var.eks_cluster_name
  principal_arn = each.value.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "deploy" {
  for_each = aws_iam_role.deploy

  cluster_name  = var.eks_cluster_name
  principal_arn = each.value.arn
  policy_arn    = var.eks_access_policy_arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.deploy]
}
