module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  tags = local.tags

  azs             = var.azs
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets

  # 실습 비용 절감: NAT 1개. 프라이빗 서브넷의 노드가 ECR/컨트롤플레인에 나가는 경로.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # LB Controller가 서브넷을 자동 탐색하는 태그. 빠지면 Service/Ingress가 pending에 머문다.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
