# EKS + Spring Boot MSA 실습

AWS EKS 위에 Spring Boot 마이크로서비스 2개(회원, 주문)와 Spring Cloud Gateway를 배포하고,
JWT 인증 · 로드밸런싱 · NetworkPolicy · Ingress vs Gateway 비교까지 한 번에 체험하는 1일 실습 프로젝트입니다.

> 작업 지시서(스펙)는 [CLAUDE.md](CLAUDE.md), 검증 방법은 [docs/verify-guide.md](docs/verify-guide.md), 비교 학습 정리는 [docs/comparison.md](docs/comparison.md) 참고.

---

## 1. 무엇을 만드는가

```
                     인터넷
                        │
        ┌───────────────┴────────────────┐
        │                                │
   NLB (gateway 경로)               ALB (Ingress 경로, 비교용)
        │                                │
        ▼                                │
┌─────────────────────┐                  │
│ ns: c2-gateway      │                  │
│  c2-gateway-svc ×2  │  ← JWT 검증,      │  ← 인증 없음 (Ingress의 한계 관찰)
│  (Spring Cloud GW)  │    X-User-Id 주입  │
└─────────┬───────────┘                  │
          │ NetworkPolicy: c2-gateway 에서 온 것만 허용 (+ALB CIDR)
          ▼                              ▼
┌────────────────────────────────────────────────┐
│ ns: c2-app                                     │
│  c2-member-svc ×2   /api/auth/login (토큰 발급)  │
│                     /api/members, /api/members/me│
│  c2-order-svc  ×2   /api/orders GET/POST        │
└────────────────────────────────────────────────┘
        EKS 1.34 · 노드 t3.medium ×2 (프라이빗 서브넷) · VPC 10.0.0.0/16
```

| # | 강사 요구사항 | 이 프로젝트에서 달성한 방법 |
|---|---|---|
| 1 | VPC + EKS 클러스터 (노드 2개) | Terraform (`infra/`) |
| 2 | Spring Boot 마이크로서비스 2개 | `apps/member-service`, `apps/order-service` |
| 3 | Dockerfile로 이미지 생성 | 멀티스테이지 빌드 (`apps/*/Dockerfile`) |
| 4 | ECR에 이미지 저장 | 리포 3개 (`c2-gateway`, `c2-member-service`, `c2-order-service`) |
| 5 | 컨테이너 2개 이상 → 로드밸런싱 확인 | `replicas: 2` + 모든 응답에 `pod` 필드(파드명) 포함 |
| 6 | Ingress vs Spring Cloud Gateway | 둘 다 배포해 같은 백엔드를 두 경로로 비교 |
| 7 | CoreDNS vs Eureka | 문서 비교 + 코드 차이 ([docs/comparison.md](docs/comparison.md)) |
| 8 | 리소스 및 EKS 정리 | 아래 "9. 정리" 절차 |
| + | Gateway에서 JWT 검증 | `JwtAuthenticationFilter` (HS256, 헤더 위조 차단) |

---

## 2. 기술 스택

| 영역 | 도구 / 버전 | 비고 |
|---|---|---|
| 앱 | Spring Boot **3.5.15**, Spring Cloud **2025.0.3**, jjwt **0.12.6**, Java 17 | Boot ↔ Cloud 릴리스 트레인 호환 확인 후 고정 |
| 게이트웨이 | `spring-cloud-starter-gateway-server-webflux` | Spring Cloud 2025.0부터 바뀐 이름 (구: `spring-cloud-starter-gateway`) |
| 빌드 | Gradle 9.7.1 (wrapper) | |
| 컨테이너 | Docker 멀티스테이지, `eclipse-temurin:17` | |
| 인프라 | Terraform 1.16, AWS Provider 5.100, 모듈 vpc 5.21 / eks 20.37 / iam 5.60 | EKS 모듈 20.x = access entry 방식 |
| 클러스터 | EKS **1.34**, AL2023 노드, VPC CNI(NetworkPolicy 시행 ON) | |
| 배포 | Ansible + `kubernetes.core` 컬렉션, Helm (AWS LB Controller, Metrics Server) | |
| 리전 | `ap-northeast-2` (서울) | |

---

## 3. 디렉터리 구조

