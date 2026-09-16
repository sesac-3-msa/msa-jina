output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "lb_controller_role_arn" {
  value = module.lb_controller_irsa.iam_role_arn
}

output "ecr_gateway_url" {
  value = aws_ecr_repository.this["gateway"].repository_url
}

output "ecr_member_url" {
  value = aws_ecr_repository.this["member"].repository_url
}

output "ecr_order_url" {
  value = aws_ecr_repository.this["order"].repository_url
}
