variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "robot-shop-observability"
}

variable "cluster_name" {
  type    = string
  default = "robot-shop"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

# Availability zones to use. EKS needs at least two.
variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "node_instance_type" {
  type    = string
  default = "m7i-flex.large"
}

variable "node_count" {
  type    = number
  default = 3
}

variable "admin_user_arn" {
  type        = string
  description = "IAM user or role that gets cluster-admin access for kubectl"
}

variable "pipeline_role_arn" {
  type        = string
  description = "GitHub apply role, which the destroy script uses to check the cluster"
}