```
msa-jina/
├── CLAUDE.md                    # 작업 지시서 (스펙). 단계·검증 기준·규칙
├── README.md                    # 이 문서
├── .gitignore                   # tfstate, .terraform/, build/, *.jar, group_vars/all.yml 제외
│
├── apps/                        # ── 1~2단계: 애플리케이션 ──
│   ├── docker-compose.yml       #   로컬 통합 테스트 (게이트웨이만 :8080 노출)
│   ├── gateway/                 #   Spring Cloud Gateway (WebFlux)
│   │   ├── build.gradle / settings.gradle / gradlew / gradle/
│   │   ├── Dockerfile
│   │   └── src/main/
│   │       ├── java/com/practice/gateway/
│   │       │   ├── GatewayApplication.java
│   │       │   ├── config/RouteConfig.java            # JWT 키·화이트리스트 조립, 필터 빈 등록
│   │       │   └── filter/JwtAuthenticationFilter.java # ★ JWT 검증 GlobalFilter (보안 핵심)
│   │       └── resources/application.yml              # 라우팅 규칙 (MEMBER/ORDER_SERVICE_URL 환경변수)
│   ├── member-service/          #   회원 서비스 (JWT 발급 담당)
│   │   └── src/main/java/com/practice/member/
│   │       ├── MemberApplication.java
│   │       ├── controller/AuthController.java   # POST /api/auth/login → {token, pod}
│   │       ├── controller/MemberController.java # GET /api/members, /api/members/me
│   │       └── util/JwtProvider.java            # HS256 토큰 발급 (sub, role, exp)
│   └── order-service/           #   주문 서비스
│       └── src/main/java/com/practice/order/
│           ├── OrderApplication.java
│           └── controller/OrderController.java  # GET/POST /api/orders (인메모리 저장)
│
├── infra/                       # ── 3단계: Terraform ──
│   ├── provider.tf              #   AWS 프로바이더, default_tags (Owner=c2, Project, ManagedBy)
│   ├── variables.tf             #   name_prefix(c2), cluster_name, CIDR, 노드 수, ECR 리포명
│   ├── terraform.tfvars         #   실제 값 (region, cluster_name, name_prefix)
│   ├── main.tf                  #   caller identity, 공통 tags 로컬
│   ├── vpc.tf                   #   VPC 10.0.0.0/16, 2 AZ, NAT 1개, LB용 서브넷 태그
│   ├── eks.tf                   #   EKS 1.34, 노드그룹 t3.medium×2, IRSA, NodePort SG, vpc-cni NetworkPolicy ON
│   ├── iam.tf                   #   LB Controller IAM 정책(공식 JSON) + IRSA 역할
│   ├── iam-policy.json          #   aws-load-balancer-controller 공식 정책 (다운로드본)
│   ├── ecr.tf                   #   ECR 리포 3개 (force_delete)
│   └── outputs.tf               #   kubeconfig 명령, ECR URL, 역할 ARN, VPC/서브넷 정보
│
├── ansible/                     # ── 5~6단계: 쿠버네티스 배포 ──
│   ├── ansible.cfg / inventory  #   localhost 실행
│   ├── group_vars/all.yml       #   (자동 생성, git 제외) Terraform output + 이미지 태그 + JWT 시크릿
│   ├── 01-addons.yml            #   Helm: AWS Load Balancer Controller, Metrics Server
│   ├── 02-namespace.yml         #   네임스페이스 c2-gateway/c2-app, jwt-secret, NetworkPolicy
│   ├── 03-deploy.yml            #   Deployment 3개 + Service 3개 (gateway만 NLB)
│   ├── 04-ingress.yml           #   비교용 ALB Ingress + ALB 허용 NetworkPolicy
│   └── templates/
│       ├── deployment.yaml.j2   #   replicas 2, POD_NAME/JWT_SECRET env, 프로브, 안티어피니티
│       ├── service.yaml.j2      #   NLB 어노테이션 (type external, ip 타겟)
│       └── networkpolicy.yaml.j2#   namespaceSelector / ipBlock 인그레스 허용
│
├── scripts/
│   ├── build-and-push.sh        #   4단계: 이미지 3개 빌드 → ECR 푸시 (태그 = git short SHA)
│   ├── gen-ansible-vars.sh      #   Terraform output → ansible/group_vars/all.yml 생성
│   └── verify.sh                #   7단계: 검증 시나리오 10개 자동 실행
│
└── docs/
    ├── verify-guide.md          #   검증 명령어를 직접 치며 확인하는 가이드
    └── comparison.md            #   Ingress vs SCG, CoreDNS vs Eureka 비교 + 실측 결과
```

