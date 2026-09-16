module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id = module.vpc.vpc_id
  # 노드는 프라이빗 서브넷에만 배치
  subnet_ids = module.vpc.private_subnets

  # 로컬 kubectl 접속용 퍼블릭 엔드포인트
  cluster_endpoint_public_access = true

  # IRSA (LB Controller 서비스어카운트에 IAM 역할 연결)
  enable_irsa = true

  # 20.x access entry 방식: terraform 실행 주체에게 cluster-admin 부여 (aws-auth ConfigMap 미사용)
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  cloudwatch_log_group_retention_in_days = 1

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = var.node_count
      max_size     = var.node_count
      desired_size = var.node_count
    }
  }

  # NodePort 대역 인바운드 허용 (VPC 내부에서)
  node_security_group_additional_rules = {
    ingress_nodeport_tcp = {
      description = "NodePort range from VPC"
      protocol    = "tcp"
      from_port   = 30000
      to_port     = 32767
      type        = "ingress"
      cidr_blocks = [var.vpc_cidr]
    }
  }
}
