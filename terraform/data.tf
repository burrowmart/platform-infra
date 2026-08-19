# The EKS cluster is provisioned elsewhere (out of scope for this session).
# Everything in this tree wires infra AROUND it — no cluster resource is created here.
data "aws_eks_cluster" "this" {
  name = var.eks_cluster_name
}

# Short-lived bearer token for the kubernetes/helm providers below. Regenerated
# on every plan/apply — never stored as a static credential.
data "aws_eks_cluster_auth" "this" {
  name = var.eks_cluster_name
}