---

## 4. 핵심 설계 포인트

### 4-1. JWT 검증은 게이트웨이에서만 한다
- `member-service`가 로그인 시 HS256 토큰을 발급하고, `gateway`의 `JwtAuthenticationFilter`가 모든 요청을 검증합니다.
- 두 서비스는 **같은 `JWT_SECRET`**(K8s Secret `jwt-secret`)을 사용합니다. 다르면 모든 요청이 401입니다.
- 필터 처리 순서(보안 포인트):
  1. 클라이언트가 보낸 `X-User-Id` 헤더를 **무조건 제거**
  2. 화이트리스트(`/api/auth/**`, `/actuator/**`)면 통과
  3. `Authorization: Bearer` 없음 → 401
  4. 서명 검증 실패 / 만료 → 401
  5. 토큰의 `sub`를 `X-User-Id`로 **재주입** → 백엔드로 전달
- 백엔드(`member`, `order`)는 JWT 라이브러리 없이 `X-User-Id` 헤더만 믿습니다.

### 4-2. 그 신뢰가 성립하려면 게이트웨이를 우회할 수 없어야 한다
- `c2-app` 네임스페이스에 NetworkPolicy `allow-from-gateway`: **`c2-gateway` 네임스페이스에서 온 트래픽만** 허용.
- EKS는 기본적으로 NetworkPolicy를 시행하지 않으므로 `vpc-cni` 애드온에 `enableNetworkPolicy=true`를 켰습니다 (`infra/eks.tf`).
- 비교용 ALB Ingress를 띄울 때는 ALB가 있는 퍼블릭 서브넷 CIDR을 추가로 허용(`allow-from-alb`)해야 했습니다 — Ingress를 쓰면 뒷단 보호를 인증이 아니라 네트워크에 의존하게 된다는 관찰 포인트.

### 4-3. 로드밸런싱을 눈으로 확인한다
- 모든 API 응답에 `"pod": "<파드명>"` 필드가 들어갑니다 (`POD_NAME` 환경변수 ← `metadata.name`).
- `replicas: 2` + `podAntiAffinity`로 같은 앱의 두 파드가 서로 다른 노드에 뜹니다.
- 게이트웨이 경유 호출은 SCG의 Netty 커넥션 재사용 때문에 한쪽으로 쏠려 보일 수 있고, 클러스터 내부에서 Service를 직접 호출하면 kube-proxy 분산이 그대로 보입니다.

### 4-4. 공유 계정이므로 모든 리소스에 `c2`
- AWS 리소스 이름: `c2-eks-msa-practice`, `c2-eks-msa-practice-node`(EC2), `c2-gateway`(ECR) 등. `name_prefix`/`cluster_name` 변수로 관리.
- 모든 AWS 리소스에 `Owner=c2` 태그 (프로바이더 `default_tags` + EKS/VPC 모듈 `tags`).
- K8s 리소스: 네임스페이스 `c2-gateway`/`c2-app`, 서비스 `c2-gateway-svc`/`c2-member-svc`/`c2-order-svc`. Ansible `k8s_prefix` 변수로 관리.

---

## 5. 실행 순서

### 전제 조건
`aws`(자격증명 설정됨), `terraform ≥ 1.5`, `kubectl`, `helm`, `ansible` + `kubernetes.core` 컬렉션, `docker`, `java 17+`, `jq`.

### 1~2단계. 앱 빌드 및 로컬 확인 (클러스터 불필요)
```bash
cd apps/gateway && ./gradlew build && cd ../member-service && ./gradlew build && cd ../order-service && ./gradlew build
```
```bash
cd apps && docker compose up -d --build
```
로컬 `http://localhost:8080`으로 401 / 로그인 / 인증 호출 / 헤더 위조 확인 후:
```bash
cd apps && docker compose down
```

### 3단계. 인프라 생성 (약 20~25분, 과금 시작)
```bash
cd infra && terraform init && terraform plan
```
```bash
cd infra && terraform apply
```
```bash
$(terraform -chdir=infra output -raw kubeconfig_command) && kubectl get nodes
```

