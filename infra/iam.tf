# AWS Load Balancer Controller 공식 IAM 정책
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_policy" "lb_controller" {
  name        = "${var.cluster_name}-AWSLoadBalancerControllerIAMPolicy"
  description = "IAM policy for AWS Load Balancer Controller (${var.cluster_name})"
  policy      = file("${path.module}/iam-policy.json")
}

# IRSA: kube-system:aws-load-balancer-controller 서비스어카운트 ↔ IAM 역할 신뢰 관계
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.60"

  role_name = "${var.cluster_name}-lb-controller"

  role_policy_arns = {
    lb_controller = aws_iam_policy.lb_controller.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
