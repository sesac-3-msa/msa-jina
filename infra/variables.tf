variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "cluster_name" {
  description = "EKS 클러스터명 (VPC, IAM, 태그 접두어로도 사용)"
  type        = string
  default     = "eks-msa-practice"
}

variable "cluster_version" {
  description = "EKS 쿠버네티스 버전 (표준 지원 범위 내 버전 사용 — 확장 지원은 과금 6배)"
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnets" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_count" {
  description = "워커 노드 수 (요구사항 1번: 2개)"
  type        = number
  default     = 2
}

variable "ecr_repositories" {
  description = "생성할 ECR 리포 이름 (key = output 접미어, value = 리포 이름)"
  type        = map(string)
  default = {
    gateway = "gateway"
    member  = "member-service"
    order   = "order-service"
  }
}
