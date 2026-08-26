# ---------------------------------------------------------------------------
# IRSA without EKS.
#
# EKS gives you a managed OIDC discovery endpoint for the API server's
# service-account signing key; that endpoint is the whole basis of IRSA. k3s
# has the same signing key, it just doesn't publish it anywhere AWS can
# reach. So we publish it ourselves: the API server is started with
# service-account-issuer pointing at this bucket, and the bootstrap script
# copies the API server's own JWKS (kubectl get --raw /openid/v1/jwks) into
# it. From STS's point of view this is indistinguishable from EKS.
#
# The result is that terraform/modules/irsa works here completely unchanged,
# and the "no static cloud credentials" property of the architecture
# survives the move off EKS.
#
# The bucket is public on purpose: it holds a public key and nothing else.
# ---------------------------------------------------------------------------

resource "random_id" "oidc_suffix" {
  byte_length = 4
}

locals {
  oidc_bucket = coalesce(var.oidc_bucket_name, "${var.cluster_name}-oidc-${random_id.oidc_suffix.hex}")
  oidc_issuer = "https://${local.oidc_bucket}.s3.${var.aws_region}.amazonaws.com"
}

resource "aws_s3_bucket" "oidc" {
  bucket = local.oidc_bucket

  # Demo cluster: let `terraform destroy` actually destroy it.
  force_destroy = true

  tags = { Name = "${var.cluster_name}-oidc" }
}

resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  # All four must be false for the anonymous-read policy below to take
  # effect. This is the one place in this tree where public access is
  # intentional — see the comment at the top of the file.
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "oidc_public_read" {
  statement {
    sid     = "AnonymousDiscoveryRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    # Scoped to the two discovery documents only — never the whole bucket.
    resources = [
      "${aws_s3_bucket.oidc.arn}/.well-known/openid-configuration",
      "${aws_s3_bucket.oidc.arn}/keys.json",
    ]
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  policy = data.aws_iam_policy_document.oidc_public_read.json

  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

# Registers the bucket as an IAM identity provider, so sts:AssumeRoleWithWebIdentity
# accepts service-account tokens signed by this cluster's API server. This is
# the exact resource the platform root used to create from the EKS cluster's
# managed issuer — modules/irsa consumes it identically.
resource "aws_iam_openid_connect_provider" "cluster" {
  url            = local.oidc_issuer
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list intentionally omitted — provider-managed.

  depends_on = [aws_s3_bucket_policy.oidc]
}
