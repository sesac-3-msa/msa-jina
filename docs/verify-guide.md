# 검증 가이드 — 직접 명령어로 확인하기 (초보자용 해설 포함)

> 저장소 루트(`msa-jina/`)에서 실행합니다. 각 단계의 "기대" 값이 나오면 통과입니다.
> 명령어마다 "무슨 뜻인지"를 옵션 단위로 풀어 썼습니다. 이미 아는 부분은 건너뛰세요.

---

## 0-1. 먼저 알아둘 셸 기본 문법

이 가이드의 명령어에 반복해서 나오는 것들입니다.

| 문법 | 뜻 | 예 |
|---|---|---|
| `A \| B` | 파이프. A의 출력을 B의 입력으로 넘긴다 | `kubectl get pods \| grep order` → 파드 목록 중 order가 들어간 줄만 |
| `$(명령)` | 명령을 실행한 **결과 문자열**로 바꿔치기 | `NLB=$(kubectl ...)` → kubectl 결과를 NLB 변수에 저장 |
| `변수=값` / `$변수` | 변수 저장 / 꺼내 쓰기. `=` 양옆에 공백 없음 | `NLB=abc.com` 후 `echo $NLB` |
| `;` | 명령을 한 줄에 이어서 실행 | `A; B` → A 하고 B |
| `&&` | 앞 명령이 성공했을 때만 뒤 명령 실행 | `A && B` |
| `\` (줄 끝) | 명령이 다음 줄로 이어짐 (가독성용 줄바꿈) | |
| `#` | 주석. 뒤는 실행되지 않음 | |
| `for i in $(seq 20); do ...; done` | 20번 반복 | |

`kubectl` 공통 옵션:

| 옵션 | 뜻 |
|---|---|
| `-n <이름>` | 네임스페이스 지정. 쿠버네티스 안의 "폴더" 같은 것. 이 프로젝트는 `c2-gateway`, `c2-app` 두 개를 씀 |
| `-o wide` | 출력을 넓게(IP, 노드 이름 등 컬럼 추가) |
| `-o jsonpath='{...}'` | 결과 JSON에서 **특정 값만** 꺼냄 |
| `-l key=value` | 라벨로 필터 |
| `-w` | watch. 변화가 생길 때마다 계속 출력 (Ctrl+C로 종료) |

`curl` 공통 옵션:

| 옵션 | 뜻 |
|---|---|
| `-s` | silent. 진행률 표시 숨김 |
| `-o /dev/null` | 응답 본문을 버림 (상태 코드만 볼 때) |
| `-w "%{http_code}\n"` | 요청 끝나고 HTTP 상태 코드(200, 401 등)를 출력 |
| `-X POST` | HTTP 메서드 지정 (기본은 GET) |
| `-H "이름: 값"` | 요청 헤더 추가 |
| `-d '...'` | 요청 본문(body) |
| `-m 5` | 5초 안에 응답 없으면 포기(timeout) |

`jq`: JSON을 예쁘게 출력하거나 특정 필드를 꺼내는 도구. `jq` 만 쓰면 전체를 정렬해 보여주고, `jq -r .token` 은 `token` 필드 값만 따옴표 없이(-r = raw) 출력.

---

## 0-2. 준비

```bash
$(terraform -chdir=infra output -raw kubeconfig_command)
```
**해설**
- `terraform -chdir=infra output -raw kubeconfig_command` : `infra/` 폴더의 Terraform 상태에서 `kubeconfig_command`라는 output 값을 꺼낸다. 값은 `aws eks update-kubeconfig --region ap-northeast-2 --name c2-eks-msa-practice` 라는 **문자열**이다. `-raw`는 따옴표 없이 출력하라는 뜻.
- 바깥의 `$( ... )` : 그 문자열을 **명령어로 실행**한다.
- 결과: `aws eks update-kubeconfig ...`가 실행되어 `~/.kube/config`에 우리 클러스터 접속 정보가 추가된다. 이걸 해야 `kubectl`이 어느 클러스터에 붙을지 안다.

