output "bucket_name" {
  description = "Set as LOKI_S3_BUCKET in k8s/observability/loki/deployment.yaml."
  value       = aws_s3_bucket.loki_chunks.id
}

output "bucket_arn" {
  value = aws_s3_bucket.loki_chunks.arn
}

output "role_arn" {
  description = "IRSA role for Loki's ServiceAccount annotation (k8s/observability/loki/serviceaccount.yaml)."
  value       = aws_iam_role.loki.arn
}
