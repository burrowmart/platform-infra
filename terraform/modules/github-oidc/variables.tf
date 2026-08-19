variable "github_owner" {
  description = "GitHub org/user that owns every service repo."
  type        = string
}

variable "repo_patterns" {
  description = "Repo patterns (owner/repo, '*' wildcard allowed) allowed to assume the deploy role. Rendered into the OIDC `sub` condition as repo:<pattern>:ref:<allowed_ref>. Defaults to every repo under github_owner."
  type        = list(string)
  default     = null
}

variable "allowed_ref" {
  description = "Git ref allowed to assume the deploy role — deploys only run from this branch."
  type        = string
  default     = "refs/heads/main"
}

variable "role_name_prefix" {
  description = "Prefix for the generated IAM role name(s)."
  type        = string
  default     = "github-oidc-deploy"
}

variable "eks_cluster_name" {
  description = "EKS cluster the deploy role gets `eks:DescribeCluster` + Kubernetes API access on."
  type        = string
}

variable "eks_cluster_arn" {
  description = "ARN of the EKS cluster, for the IAM policy resource constraint."
  type        = string
}

variable "eks_access_policy_arn" {
  description = <<-EOT
    AWS-managed EKS access policy granted to the deploy role, cluster-scoped.
    Defaults to AmazonEKSEditPolicy (create/update/delete workloads, no RBAC
    or node-group admin) rather than the Admin/ClusterAdmin policies — CI
    creates a namespace per service (helm --create-namespace) so this can't
    be pinned to specific namespaces up front.
  EOT
  type        = string
  default     = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
}

variable "tags" {
  type    = map(string)
  default = {}
}