```bash
NLB=$(kubectl get svc -n c2-gateway c2-gateway-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); echo $NLB
```
**해설**
- `kubectl get svc` : Service 목록 조회. `svc`는 `service`의 줄임.
- `-n c2-gateway c2-gateway-svc` : `c2-gateway` 네임스페이스의 `c2-gateway-svc`라는 Service 하나만.
- `-o jsonpath='{.status.loadBalancer.ingress[0].hostname}'` : 이 Service의 JSON 중 `status → loadBalancer → ingress 배열의 0번째 → hostname` 값만 꺼낸다. 이게 **NLB 주소**다.
- `NLB=$( ... )` : 그 주소를 `NLB` 변수에 저장. 이후 `$NLB`로 사용.
- `; echo $NLB` : 저장된 값을 화면에 출력해 확인.

> 터미널을 새로 열면 변수가 사라집니다. 그때는 이 줄을 다시 실행하세요.

---

## 1. 노드 2개 Ready (요구사항 1)

```bash
kubectl get nodes -o wide
```
**해설**
- `kubectl get nodes` : 클러스터의 워커 노드(EC2 인스턴스) 목록.
- `-o wide` : INTERNAL-IP, OS, 컨테이너 런타임 등 컬럼 추가.

**기대**: `STATUS`가 `Ready`인 줄 2개. `INTERNAL-IP`가 `10.0.10.x`와 `10.0.11.x` — 각각 다른 AZ의 프라이빗 서브넷에 있다는 뜻.

```bash
aws ec2 describe-instances --region ap-northeast-2 --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Owner:Tags[?Key==`Owner`]|[0].Value,Type:InstanceType}' --output table
```
**해설**
- `aws ec2 describe-instances` : EC2 인스턴스 정보 조회.
- `--region ap-northeast-2` : 서울 리전.
- `--filters Name=instance-state-name,Values=running` : 실행 중인 것만.
- `--query '...'` : 결과 JSON에서 필요한 것만 뽑는 식(JMESPath 문법).
  - `Reservations[].Instances[]` : 모든 인스턴스를 평평하게 나열.
  - `.{Name: ..., Owner: ..., Type: ...}` : 각 인스턴스를 세 컬럼으로 재구성.
  - ``Tags[?Key==`Name`]|[0].Value`` : 태그 배열 중 Key가 `Name`인 것을 찾아 첫 번째의 Value. (태그는 `[{Key:..., Value:...}, ...]` 형태라 이렇게 꺼내야 한다.)
- `--output table` : 표 형태로 출력.

**기대**: `Name`이 `c2-eks-msa-practice-node`, `Owner`가 `c2`, `Type`이 `t3.medium`인 줄 2개. (같은 계정에 다른 사람 인스턴스도 보일 수 있음 — `c2`로 구분)

---

## 2. 파드 6개 Running, 두 노드에 분산 (요구사항 5)

```bash
kubectl get pods -n c2-gateway -o wide
kubectl get pods -n c2-app -o wide
```
**해설**
- `kubectl get pods` : 파드(컨테이너가 실행되는 단위) 목록.
- `-n c2-gateway` / `-n c2-app` : 네임스페이스별로 따로 조회. 게이트웨이는 `c2-gateway`, 회원/주문은 `c2-app`에 있다.
- `-o wide` : 파드 IP와 어느 노드(`NODE` 컬럼)에 떠 있는지 표시.

**기대**: `c2-gateway-svc-xxx` 2개, `c2-member-svc-xxx` 2개, `c2-order-svc-xxx` 2개, 모두 `Running`. 같은 앱의 두 파드가 **서로 다른 NODE**에 있음 (podAntiAffinity 효과).

---

