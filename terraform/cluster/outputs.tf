output "cluster_name" {
  description = "Passed to the platform root as cluster_name."
  value       = var.cluster_name
}

output "instance_id" {
  description = "EC2 instance id — the --target for `aws ssm start-session` (shell and API port-forward)."
  value       = aws_instance.k3s.id
}

output "node_public_ip" {
  description = "Stable Elastic IP of the node. Survives a spot stop/start."
  value       = aws_eip.node.public_ip
}

output "kubeconfig_parameter_name" {
  description = "SSM SecureString parameter holding the cluster kubeconfig (server: https://127.0.0.1:6443, used through the SSM port-forward)."
  value       = local.kubeconfig_param
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider for this cluster's service accounts. Consumed by the platform root's irsa module — the drop-in replacement for the EKS-managed one."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider_url" {
  description = "Service-account token issuer URL (the public discovery bucket)."
  value       = aws_iam_openid_connect_provider.cluster.url
}

output "oidc_bucket_name" {
  value = local.oidc_bucket
}

output "aws_region" {
  description = "Region everything lives in. Read by the Makefile so shell targets don't need AWS_REGION set."
  value       = var.aws_region
}
