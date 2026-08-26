# ---------------------------------------------------------------------------
# Minimal VPC — one public subnet, no NAT Gateway.
#
# The eksctl command this replaced used --node-private-networking, which
# forces a NAT Gateway (~$33/month + per-GB) purely so private nodes can
# reach the internet outbound. That buys nothing here: there is no public
# inbound anyway (the security group below has zero ingress rules, every
# Service is ClusterIP, and traffic arrives via the Cloudflare Tunnel's
# outbound-only connection). A public subnet with a locked-down SG gives the
# same exposure for $0.
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.cluster_name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.cluster_name }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = data.aws_availability_zones.available.names[0]

  # No auto-assigned public IP: the node gets a stable Elastic IP instead, so
  # its address (and therefore the API cert SAN) survives a spot stop/start.
  map_public_ip_on_launch = false

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security group — egress only by default.
#
# Everything that needs to reach in does so over an outbound connection the
# node itself opens: cloudflared dials the Cloudflare edge, the SSM agent
# dials Systems Manager (which is how kubectl/helm/Terraform get to the API,
# via a port-forward session). api_allowed_cidrs is the deliberate escape
# hatch and is empty unless you set it.
# ---------------------------------------------------------------------------

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "k3s single node: egress only, optional 6443 from api_allowed_cidrs"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.cluster_name}-node" }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "Outbound to anywhere: container registries, Cloudflare edge, SSM, AWS APIs."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "api" {
  for_each = toset(var.api_allowed_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "Direct Kubernetes API access (bypasses the SSM tunnel)"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = each.value
}

resource "aws_eip" "node" {
  domain = "vpc"
  tags   = { Name = var.cluster_name }
}