## 3. 미인증 차단 → 401

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://$NLB/api/orders
```
**해설**
- `curl http://$NLB/api/orders` : NLB 주소로 주문 목록 API 호출. 토큰(Authorization 헤더)을 **일부러 안 붙임**.
- `-s` : 진행률 숨김.
- `-o /dev/null` : 응답 본문은 버림.
- `-w "%{http_code}\n"` : 상태 코드만 출력.

**기대**: `401` (Unauthorized). 게이트웨이의 JWT 필터가 토큰 없는 요청을 막았다는 뜻.

---

## 4. 로그인 → 토큰

```bash
TOKEN=$(curl -s -X POST http://$NLB/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"user1","password":"pass1"}' | jq -r .token); echo $TOKEN
```
**해설**
- `curl -X POST http://$NLB/api/auth/login` : 로그인 API에 POST 요청.
- `-H 'Content-Type: application/json'` : "본문이 JSON이다"라고 서버에 알림.
- `-d '{"username":"user1","password":"pass1"}'` : 본문. 인메모리 계정 `user1/pass1`.
- `| jq -r .token` : 응답 JSON `{"token":"eyJ...","pod":"..."}`에서 `token` 값만 따옴표 없이 꺼냄.
- `TOKEN=$( ... )` : 그 값을 `TOKEN` 변수에 저장. 이후 요청에서 `$TOKEN`으로 사용.
- `; echo $TOKEN` : 확인 출력.

**기대**: `eyJhbGciOiJIUzI1NiJ9.eyJzdWIi...` 처럼 점(`.`) 두 개로 나뉜 긴 문자열. 이게 JWT다. (헤더.페이로드.서명)

토큰 안을 들여다보기:
```bash
echo $TOKEN | cut -d. -f1 | base64 -d; echo
echo $TOKEN | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null; echo
```
**해설**
- `cut -d. -f1` : 점(`.`)으로 잘라 1번째 조각(헤더). `-f2`는 2번째(페이로드).
- `base64 -d` : base64 디코딩. JWT의 헤더·페이로드는 암호화가 아니라 **단순 인코딩**이라 누구나 읽을 수 있다. (서명이 있어서 **위조**만 못 한다.)
- `tr '_-' '/+'` : JWT는 URL-safe base64를 써서 `_`,`-`를 쓰는데, 일반 `base64` 명령은 `/`,`+`를 기대하므로 바꿔준다.
- `2>/dev/null` : 패딩 경고 메시지 숨김. `; echo` : 줄바꿈.

**기대**: 1번째 줄 `{"alg":"HS256"}` / 2번째 줄 `{"sub":"user1","role":"USER","iat":...,"exp":...}`.
`sub`=사용자 ID, `role`=역할, `iat`=발급 시각, `exp`=만료 시각(발급+1시간, 유닉스 초).

---

## 5. 인증 호출 → 200 + pod 필드

```bash
curl -s http://$NLB/api/orders -H "Authorization: Bearer $TOKEN" | jq
curl -s http://$NLB/api/members -H "Authorization: Bearer $TOKEN" | jq
```
**해설**
- `-H "Authorization: Bearer $TOKEN"` : 표준 방식의 토큰 전달. `Bearer ` 뒤에 토큰을 붙인다. 게이트웨이 필터가 이 헤더를 읽어 검증한다.
- `| jq` : 응답 JSON을 들여쓰기해서 보기 좋게.

**기대**: `{"pod":"c2-order-svc-xxxx","data":[...]}` 처럼 `pod` 필드에 **응답한 파드 이름**이 들어 있음. 이 필드가 7번 로드밸런싱 확인의 근거다.

---

## 6. 헤더 위조 → 무시

```bash
curl -s http://$NLB/api/members/me -H "Authorization: Bearer $TOKEN" -H "X-User-Id: hacker" | jq
```
**해설**
- `/api/members/me` : "내 정보" API. 백엔드는 `X-User-Id` 헤더를 보고 누구인지 판단한다.
- `-H "X-User-Id: hacker"` : 클라이언트가 **직접** 이 헤더를 끼워 넣어 남인 척 시도.
- 유효한 토큰(`user1`)도 함께 보냄.

