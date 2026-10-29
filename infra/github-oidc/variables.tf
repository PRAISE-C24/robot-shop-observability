variable "region" {
  type    = string
  default = "us-east-1"
}

variable "create_oidc_provider" {
  type        = bool
  default     = true
  description = "Create GitHub's OIDC provider. AWS allows one per account: set false if another project already created it."
}

variable "github_repo_sub" {
  type    = string
  default = "repo:PRAISE-C24@104138599/robot-shop-observability@1437240205"
}

variable "state_bucket" {
  type    = string
  default = "tfstate-663001881484-us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "robot-shop" # must match cluster_name in infra/eks
}
