# ---------------------------------------------------------------------------
# Bucket — private, encrypted, no ACLs. Same posture as
# ../opa-bundle-bucket, with two deliberate differences, both about what log
# chunks are:
#
#   1. NO versioning. Chunks are written once and never modified; the only
#      thing that ever deletes them is Loki's own retention compactor. With
#      versioning on, that delete would write a delete marker and keep the
#      object — so retention would stop reclaiming anything while the bill
#      kept growing, and the retained versions would not even be queryable.
#      The OPA bundle bucket wants versioning for the opposite reason: one
#      mutable object whose previous revision is a rollback target.
#
#   2. A lifecycle policy (below), which the bundle bucket has no use for.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "loki_chunks" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_ownership_controls" "loki_chunks" {
  bucket = aws_s3_bucket.loki_chunks.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "loki_chunks" {
  bucket                  = aws_s3_bucket.loki_chunks.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki_chunks" {
  bucket = aws_s3_bucket.loki_chunks.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------------------------
# Lifecycle — a backstop, NOT the primary retention mechanism.
#
# Loki's compactor is what deletes expired chunks (limits_config.retention_period
# in k8s/observability/loki/loki-config.yaml). This rule catches what the
# compactor cannot: objects orphaned by a compactor that was disabled, crashed,
# or ran with a shorter retention than the data already in the bucket.
#
# expiration_days MUST stay comfortably LONGER than Loki's retention_period.
# Shorter, and S3 deletes chunks the TSDB index still points at — queries then
# fail on missing objects rather than returning fewer results. 14d retention
# against a 30d expiry leaves a wide margin.
#
# Deliberately no transition to STANDARD_IA or Glacier: IA bills a 30-day
# minimum per object plus a per-GB retrieval fee, so moving objects that are
# deleted at 30 days anyway costs more than it saves. Tiering starts paying
# off at retention measured in months.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "loki_chunks" {
  bucket = aws_s3_bucket.loki_chunks.id

  rule {
    id     = "expire-orphaned-chunks"
    status = "Enabled"

    filter {}

    expiration {
      days = var.expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    # Loki writes larger chunks as multipart uploads. A part that never
    # completes is billed as stored data but is invisible in the console's
    # object listing — the classic silently-growing S3 bill.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Loki's IRSA role. One role, not the reader/writer split the bundle bucket
# uses: Loki writes chunks, reads them back to answer queries, and deletes
# them when the compactor enforces retention — all as the same principal.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "LokiIRSA"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.cluster_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${trimprefix(var.cluster_oidc_provider_url, "https://")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${trimprefix(var.cluster_oidc_provider_url, "https://")}:sub"
      values   = ["system:serviceaccount:${var.loki_namespace}:${var.loki_service_account}"]
    }
  }
}

resource "aws_iam_role" "loki" {
  name               = "loki-chunks-irsa"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "loki" {
  statement {
    sid    = "ReadWriteChunks"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      # Multipart uploads that Loki gives up on — without this the parts
      # linger until the lifecycle rule above sweeps them.
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.loki_chunks.arn}/*"]
  }

  statement {
    sid       = "ListChunks"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.loki_chunks.arn]
  }
}

resource "aws_iam_role_policy" "loki" {
  name   = "loki-chunks-readwrite"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki.json
}