**기대**: `"userId": "user1"`. `hacker`가 아니어야 한다. 게이트웨이가 (1) 클라이언트가 보낸 `X-User-Id`를 **지우고** (2) 토큰 안의 `sub`(`user1`)를 **다시 넣어** 백엔드로 보냈기 때문이다. 이 순서가 이 실습의 핵심 보안 포인트.

---

## 7. 로드밸런싱 (요구사항 5)

### 7a. 게이트웨이 경유 — 쏠릴 수 있음
```bash
for i in $(seq 20); do
  curl -s http://$NLB/api/orders -H "Authorization: Bearer $TOKEN" | jq -r .pod
done | sort | uniq -c
```
**해설**
- `for i in $(seq 20); do ... done` : 20번 반복.
- 반복 안: 주문 API를 호출해 `pod` 값(파드 이름)만 한 줄씩 출력.
- `| sort | uniq -c` : 같은 이름끼리 모아 개수를 센다. (`uniq -c`는 연속된 중복만 세므로 먼저 `sort` 필요)

**기대**: 예 `16 c2-order-svc-aaa` / `4 c2-order-svc-bbb`. 두 파드 이름이 나오되 **한쪽으로 쏠려도 정상**. Spring Cloud Gateway의 Netty 클라이언트가 백엔드와 맺은 연결을 재사용하기 때문에, 연결이 살아 있는 동안은 같은 파드로 간다. 버그가 아니라 커넥션 풀의 동작이다.

### 7b. 클러스터 내부에서 Service 직접 호출 — 순수 kube-proxy 분산
```bash
kubectl run tmp --rm -it --restart=Never -n c2-gateway --image=curlimages/curl:8.10.1 -- \
  sh -c 'for i in $(seq 20); do curl -s -m 5 http://c2-order-svc.c2-app.svc.cluster.local:8080/api/orders; echo; done' \
  | grep -o '"pod":"[^"]*"' | sort | uniq -c
```
**해설**
- `kubectl run tmp` : `tmp`라는 이름의 임시 파드를 하나 띄운다.
- `--image=curlimages/curl:8.10.1` : curl만 들어 있는 작은 이미지 사용.
- `--rm` : 끝나면 파드 자동 삭제. `-it` : 터미널을 붙여 출력을 바로 본다. `--restart=Never` : 죽어도 재시작하지 않음(일회성).
- `-n c2-gateway` : **`c2-gateway` 네임스페이스에** 띄운다 (이유는 아래).
- `-- sh -c '...'` : 파드 안에서 실행할 명령. 20번 curl.
- `http://c2-order-svc.c2-app.svc.cluster.local:8080` : 클러스터 내부 DNS 이름. 형식은 `<서비스명>.<네임스페이스>.svc.cluster.local`. CoreDNS가 이 이름을 Service IP로 바꿔주고, kube-proxy가 파드 2개로 분산한다.
- `-m 5` : 5초 타임아웃 (막혀 있으면 무한정 기다리지 않도록).
- `| grep -o '"pod":"[^"]*"'` : 응답에서 `"pod":"..."` 부분만 추출. `-o`는 매치된 부분만 출력.
- `| sort | uniq -c` : 개수 세기.

**기대**: 두 파드 이름이 **섞여** 나온다 (예 `6 : 14`). 매 요청이 새 연결이므로 kube-proxy 분산이 그대로 보인다.

> **왜 `-n c2-gateway`인가?** `c2-app` 네임스페이스에는 "`c2-gateway`에서 온 트래픽만 허용"하는 NetworkPolicy가 걸려 있다. 임시 파드를 `c2-app`에 띄우면 같은 네임스페이스라도 차단되어 curl이 타임아웃된다. (실제로 처음에 그렇게 막혔다.)

---

## 8. NetworkPolicy 우회 차단

