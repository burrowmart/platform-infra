output "bucket_name" {
  value = aws_s3_bucket.opa_bundles.id
}

output "bucket_arn" {
  value = aws_s3_bucket.opa_bundles.arn
}

output "writer_role_arn" {
  description = "IAM role the opa-policies repo's CI assumes to publish bundles."
  value       = aws_iam_role.writer.arn
}

output "reader_role_arn" {
  description = "IRSA role for the OPA PDP DaemonSet's ServiceAccount annotation."
  value       = aws_iam_role.reader.arn
}
