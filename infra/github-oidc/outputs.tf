output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}