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

variable "cluster_instance_id" {
  description = "EC2 instance id of the k3s node. Scopes the ssm:StartSession port-forward permission to exactly that one host."
  type        = string
}

variable "kubeconfig_parameter_name" {
  description = "SSM parameter holding the cluster kubeconfig. The deploy role gets ssm:GetParameter on this one path only."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "aws_account_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
