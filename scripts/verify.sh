#!/usr/bin/env bash
# 7단계 검증 시나리오를 한 번에 실행한다. 저장소 루트에서 실행.
#   ./scripts/verify.sh
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "=== [$1] $2 ==="; }

NLB=$(kubectl get svc -n gateway gateway-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
if [[ -z "$NLB" ]]; then echo "NLB 주소를 찾을 수 없음"; exit 1; fi
echo "NLB: $NLB"

step 1 "노드 2개 Ready"
kubectl get nodes
READY=$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l)
[[ "$READY" -eq 2 ]] && ok "Ready 노드 $READY개" || fail "Ready 노드 $READY개 (기대 2)"

step 2 "파드 6개 Running (두 노드에 분산)"
kubectl get pods -n gateway -o wide; kubectl get pods -n app -o wide
RUNNING=$( { kubectl get pods -n gateway --no-headers; kubectl get pods -n app --no-headers; } | awk '$3=="Running"' | wc -l)
[[ "$RUNNING" -eq 6 ]] && ok "Running 파드 $RUNNING개" || fail "Running 파드 $RUNNING개 (기대 6)"

step 3 "미인증 차단 → 401"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "http://$NLB/api/orders")
[[ "$CODE" == "401" ]] && ok "HTTP $CODE" || fail "HTTP $CODE (기대 401)"

step 4 "로그인 → 토큰"
LOGIN=$(curl -s -m 10 -X POST "http://$NLB/api/auth/login" -H 'Content-Type: application/json' -d '{"username":"user1","password":"pass1"}')
TOKEN=$(echo "$LOGIN" | jq -r '.token // empty')
echo "  $(echo "$LOGIN" | jq -c '{pod, token: (.token // "" | .[0:20] + "...")}')"
[[ -n "$TOKEN" ]] && ok "토큰 발급 (pod=$(echo "$LOGIN" | jq -r .pod))" || fail "토큰 없음"

step 5 "인증 호출 → 200 + pod 필드"
RESP=$(curl -s -m 10 -w '\n%{http_code}' "http://$NLB/api/orders" -H "Authorization: Bearer $TOKEN")
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | head -n -1)
echo "  $(echo "$BODY" | jq -c '{pod, count: (.data|length)}')"
[[ "$CODE" == "200" && $(echo "$BODY" | jq -r '.pod // empty') != "" ]] && ok "HTTP 200, pod=$(echo "$BODY" | jq -r .pod)" || fail "HTTP $CODE"

step 6 "헤더 위조 (X-User-Id: hacker) → 무시"
UID_=$(curl -s -m 10 "http://$NLB/api/members/me" -H "Authorization: Bearer $TOKEN" -H "X-User-Id: hacker" | jq -r .userId)
[[ "$UID_" == "user1" ]] && ok "userId=$UID_" || fail "userId=$UID_ (기대 user1)"

step 7a "로드밸런싱 — 게이트웨이 경유 20회 (Netty 커넥션 재사용으로 쏠릴 수 있음)"
for i in $(seq 20); do curl -s -m 10 "http://$NLB/api/orders" -H "Authorization: Bearer $TOKEN" | jq -r .pod; done | sort | uniq -c | sed 's/^/  /'

step 7b "로드밸런싱 — 클러스터 내부(gateway ns)에서 order-svc 직접 호출 20회"
# NetworkPolicy가 gateway 네임스페이스만 허용하므로 검증 파드도 gateway에서 띄운다 (app ns 내부 파드끼리도 차단됨)
INNER=$(kubectl run lb-check --rm -i --restart=Never -n gateway --image=curlimages/curl:8.10.1 -q -- \
  sh -c 'for i in $(seq 20); do curl -s -m 5 http://order-svc.app.svc.cluster.local:8080/api/orders; echo; done' 2>/dev/null | grep -o '"pod":"[^"]*"' | sort | uniq -c)
echo "$INNER" | sed 's/^/  /'
DISTINCT=$(echo "$INNER" | wc -l)
[[ "$DISTINCT" -ge 2 ]] && ok "파드 $DISTINCT종으로 분산" || fail "파드 $DISTINCT종 (기대 2)"

step 8 "NetworkPolicy 우회 차단 — default 네임스페이스에서 order-svc 접근 → 타임아웃"
kubectl run np-check --rm -i --restart=Never -n default --image=curlimages/curl:8.10.1 -q -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}' http://order-svc.app.svc.cluster.local:8080/api/orders > /tmp/np_out 2>&1
NPCODE=$(grep -oE '^[0-9]{3}' /tmp/np_out | head -1)
if [[ "$NPCODE" == "000" || -z "$NPCODE" ]]; then ok "연결 차단됨 (timeout)"; else fail "HTTP $NPCODE — 차단되지 않음"; fi

step 9 "자가 복구 — order-svc 파드 1개 삭제 후 무중단 확인"
VICTIM=$(kubectl get pods -n app -l app=order-svc -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n app "$VICTIM" --wait=false >/dev/null
ERRORS=0
for i in $(seq 10); do
  C=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$NLB/api/orders" -H "Authorization: Bearer $TOKEN")
  [[ "$C" != "200" ]] && ERRORS=$((ERRORS+1)); sleep 1
done
kubectl rollout status deploy/order-svc -n app --timeout=120s >/dev/null
kubectl get pods -n app -l app=order-svc
[[ "$ERRORS" -eq 0 ]] && ok "삭제 중 10회 호출 모두 200, 파드 재생성됨" || fail "삭제 중 실패 $ERRORS회"

step 10 "Ingress 비교 — ALB로 토큰 없이 호출 → 200 (JWT 검증 없음)"
ALB=$(kubectl get ingress -n app app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [[ -z "$ALB" ]]; then
  echo "  (Ingress 미배포 — ansible-playbook ansible/04-ingress.yml 실행 후 재확인)"
else
  CODE=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "http://$ALB/api/orders")
  [[ "$CODE" == "200" ]] && ok "ALB 토큰 없이 HTTP $CODE — Ingress는 인증을 못 한다" || fail "HTTP $CODE (기대 200)"
fi

echo; echo "==== 결과: PASS=$PASS FAIL=$FAIL ===="
[[ "$FAIL" -eq 0 ]]