```bash
kubectl run tmp --rm -it --restart=Never -n default --image=curlimages/curl:8.10.1 -- \
  curl -m 5 -o /dev/null -w "%{http_code}\n" http://c2-order-svc.c2-app.svc.cluster.local:8080/api/orders
```
**해설**
- 7b와 같은 임시 파드지만 **`-n default`** (기본 네임스페이스)에 띄운다. 게이트웨이를 거치지 않고 주문 서비스에 직접 접근하는 "우회 시도".
- `-m 5 -o /dev/null -w "%{http_code}\n"` : 5초 기다리고 상태 코드만 출력.

**기대**: `000` — 응답을 아예 못 받고 타임아웃. `default` 네임스페이스는 허용 목록에 없으므로 NetworkPolicy가 패킷을 버린다. (DNS 이름은 해석되지만 연결이 안 됨 → 디스커버리와 접근 제어는 별개 계층.)
파드 자체는 `pod "tmp" deleted` 또는 exit 코드 경고와 함께 정리된다.

```bash
kubectl get networkpolicy -n c2-app
kubectl -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[*].name}'; echo
```
**해설**
- `kubectl get networkpolicy -n c2-app` : `c2-app`에 적용된 NetworkPolicy 목록.
- `kubectl -n kube-system get ds aws-node` : `kube-system` 네임스페이스의 DaemonSet(`ds`) `aws-node` = VPC CNI(네트워크 플러그인). `-o jsonpath='{.spec.template.spec.containers[*].name}'`로 그 안의 컨테이너 이름들만 출력.

**기대**: `allow-from-gateway`, `allow-from-alb` 두 정책 / `aws-node aws-eks-nodeagent`. 두 번째 컨테이너 `aws-eks-nodeagent`가 NetworkPolicy를 실제로 시행하는 주체다. EKS는 기본값으로 이걸 켜지 않으므로 Terraform에서 `enableNetworkPolicy=true`로 켰다 — 안 켜면 정책은 저장만 되고 아무것도 막지 않는다.

---

## 9. 자가 복구

터미널을 2개 엽니다. (새 터미널에서는 0-2의 `NLB=`, 4의 `TOKEN=` 줄을 다시 실행해야 변수가 있습니다.)

**터미널 1** — 0.5초마다 계속 호출:
```bash
while true; do curl -s -o /dev/null -w "%{http_code} " http://$NLB/api/orders -H "Authorization: Bearer $TOKEN"; sleep 0.5; done
```
**해설**
- `while true; do ...; done` : 무한 반복 (Ctrl+C로 종료).
- 상태 코드를 공백으로 이어서 출력 → `200 200 200 ...` 이 계속 찍힌다.
- `sleep 0.5` : 0.5초 쉬기.

**터미널 2** — 파드 하나를 죽이고 지켜보기:
```bash
kubectl delete pod -n c2-app $(kubectl get pods -n c2-app -l app=c2-order-svc -o jsonpath='{.items[0].metadata.name}')
kubectl get pods -n c2-app -l app=c2-order-svc -w
```
**해설**
- 안쪽 `kubectl get pods -n c2-app -l app=c2-order-svc -o jsonpath='{.items[0].metadata.name}'` : 라벨 `app=c2-order-svc`인 파드 중 첫 번째의 이름을 꺼낸다.
- 바깥 `kubectl delete pod -n c2-app <그 이름>` : 그 파드를 삭제.
- `kubectl get pods ... -w` : 파드 목록을 계속 감시. `Terminating` → 새 파드 `ContainerCreating` → `Running` 으로 바뀌는 과정이 보인다. Ctrl+C로 종료.

**기대**: 터미널 1은 `200`만 찍히고(중단 없음), 터미널 2에서 이름이 다른 새 파드가 생긴다. Deployment가 `replicas: 2`를 유지하려고 즉시 재생성하고, 죽는 파드는 Endpoints에서 바로 빠져 트래픽이 살아 있는 파드로만 간다.