### 4단계. 이미지 빌드 → ECR 푸시
```bash
./scripts/build-and-push.sh
```
마지막 줄의 `TAG=xxxxxxx`를 다음 단계에 씁니다.

### 5~6단계. 쿠버네티스 배포
```bash
./scripts/gen-ansible-vars.sh <TAG>
```
```bash
cd ansible && ansible-playbook 01-addons.yml && ansible-playbook 02-namespace.yml && ansible-playbook 03-deploy.yml && ansible-playbook 04-ingress.yml
```
NLB/ALB 주소가 출력됩니다. 실제 응답까지 2~3분 더 걸립니다.

### 7단계. 검증
[docs/verify-guide.md](docs/verify-guide.md)를 따라 직접 확인하거나, 한 번에:
```bash
./scripts/verify.sh
```

### 8단계. 비교 학습
[docs/comparison.md](docs/comparison.md) — Ingress vs SCG, CoreDNS vs Eureka.

### 9단계. 정리 (반드시! 시간당 약 $0.26 과금)
순서를 지켜야 합니다. LB Controller가 만든 NLB/ALB를 먼저 지우지 않으면 `terraform destroy`가 VPC에서 멈춥니다.
```bash
kubectl delete ingress -n c2-app c2-app-ingress && kubectl delete svc -n c2-gateway c2-gateway-svc
```
```bash
aws elbv2 describe-load-balancers --region ap-northeast-2 --query 'LoadBalancers[].LoadBalancerName'
```
(빈 목록 `[]`이 될 때까지 1~2분 대기)
```bash
kubectl delete ns c2-app c2-gateway
```
```bash
cd infra && terraform destroy
```
잔여 확인: EC2, ALB/NLB, ENI, NAT Gateway, Elastic IP, VPC, ECR, CloudWatch 로그 그룹 `/aws/eks/c2-eks-msa-practice/cluster`.

---

## 6. API 요약

| 메서드 | 경로 | 인증 | 응답 예 |
|---|---|---|---|
| POST | `/api/auth/login` | 불필요 | `{"token":"eyJ...","pod":"c2-member-svc-..."}` |
| GET | `/api/members` | 필요 | `{"pod":"...","data":[{"id":"user1","name":"Alice"},...]}` |
| GET | `/api/members/me` | 필요 | `{"pod":"...","userId":"user1"}` |
| GET | `/api/orders` | 필요 | `{"pod":"...","data":[...]}` |
| POST | `/api/orders` | 필요 | `{"pod":"...","orderId":"order-xxxxxxxx"}` |

로그인 계정: `user1/pass1`, `user2/pass2` (인메모리).
토큰 없이 호출하면 게이트웨이가 **본문 없는 401**을 반환합니다.

---

## 7. 자주 막히는 지점

| 증상 | 원인 | 확인 |
|---|---|---|
| 노드가 Ready 안 됨 | 프라이빗 라우팅 테이블에 NAT 경로 없음 | 라우팅 테이블 |
| Service/Ingress가 pending | 서브넷 `kubernetes.io/role/elb` 태그 누락 | 서브넷 태그 |
| LB Controller는 Running인데 LB 안 생김 | 서비스어카운트 IRSA 어노테이션 누락 | `kubectl describe sa -n kube-system aws-load-balancer-controller` |
| NLB 주소 있는데 응답 `000` | 타겟 헬스체크 아직 진행 중 (2~3분) / `/actuator/health` 미노출 | 콘솔 타겟 그룹 |
| 게이트웨이 502 | 라우팅 URI와 Service 이름 불일치 | `kubectl get svc -n c2-app` |
| `ImagePullBackOff` | ECR URL/태그 불일치 | `kubectl describe pod` |
| 계속 401 | gateway와 member의 `JWT_SECRET` 불일치 | 두 네임스페이스 Secret 비교 |
| 검증 파드가 `c2-app`에서 멈춤 | NetworkPolicy가 같은 네임스페이스 내 호출도 차단 | 검증 파드는 `-n c2-gateway`로 |
| 노드그룹 IAM 역할 생성 실패 | `name_prefix` 38자 초과 | `iam_role_use_name_prefix = false` (적용됨) |
