# Canonical's published AMI id for the region — resolved at plan time rather
# than hardcoded, so this root is region-portable and never pins a stale image.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "k3s" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
    # Keep cluster state across a spot stop/start; destroyed with the instance.
    delete_on_termination = true
  }

  # Spot with interruption_behavior = "stop" + a persistent request: AWS stops
  # the node when it reclaims capacity and starts it again when capacity comes
  # back, leaving the EBS root volume (and all cluster state) intact. A
  # "terminate" behaviour would wipe the cluster on every reclaim.
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []

    content {
      market_type = "spot"

      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region       = var.aws_region
    k3s_version      = var.k3s_version
    oidc_issuer      = local.oidc_issuer
    oidc_bucket      = local.oidc_bucket
    kubeconfig_param = local.kubeconfig_param
    node_public_ip   = aws_eip.node.public_ip
  })

  tags = { Name = var.cluster_name }

  # The bootstrap script publishes to both before it finishes; without these
  # the instance can race ahead of the bucket policy or the OIDC provider.
  depends_on = [
    aws_s3_bucket_policy.oidc,
    aws_iam_role_policy.node_bootstrap,
    aws_iam_role_policy_attachment.ssm_core,
    aws_route_table_association.public,
  ]
}

resource "aws_eip_association" "node" {
  instance_id   = aws_instance.k3s.id
  allocation_id = aws_eip.node.id
}

# `aws_instance` returns as soon as EC2 reports the instance running — the
# bootstrap script still has several minutes of work left. The platform root
# reads the kubeconfig SSM parameter, so block here until it exists, otherwise
# `make up` hands over a cluster that isn't there yet.
resource "terraform_data" "wait_for_k3s" {
  triggers_replace = [aws_instance.k3s.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      for i in $(seq 1 60); do
        if aws ssm get-parameter --name "${local.kubeconfig_param}" \
             --region "${var.aws_region}" >/dev/null 2>&1; then
          echo "k3s is up: kubeconfig published to ${local.kubeconfig_param}"
          exit 0
        fi
        echo "waiting for k3s bootstrap ($i/60)..."
        sleep 15
      done
      echo "Timed out after 15 minutes." >&2
      echo "Inspect the bootstrap log:" >&2
      echo "  aws ssm start-session --target ${aws_instance.k3s.id} --region ${var.aws_region}" >&2
      echo "  sudo tail -100 /var/log/k3s-bootstrap.log" >&2
      exit 1
    EOT
  }

  depends_on = [aws_eip_association.node]
}
