# 검증 가이드 — 직접 명령어로 확인하기

> 저장소 루트에서 실행. 각 단계의 "기대" 값이 나오면 통과.

## 0. 준비

```bash
# kubeconfig 갱신
$(terraform -chdir=infra output -raw kubeconfig_command)

# NLB 주소 변수로
NLB=$(kubectl get svc -n c2-gateway c2-gateway-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); echo $NLB
```

## 1. 노드 2개 Ready (요구사항 1)

```bash
kubectl get nodes -o wide
```
기대: `Ready` 2개, INTERNAL-IP가 `10.0.10.x` / `10.0.11.x` (프라이빗 서브넷).

```bash
aws ec2 describe-instances --region ap-northeast-2 --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Owner:Tags[?Key==`Owner`]|[0].Value,Type:InstanceType}' --output table
```
기대: Name `c2-eks-msa-practice-node`, Owner `c2`, `t3.medium` × 2.

## 2. 파드 6개 Running, 두 노드에 분산 (요구사항 5)

```bash
kubectl get pods -n c2-gateway -o wide
kubectl get pods -n c2-app -o wide
```
기대: c2-gateway-svc 2, c2-member-svc 2, c2-order-svc 2. 같은 앱의 두 파드가 서로 다른 NODE에 있음.

## 3. 미인증 차단 → 401

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://$NLB/api/orders
```
기대: `401`

## 4. 로그인 → 토큰

```bash
TOKEN=$(curl -s -X POST http://$NLB/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"user1","password":"pass1"}' | jq -r .token); echo $TOKEN
```
기대: `eyJ...` 토큰. 헤더/클레임 확인:
```bash
echo $TOKEN | cut -d. -f1 | base64 -d; echo
echo $TOKEN | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null; echo
```
기대: `{"alg":"HS256"}` / `sub`, `role`, `iat`, `exp`.

## 5. 인증 호출 → 200 + pod 필드

```bash
curl -s http://$NLB/api/orders -H "Authorization: Bearer $TOKEN" | jq
curl -s http://$NLB/api/members -H "Authorization: Bearer $TOKEN" | jq
```
기대: `pod` 필드에 파드명, `data` 배열.

## 6. 헤더 위조 → 무시

```bash
curl -s http://$NLB/api/members/me -H "Authorization: Bearer $TOKEN" -H "X-User-Id: hacker" | jq
```
기대: `"userId": "user1"` (hacker 아님). 게이트웨이가 클라이언트의 `X-User-Id`를 제거하고 토큰의 `sub`를 주입.

## 7. 로드밸런싱 (요구사항 5)

### 7a. 게이트웨이 경유 — 쏠릴 수 있음
```bash
for i in $(seq 20); do
  curl -s http://$NLB/api/orders -H "Authorization: Bearer $TOKEN" | jq -r .pod
done | sort | uniq -c
```
한쪽으로 쏠려도 정상. SCG의 Netty 클라이언트가 커넥션 풀을 재사용하기 때문.

### 7b. 클러스터 내부에서 Service 직접 호출 — 순수 kube-proxy 분산
```bash
kubectl run tmp --rm -it --restart=Never -n c2-gateway --image=curlimages/curl:8.10.1 -- \
  sh -c 'for i in $(seq 20); do curl -s -m 5 http://c2-order-svc.c2-app.svc.cluster.local:8080/api/orders; echo; done' \
  | grep -o '"pod":"[^"]*"' | sort | uniq -c
```
기대: 파드명 2종이 섞여 나옴.
> `-n c2-gateway`인 이유: `c2-app` 네임스페이스는 NetworkPolicy로 `c2-gateway`에서 온 트래픽만 허용한다. `c2-app` 안에서 띄우면 같은 네임스페이스라도 차단된다.

## 8. NetworkPolicy 우회 차단

```bash
kubectl run tmp --rm -it --restart=Never -n default --image=curlimages/curl:8.10.1 -- \
  curl -m 5 -o /dev/null -w "%{http_code}\n" http://c2-order-svc.c2-app.svc.cluster.local:8080/api/orders
```
기대: `000` (타임아웃). `default` 네임스페이스에서는 게이트웨이를 우회해 접근할 수 없다.

```bash
kubectl get networkpolicy -n c2-app
kubectl -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[*].name}'; echo
```
기대: `allow-from-gateway`, `allow-from-alb` / `aws-node aws-eks-nodeagent` (nodeagent가 NetworkPolicy 시행 주체).

## 9. 자가 복구

터미널 1 — 요청 반복:
```bash
while true; do curl -s -o /dev/null -w "%{http_code} " http://$NLB/api/orders -H "Authorization: Bearer $TOKEN"; sleep 0.5; done
```
터미널 2 — 파드 삭제:
```bash
kubectl delete pod -n c2-app $(kubectl get pods -n c2-app -l app=c2-order-svc -o jsonpath='{.items[0].metadata.name}')
kubectl get pods -n c2-app -l app=c2-order-svc -w
```
기대: 터미널 1은 `200`만 찍히고, 터미널 2에서 새 파드가 뜸.

## 10. Ingress 비교 (요구사항 6)

```bash
ALB=$(kubectl get ingress -n c2-app c2-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); echo $ALB
curl -s -o /dev/null -w "%{http_code}\n" http://$ALB/api/orders          # 토큰 없음
curl -s http://$ALB/api/members/me -H "X-User-Id: hacker" | jq          # 헤더 위조
```
기대: **`200`** / **`"userId": "hacker"`** — Ingress에는 JWT 검증도 헤더 제거도 없다. 이것이 SCG와의 결정적 차이.

## 11. 전체 자동 실행

```bash
./scripts/verify.sh
```

## 12. c2 태그 확인

```bash
aws resourcegroupstaggingapi get-resources --region ap-northeast-2 --tag-filters Key=Owner,Values=c2 \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed 's|.*:||' | sort | head -50
```
