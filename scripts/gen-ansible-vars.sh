#!/usr/bin/env bash
# Terraform output을 읽어 ansible/group_vars/all.yml 을 생성한다 (하드코딩 방지).
#   ./scripts/gen-ansible-vars.sh <IMAGE_TAG>
set -euo pipefail

cd "$(dirname "$0")/.."

TAG=${1:?"사용법: $0 <IMAGE_TAG>"}
JWT_SECRET=${JWT_SECRET:-$(openssl rand -base64 48 | tr -d '\n')}

tf() { terraform -chdir=infra output -raw "$1"; }

cat > ansible/group_vars/all.yml <<YAML
# 자동 생성됨 (scripts/gen-ansible-vars.sh) — 직접 수정하지 말 것
region: "$(tf region)"
cluster_name: "$(tf cluster_name)"
vpc_id: "$(tf vpc_id)"
public_subnet_cidrs: $(terraform -chdir=infra output -json public_subnet_cidrs)
lb_controller_role_arn: "$(tf lb_controller_role_arn)"
image_tag: "$TAG"
ecr_gateway: "$(tf ecr_gateway_url)"
ecr_member: "$(tf ecr_member_url)"
ecr_order: "$(tf ecr_order_url)"
jwt_secret: "$JWT_SECRET"
YAML

echo "ansible/group_vars/all.yml 생성 완료 (image_tag=$TAG)"