---

## 10. Ingress 비교 (요구사항 6)

```bash
ALB=$(kubectl get ingress -n c2-app c2-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); echo $ALB
```
**해설**: 0-2에서 NLB 주소를 꺼낸 것과 같은 방식으로, 이번엔 Ingress 리소스에서 **ALB 주소**를 꺼내 `ALB` 변수에 저장.

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://$ALB/api/orders
```
**해설**: 3번과 똑같이 토큰 없이 호출하되, NLB(게이트웨이 경로)가 아니라 **ALB(Ingress 경로)**로.

**기대**: **`200`**. 3번에서는 401이었는데 여기선 통과한다. Ingress(ALB)에는 JWT를 검사하는 기능이 없기 때문이다.

```bash
curl -s http://$ALB/api/members/me -H "X-User-Id: hacker" | jq
```
**해설**: 6번의 헤더 위조를 ALB 경로로.

**기대**: **`"userId": "hacker"`**. 위조가 그대로 통한다. ALB는 헤더를 지우거나 바꾸지 못한다.

→ 이것이 Ingress와 Spring Cloud Gateway의 결정적 차이다. 자세한 비교는 [comparison.md](comparison.md).

---

## 11. 전체 자동 실행

```bash
./scripts/verify.sh
```
**해설**: 위 1~10번을 스크립트로 한 번에 실행하고 PASS/FAIL을 센다. 9번(자가 복구)은 파드를 실제로 하나 삭제한다.

---

## 12. c2 태그 확인

```bash
aws resourcegroupstaggingapi get-resources --region ap-northeast-2 --tag-filters Key=Owner,Values=c2 \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed 's|.*:||' | sort | head -50
```
**해설**
- `aws resourcegroupstaggingapi get-resources` : 태그로 AWS 리소스를 검색하는 API.
- `--tag-filters Key=Owner,Values=c2` : `Owner=c2` 태그가 붙은 것만.
- `--query 'ResourceTagMappingList[].ResourceARN' --output text` : 리소스 ARN(고유 식별자)만 텍스트로. 탭으로 구분되어 한 줄에 나온다.
- `| tr '\t' '\n'` : 탭을 줄바꿈으로 바꿔 한 줄에 하나씩.
- `| sed 's|.*:||'` : ARN 앞부분(`arn:aws:ec2:ap-northeast-2:계정:`)을 지우고 마지막 콜론 뒤(리소스 이름/ID)만 남김.
- `| sort | head -50` : 정렬 후 앞 50개.

**기대**: `cluster/c2-eks-msa-practice`, `vpc/vpc-xxx`, `subnet/...`, `natgateway/...`, `repository/c2-gateway`, `instance/i-...`, `loadbalancer/...` 등 이 프로젝트가 만든 리소스가 모두 `Owner=c2`로 잡힌다.

---

## 부록: 자주 나오는 결과 해석

| 결과 | 뜻 |
|---|---|
| `000` | curl이 응답을 아예 못 받음 (연결 실패/타임아웃). LB 생성 직후라면 2~3분 기다렸다 재시도. 8번에서는 이게 정답 |
| `401` | 인증 실패. 토큰 없음/틀림/만료 |
| `404` | 경로가 없음. URL 오타 확인 |
| `502`/`503` | 게이트웨이는 살아 있는데 뒷단 서비스에 못 붙음. `kubectl get svc -n c2-app`으로 서비스 이름 확인 |
| `error: You must be logged in` / `Unauthorized` (kubectl) | kubeconfig가 없거나 만료. 0-2의 첫 줄 재실행 |
| `jq: error ... Cannot iterate over null` | 응답이 기대한 JSON이 아님. `jq` 빼고 원문을 먼저 확인 |
| `pod "tmp" already exists` | 이전 임시 파드가 남아 있음. `kubectl delete pod tmp -n <네임스페이스>` 후 재실행 |
