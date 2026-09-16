resource "aws_ecr_repository" "this" {
  for_each = var.ecr_repositories

  name                 = each.value
  image_tag_mutability = "MUTABLE"
  # 이미지가 남아 있어도 destroy 가능하게
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
