# ---------------------------------------------------------------------------
# Bucket — versioned, private, encrypted. No ACLs (ownership controls force
# bucket-owner-enforced, the modern replacement for ACL-based access).
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "opa_bundles" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "opa_bundles" {
  bucket = aws_s3_bucket.opa_bundles.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "opa_bundles" {
  bucket = aws_s3_bucket.opa_bundles.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "opa_bundles" {
  bucket                  = aws_s3_bucket.opa_bundles.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "opa_bundles" {
  bucket = aws_s3_bucket.opa_bundles.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------------------------
# Writer — opa-policies repo's CI, via the shared GitHub OIDC provider.
# Write-only: publishes bundles, never reads its own upload back or lists
# unrelated keys.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "writer_assume_role" {
  statement {
    sid     = "OpaPoliciesCiOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.opa_policies_repo}:ref:${var.writer_allowed_ref}"]
    }
  }
}

resource "aws_iam_role" "writer" {
  name               = "opa-bundle-writer"
  assume_role_policy = data.aws_iam_policy_document.writer_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "writer" {
  statement {
    sid       = "PublishBundles"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.opa_bundles.arn, "${aws_s3_bucket.opa_bundles.arn}/*"]
  }
}

resource "aws_iam_role_policy" "writer" {
  name   = "opa-bundle-write"
  role   = aws_iam_role.writer.id
  policy = data.aws_iam_policy_document.writer.json
}

# ---------------------------------------------------------------------------
# Reader — OPA PDP DaemonSet, via EKS IRSA. Read-only.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "reader_assume_role" {
  statement {
    sid     = "OpaDaemonSetIRSA"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${trimprefix(var.eks_oidc_provider_url, "https://")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${trimprefix(var.eks_oidc_provider_url, "https://")}:sub"
      values   = ["system:serviceaccount:${var.opa_namespace}:${var.opa_service_account}"]
    }
  }
}

resource "aws_iam_role" "reader" {
  name               = "opa-bundle-reader-irsa"
  assume_role_policy = data.aws_iam_policy_document.reader_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "reader" {
  statement {
    sid       = "ReadBundles"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.opa_bundles.arn, "${aws_s3_bucket.opa_bundles.arn}/*"]
  }
}

resource "aws_iam_role_policy" "reader" {
  name   = "opa-bundle-read"
  role   = aws_iam_role.reader.id
  policy = data.aws_iam_policy_document.reader.json
}
