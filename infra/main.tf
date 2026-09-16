data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # 프로바이더 default_tags는 EKS 모듈이 만드는 런치 템플릿의 인스턴스/볼륨 태그까지 전파되지 않는다.
  # 모듈에 직접 넘겨 EC2 인스턴스에도 Owner 태그가 붙게 한다.
  tags = {
    Owner   = var.name_prefix
    Project = var.cluster_name
  }
}
