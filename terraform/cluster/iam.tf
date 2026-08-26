locals {
  kubeconfig_param = "/${var.cluster_name}/kubeconfig"
}

# ---------------------------------------------------------------------------
# Node instance role.
#
# Deliberately tiny: publish the OIDC discovery documents once at boot, stash
# the kubeconfig in SSM once at boot, and be manageable via Session Manager.
# Pods do NOT borrow this role — they get their own IRSA roles (see the
# platform root), which is why there is no Secrets Manager access here.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
}

# Session Manager: shell access and — more importantly — the port-forward
# session that carries kubectl/helm/Terraform traffic to the API server.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "node_bootstrap" {
  statement {
    sid       = "PublishOidcDiscovery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.oidc.arn}/*"]
  }

  statement {
    sid       = "PublishKubeconfig"
    effect    = "Allow"
    actions   = ["ssm:PutParameter", "ssm:AddTagsToResource"]
    resources = ["arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter${local.kubeconfig_param}"]
  }

  statement {
    sid     = "EncryptKubeconfigParameter"
    effect  = "Allow"
    actions = ["kms:Encrypt", "kms:GenerateDataKey", "kms:Decrypt"]
    # The AWS-managed alias/aws/ssm key. Constrained by ViaService so this
    # role cannot use KMS for anything except Parameter Store.
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "node_bootstrap" {
  name   = "bootstrap"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node_bootstrap.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
}
