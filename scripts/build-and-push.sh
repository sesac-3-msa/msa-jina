#!/usr/bin/env bash
# 세 서비스 이미지를 빌드해 ECR에 푸시한다. 저장소 루트에서 실행.
#   ./scripts/build-and-push.sh [TAG]
# TAG 생략 시 git short SHA. 마지막 줄에 TAG=... 를 출력한다.
set -euo pipefail

cd "$(dirname "$0")/.."

REGION=$(terraform -chdir=infra output -raw region)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
TAG=${1:-$(git rev-parse --short HEAD)}

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# 디렉터리명 -> terraform output 이름
declare -A OUTPUT_OF=(
  [gateway]=ecr_gateway_url
  [member-service]=ecr_member_url
  [order-service]=ecr_order_url
)

for svc in gateway member-service order-service; do
  REPO=$(terraform -chdir=infra output -raw "${OUTPUT_OF[$svc]}")
  if [[ -z "$REPO" ]]; then
    echo "ERROR: terraform output ${OUTPUT_OF[$svc]} 이 비어 있음" >&2
    exit 1
  fi
  echo "==> $svc -> $REPO:$TAG"
  docker build --platform linux/amd64 -t "$REPO:$TAG" "apps/$svc"
  docker push "$REPO:$TAG"
done

echo "TAG=$TAG"
