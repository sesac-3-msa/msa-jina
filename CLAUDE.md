# EKS + Spring Boot MSA 실습 작업 지시서

> 개인 실습 / 1일 완주
> Claude Code 실행용 스펙 문서

---

## 0. Claude Code 작업 규칙

**이 문서를 읽는 에이전트는 아래 규칙을 먼저 따른다.**

1. **단계는 순서대로 진행한다.** 각 단계 끝의 "검증" 항목을 실행해 기대 출력이 나오기 전에는 다음 단계로 넘어가지 않는다.
2. **`terraform apply`와 `terraform destroy`는 반드시 사용자 확인을 받고 실행한다.** 비용이 발생하는 명령이다. `-auto-approve`를 임의로 붙이지 않는다.
3. **AWS 계정 ID, 리전, 클러스터명은 변수로 처리한다.** 코드에 하드코딩하지 않는다. 계정 ID가 필요하면 `aws sts get-caller-identity --query Account --output text`로 조회한다.
4. **라이브러리 버전은 추측하지 않는다.** Spring Boot와 Spring Cloud는 릴리스 트레인 호환성이 엄격하다. `build.gradle` 작성 전에 사용 중인 Spring Boot 버전에 맞는 Spring Cloud BOM 버전을 확인한다. 의존성 이름도 버전에 따라 다르다 (예: 구버전 `spring-cloud-starter-gateway` → 신버전 `spring-cloud-starter-gateway-server-webflux`).
5. **한 단계에서 3회 이상 같은 오류가 반복되면 진행을 멈추고 사용자에게 상황을 보고한다.** 추측으로 설정을 바꿔가며 반복 시도하지 않는다.
6. **실습 종료 시 9단계 정리를 반드시 수행한다.** EKS 클러스터와 NAT Gateway는 시간당 과금된다.
7. 생성한 파일은 커밋하되, `terraform.tfstate`, `.terraform/`, `*.jar`, `build/`는 `.gitignore`에 넣는다.

---

## 1. 목표

강사 요구사항 기준 완료 조건이다. 각 항목은 9단계 검증에서 다시 확인한다.

| # | 요구사항 | 달성 방법 |
|---|---|---|
| 1 | VPC 및 EKS 클러스터 (노드 2개) | Terraform |
| 2 | Spring Boot 마이크로서비스 2개 (회원, 주문) | `/api/members`, `/api/orders` |
| 3 | Dockerfile로 이미지 생성 | 멀티스테이지 빌드 |
| 4 | 이미지를 ECR에 저장 | 리포 3개 |
| 5 | 컨테이너 2개 이상 → 로드밸런싱 확인 | `replicas: 2` + 응답에 파드명 포함 |
| 6 | Ingress vs Spring Cloud Gateway 학습 | 둘 다 배포해 비교 (10장) |
| 7 | CoreDNS vs Eureka 학습 | 문서 비교 + 코드 차이 (10장) |
| 8 | 마지막에 K8s 리소스 및 EKS 정리 | 9단계 체크리스트 |

추가로 넣는 것: Spring Cloud Gateway에서 JWT 검증.

---

## 2. 전제 조건

작업 시작 전 아래를 확인한다. 하나라도 실패하면 진행하지 않고 사용자에게 알린다.

```bash
aws sts get-caller-identity          # AWS 자격증명
terraform version                    # 1.5 이상
kubectl version --client
helm version
ansible --version
docker info                          # 데몬 실행 중
java -version                        # 17 이상
```

Ansible 컬렉션 설치:

```bash
ansible-galaxy collection install kubernetes.core
pip install kubernetes
```

리전은 `ap-northeast-2` 고정.

---

## 3. 디렉터리 구조

아래 구조를 그대로 만든다.

```
eks-msa-practice/
├── apps/
│   ├── gateway/
│   │   ├── build.gradle
│   │   ├── settings.gradle
│   │   ├── Dockerfile
│   │   └── src/main/java/com/practice/gateway/
│   │       ├── GatewayApplication.java
│   │       ├── config/RouteConfig.java
│   │       └── filter/JwtAuthenticationFilter.java
│   ├── member-service/
│   │   ├── build.gradle
│   │   ├── settings.gradle
│   │   ├── Dockerfile
│   │   └── src/main/java/com/practice/member/
│   │       ├── MemberApplication.java
│   │       ├── controller/MemberController.java
│   │       ├── controller/AuthController.java
│   │       └── util/JwtProvider.java
│   ├── order-service/
│   │   ├── build.gradle
│   │   ├── settings.gradle
│   │   ├── Dockerfile
│   │   └── src/main/java/com/practice/order/
│   │       ├── OrderApplication.java
│   │       └── controller/OrderController.java
│   └── docker-compose.yml
├── infra/
│   ├── main.tf
│   ├── provider.tf
│   ├── variables.tf
│   ├── vpc.tf
│   ├── eks.tf
│   ├── iam.tf
│   ├── ecr.tf
│   ├── outputs.tf
│   └── terraform.tfvars
├── ansible/
│   ├── ansible.cfg
│   ├── inventory
│   ├── group_vars/all.yml
│   ├── 01-addons.yml
│   ├── 02-namespace.yml
│   ├── 03-deploy.yml
│   ├── 04-ingress.yml
│   └── templates/
│       ├── deployment.yaml.j2
│       ├── service.yaml.j2
│       └── networkpolicy.yaml.j2
├── scripts/
│   ├── build-and-push.sh
│   └── verify.sh
└── docs/
    └── comparison.md
```

---

## 4. 1단계 — 애플리케이션

클러스터가 없어도 되는 단계다. 여기부터 시작한다.

### 4-1. 공통 계약

**이 값들은 세 프로젝트에서 동일해야 한다.**

| 항목 | 값 |
|---|---|
| 포트 | `8080` |
| 헬스체크 | `/actuator/health` |
| JWT 알고리즘 | HS256 |
| JWT 시크릿 환경변수 | `JWT_SECRET` (최소 32바이트) |
| JWT 클레임 | `sub`(userId), `role`, `exp` |
| 파드명 환경변수 | `POD_NAME` |
| 사용자 식별 헤더 | `X-User-Id` |

### 4-2. API 계약

| 메서드 | 경로 | 인증 | 응답 |
|---|---|---|---|
| POST | `/api/auth/login` | 불필요 | `{"token": "...", "pod": "..."}` |
| GET | `/api/members` | 필요 | `{"pod": "...", "data": [...]}` |
| GET | `/api/members/me` | 필요 | `{"pod": "...", "userId": "..."}` |
| GET | `/api/orders` | 필요 | `{"pod": "...", "data": [...]}` |
| POST | `/api/orders` | 필요 | `{"pod": "...", "orderId": "..."}` |

로그인 요청 바디: `{"username": "user1", "password": "pass1"}`

인메모리 사용자는 `user1/pass1`, `user2/pass2` 두 개로 충분하다.

### 4-3. 로드밸런싱 확인용 구현 (요구사항 5번)

**모든 응답에 `pod` 필드를 넣는다.** 이게 없으면 레플리카 2개를 띄워도 분산을 증명할 방법이 없다.

```java
@Value("${POD_NAME:local}")
private String podName;

@GetMapping("/api/orders")
public Map<String, Object> list() {
    return Map.of("pod", podName, "data", store.values());
}
```

### 4-4. JWT 구현 (jjwt 0.12.x 기준)

**발급 — member-service의 `JwtProvider`**

```java
private final SecretKey key = Keys.hmacShaKeyFor(
    System.getenv("JWT_SECRET").getBytes(StandardCharsets.UTF_8));

public String issue(String userId, String role) {
    return Jwts.builder()
        .subject(userId)
        .claim("role", role)
        .issuedAt(new Date())
        .expiration(new Date(System.currentTimeMillis() + 3600_000))
        .signWith(key)
        .compact();
}
```

**검증 — gateway의 `JwtAuthenticationFilter`**

```java
Claims claims = Jwts.parser()
    .verifyWith(key)
    .build()
    .parseSignedClaims(token)
    .getPayload();
```

> jjwt 0.11 이하는 API가 다르다 (`parserBuilder()`, `setSubject()` 등). 사용 중인 버전에 맞춰 작성한다.

### 4-5. 게이트웨이 필터 처리 순서

**순서를 반드시 지킨다.**

1. 요청 경로가 화이트리스트(`/api/auth/**`, `/actuator/**`)면 통과
2. **클라이언트가 보낸 `X-User-Id` 헤더를 제거**
3. `Authorization: Bearer <token>` 파싱 → 없으면 401
4. 서명 검증 → 실패 시 401
5. `exp` 만료 확인 → 만료 시 401
6. 토큰의 `sub`를 `X-User-Id` 헤더로 주입
7. 다음 필터로 전달

> 2번이 3~6번보다 먼저여야 한다. 순서가 반대면 화이트리스트 경로로 헤더 위조가 통과한다. 이건 실습의 보안 포인트이므로 생략하지 않는다.

401 응답은 본문 없이 상태코드만 반환한다.

### 4-6. 라우팅

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: member
          uri: ${MEMBER_SERVICE_URL}
          predicates:
            - Path=/api/members/**,/api/auth/**
        - id: order
          uri: ${ORDER_SERVICE_URL}
          predicates:
            - Path=/api/orders/**
```

URL을 환경변수로 뺀다. 로컬(docker-compose)과 클러스터에서 값이 다르기 때문이다.

- 로컬: `http://member-service:8080`
- 클러스터: `http://member-svc.app.svc.cluster.local:8080`

### 검증 1단계

```bash
cd apps/gateway && ./gradlew build
cd ../member-service && ./gradlew build
cd ../order-service && ./gradlew build
```

세 프로젝트 모두 BUILD SUCCESSFUL.

---

## 5. 2단계 — Dockerfile 및 로컬 통합 확인

### 5-1. Dockerfile (세 프로젝트 공통 템플릿)

```dockerfile
FROM eclipse-temurin:17-jdk-alpine AS build
WORKDIR /app
COPY gradle gradle
COPY gradlew build.gradle settings.gradle ./
RUN chmod +x gradlew && ./gradlew dependencies --no-daemon
COPY src src
RUN ./gradlew bootJar --no-daemon

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /app/build/libs/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 5-2. docker-compose.yml

세 서비스를 띄우고 `JWT_SECRET`을 동일하게 주입한다. 게이트웨이만 호스트 포트 8080에 노출한다.

### 검증 2단계

```bash
cd apps && docker compose up -d --build

# 토큰 없이 호출 → 401 이어야 함
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/api/orders

# 로그인
TOKEN=$(curl -s -X POST http://localhost:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"user1","password":"pass1"}' | jq -r .token)

# 인증 호출 → 200 + pod 필드
curl -s http://localhost:8080/api/orders -H "Authorization: Bearer $TOKEN" | jq

# 헤더 위조 시도 → X-User-Id가 무시되어야 함
curl -s http://localhost:8080/api/members/me \
  -H "Authorization: Bearer $TOKEN" -H "X-User-Id: hacker" | jq
```

기대 결과: 401 / 200 / `userId`가 `hacker`가 아닌 실제 토큰의 `sub`.

**이 단계가 통과하기 전에는 절대 클러스터로 넘어가지 않는다.** 클러스터에서 디버깅하면 원인이 앱인지 네트워크인지 구분되지 않는다.

```bash
docker compose down
```

---

## 6. 3단계 — Terraform

### 6-1. 사용할 모듈

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"
}
```

EKS 모듈 20.x는 access entry 방식을 쓴다. 구버전의 `aws-auth` ConfigMap 방식과 다르므로 혼용하지 않는다.

### 6-2. VPC 요구사항

| 항목 | 값 |
|---|---|
| CIDR | `10.0.0.0/16` |
| AZ | `ap-northeast-2a`, `ap-northeast-2c` |
| 퍼블릭 서브넷 | `10.0.0.0/24`, `10.0.1.0/24` |
| 프라이빗 서브넷 | `10.0.10.0/24`, `10.0.11.0/24` |
| NAT Gateway | 1개 (`single_nat_gateway = true`) |

**서브넷 태그는 반드시 넣는다.**

```hcl
public_subnet_tags = {
  "kubernetes.io/role/elb" = "1"
}
private_subnet_tags = {
  "kubernetes.io/role/internal-elb" = "1"
}
```

없으면 로드밸런서가 서브넷을 찾지 못해 Service와 Ingress가 pending에 머문다.

### 6-3. EKS 요구사항

- 노드그룹: `t3.medium` × **2대** (min 2, max 2, desired 2) — 요구사항 1번
- `subnet_ids`에 **프라이빗 서브넷만** 지정
- `enable_irsa = true`
- 퍼블릭 엔드포인트 활성화 (로컬에서 kubectl 접속)
- 노드 SG 인바운드에 NodePort `30000-32767` 추가

### 6-4. IAM

LB Controller용 IRSA 역할을 만든다. IAM 정책은 AWS가 배포하는 공식 JSON을 사용한다. 직접 작성하면 권한이 누락되어 컨트롤러가 조용히 실패한다.

```bash
curl -o iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

서비스어카운트는 `kube-system:aws-load-balancer-controller`로 신뢰 관계를 건다.

### 6-5. ECR

리포 3개: `gateway`, `member-service`, `order-service`.
`force_delete = true`를 넣는다. 이미지가 남아 있으면 destroy가 실패한다.

### 6-6. outputs.tf

```hcl
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
output "lb_controller_role_arn" { value = module.lb_controller_irsa.iam_role_arn }
output "ecr_gateway_url"        { value = aws_ecr_repository.gateway.repository_url }
output "ecr_member_url"         { value = aws_ecr_repository.member.repository_url }
output "ecr_order_url"          { value = aws_ecr_repository.order.repository_url }
```

### 검증 3단계

```bash
cd infra
terraform init
terraform validate
terraform plan
```

plan 결과를 사용자에게 보여주고 승인을 받은 뒤 apply한다.

```bash
terraform apply
```

NAT 포함 20~25분 소요.

```bash
$(terraform output -raw kubeconfig_command)
kubectl get nodes
```

기대 출력: 노드 2개, 둘 다 `Ready`.

> 노드가 뜨지 않으면 프라이빗 라우팅 테이블의 NAT 경로를 확인한다. NAT가 없으면 노드가 컨트롤 플레인에 등록조차 못 한다.

---

## 7. 4단계 — 이미지 빌드 및 ECR 푸시

`scripts/build-and-push.sh`를 작성한다. Terraform output에서 ECR URL을 읽어오게 한다.

```bash
#!/usr/bin/env bash
set -euo pipefail

REGION=ap-northeast-2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
TAG=$(git rev-parse --short HEAD)

aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com

for svc in gateway member-service order-service; do
  REPO=$(terraform -chdir=infra output -raw ecr_${svc%%-*}_url)
  docker build -t $REPO:$TAG apps/$svc
  docker push $REPO:$TAG
done

echo "TAG=$TAG"
```

> `ecr_${svc%%-*}_url` 부분은 output 이름 규칙에 맞게 조정한다. 이름이 어긋나면 스크립트가 조용히 빈 값으로 동작하므로, 각 URL이 비어 있지 않은지 확인하는 로직을 넣는다.

### 검증 4단계

```bash
aws ecr describe-images --repository-name gateway --region ap-northeast-2
```

세 리포 모두 이미지 태그가 조회되어야 한다.

---

## 8. 5단계 — Ansible 배포

### 8-1. group_vars/all.yml

Terraform output 값을 여기에 채운다. 하드코딩하지 말고 실행 시 `--extra-vars`로 주입하거나, 스크립트로 output을 읽어 생성한다.

```yaml
cluster_name: "{{ lookup('env', 'CLUSTER_NAME') }}"
lb_controller_role_arn: "..."
image_tag: "..."
ecr_gateway: "..."
ecr_member: "..."
ecr_order: "..."
```

### 8-2. 01-addons.yml

`kubernetes.core.helm`으로 AWS Load Balancer Controller와 Metrics Server 설치.

```yaml
- name: Install AWS Load Balancer Controller
  kubernetes.core.helm:
    name: aws-load-balancer-controller
    chart_ref: eks/aws-load-balancer-controller
    release_namespace: kube-system
    values:
      clusterName: "{{ cluster_name }}"
      serviceAccount:
        create: true
        name: aws-load-balancer-controller
        annotations:
          eks.amazonaws.com/role-arn: "{{ lb_controller_role_arn }}"
```

Helm 리포 추가(`https://aws.github.io/eks-charts`)를 선행 태스크로 넣는다.

> 어노테이션이 빠지면 컨트롤러 파드는 Running인데 로드밸런서 생성만 실패한다. 증상이 조용해서 찾기 어렵다.

### 8-3. 02-namespace.yml

- 네임스페이스 `gateway`, `app` 생성
- `JWT_SECRET`을 담은 Secret을 두 네임스페이스에 각각 생성
- `app` 네임스페이스에 NetworkPolicy — `gateway` 네임스페이스에서 온 인그레스만 허용

### 8-4. 03-deploy.yml

Deployment 3개, Service 3개.

**Deployment 필수 항목**

```yaml
spec:
  replicas: 2          # 요구사항 5번
  template:
    spec:
      containers:
        - name: app
          image: "{{ ecr_order }}:{{ image_tag }}"
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: jwt-secret
                  key: secret
          readinessProbe:
            httpGet: { path: /actuator/health, port: 8080 }
            initialDelaySeconds: 20
          livenessProbe:
            httpGet: { path: /actuator/health, port: 8080 }
            initialDelaySeconds: 40
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels: { app: order-svc }
```

안티어피니티를 넣으면 두 파드가 서로 다른 노드에 뜬다. 로드밸런싱 시연이 더 명확해진다.

**Service 이름은 고정한다.** 게이트웨이 라우팅 URI와 일치해야 한다.

- `gateway-svc` (ns: gateway)
- `member-svc` (ns: app)
- `order-svc` (ns: app)

**gateway-svc만 LoadBalancer 타입**

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
```

> `aws-load-balancer-type`은 `external`이어야 한다. `nlb`로 쓰면 EKS 내장 컨트롤러가 처리해 ip 모드가 적용되지 않는다.

나머지 두 Service는 `ClusterIP`.

### 검증 5단계

```bash
ansible-playbook ansible/01-addons.yml
kubectl -n kube-system get pods | grep load-balancer   # Running

ansible-playbook ansible/02-namespace.yml
ansible-playbook ansible/03-deploy.yml

kubectl get pods -A -o wide
```

기대 출력: 파드 6개 Running (게이트웨이 2, 회원 2, 주문 2), 두 노드에 분산.

```bash
kubectl get svc -n gateway gateway-svc
```

`EXTERNAL-IP`에 NLB 주소가 나온다. 실제 연결 가능까지 2~3분 더 걸린다.

---

## 9. 6단계 — Ingress 병행 배포 (요구사항 6번)

SCG와 별개로 ALB Ingress를 하나 더 띄운다. 같은 클러스터에 공존하므로 두 경로를 비교할 수 있다.

`ansible/04-ingress.yml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  namespace: app
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /api/members
            pathType: Prefix
            backend:
              service:
                name: member-svc
                port: { number: 8080 }
          - path: /api/orders
            pathType: Prefix
            backend:
              service:
                name: order-svc
                port: { number: 8080 }
```

> **주의**: NetworkPolicy가 `gateway` 네임스페이스만 허용하고 있으면 ALB에서 오는 트래픽이 차단된다. 비교 실습 중에는 NetworkPolicy를 일시 해제하거나, ALB 노드 CIDR을 허용하는 규칙을 추가한다. **이 차이 자체가 비교 학습의 핵심 관찰 포인트다** — Ingress는 인증을 못 하므로 뒷단 보호를 다른 수단에 의존해야 한다.

### 검증 6단계

```bash
kubectl get ingress -n app
```

ALB 주소가 나오면 토큰 없이 호출해본다. **200이 나온다.** Ingress에는 JWT 검증이 없기 때문이다. 이게 SCG와의 결정적 차이다.

---

## 10. 7단계 — 검증 시나리오

`scripts/verify.sh`로 작성해 한 번에 돌릴 수 있게 한다.

```bash
NLB=$(kubectl get svc -n gateway gateway-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

| # | 항목 | 명령 | 기대 |
|---|---|---|---|
| 1 | 노드 2개 | `kubectl get nodes` | Ready 2개 |
| 2 | 파드 6개 | `kubectl get pods -A` | Running |
| 3 | 미인증 차단 | `curl -o /dev/null -w "%{http_code}" http://$NLB/api/orders` | `401` |
| 4 | 로그인 | `curl -X POST http://$NLB/api/auth/login ...` | 토큰 반환 |
| 5 | 인증 호출 | `curl http://$NLB/api/orders -H "Authorization: Bearer $TOKEN"` | `200` + pod 필드 |
| 6 | 헤더 위조 | `-H "X-User-Id: hacker"` 추가 | `hacker` 아님 |
| 7 | **로드밸런싱** | 아래 참조 | 파드명 2종 |
| 8 | 우회 차단 | 아래 참조 | 연결 실패 |
| 9 | 자가 복구 | `kubectl delete pod ...` | 재생성, 무중단 |
| 10 | Ingress 비교 | ALB로 토큰 없이 호출 | `200` |

### 7번 — 로드밸런싱 확인 (요구사항 5번)

```bash
for i in $(seq 20); do
  curl -s http://$NLB/api/orders -H "Authorization: Bearer $TOKEN" | jq -r .pod
done | sort | uniq -c
```

**게이트웨이를 경유하면 한쪽으로 쏠려 보일 수 있다.** SCG의 Netty 클라이언트가 커넥션 풀을 재사용하기 때문이다. 이건 버그가 아니라 정상 동작이며, 설명할 수 있어야 한다.

순수한 분산 확인은 클러스터 내부에서 Service를 직접 호출한다.

```bash
kubectl run tmp --rm -it --restart=Never -n app \
  --image=curlimages/curl -- sh -c \
  'for i in $(seq 20); do curl -s http://order-svc:8080/api/orders; echo; done'
```

두 파드 이름이 섞여 나오면 kube-proxy 분산이 동작하는 것이다.

### 8번 — NetworkPolicy 우회 차단

```bash
kubectl run tmp --rm -it --restart=Never -n default \
  --image=curlimages/curl -- \
  curl -m 5 http://order-svc.app.svc.cluster.local:8080/api/orders
```

타임아웃되면 정상이다. `default` 네임스페이스에서는 접근할 수 없어야 한다.

---

## 11. 8단계 — 비교 학습 문서 작성

`docs/comparison.md`에 아래 내용을 정리한다. 실제 배포해본 결과를 포함시킨다.

### 11-1. Ingress vs Spring Cloud Gateway

| | Ingress (ALB) | Spring Cloud Gateway |
|---|---|---|
| 계층 | 플랫폼 (K8s 리소스) | 애플리케이션 (Java 프로세스) |
| 실체 | ALB — AWS 관리형 | 파드 — 직접 운영 |
| 라우팅 정의 | YAML | `application.yml` / Java DSL |
| 커스텀 로직 | 어노테이션 범위 내 | 필터로 무제한 |
| 인증 | ALB OIDC 연동 정도 | JWT 검증 직접 구현 |
| 경로 추가 시 | YAML 적용만 | 재배포 또는 ConfigMap 갱신 + 재시작 |
| 장애 지점 | AWS가 관리 | 파드가 죽으면 전체 다운 |
| 홉 수 | 1 | 2 (NLB → SCG → 서비스) |

**코드 차이 — 경로 하나 추가할 때**

Ingress:
```yaml
- path: /api/payments
  pathType: Prefix
  backend:
    service: { name: payment-svc, port: { number: 8080 } }
```

SCG:
```yaml
- id: payment
  uri: http://payment-svc.app.svc.cluster.local:8080
  predicates:
    - Path=/api/payments/**
```

전자는 `kubectl apply`로 끝나고, 후자는 게이트웨이 재시작이 필요하다.

**실습에서 관찰한 것**: ALB 경로로 토큰 없이 호출하면 200이 나온다. Ingress는 요청 본문이나 헤더를 검사해 거부하는 로직을 표현할 수 없기 때문이다. 이 실습에서 SCG를 택한 이유가 정확히 이것이다.

### 11-2. CoreDNS vs Netflix Eureka

| | CoreDNS (K8s Service) | Netflix Eureka |
|---|---|---|
| 방식 | 서버 사이드 디스커버리 | 클라이언트 사이드 디스커버리 |
| 등록 주체 | 쿠버네티스 (자동) | 애플리케이션 (스스로 등록) |
| 목록 관리 | Endpoints 오브젝트 | Eureka 서버 레지스트리 |
| 제거 시점 | 파드 종료 즉시 | 하트비트 만료 후 (기본 90초) |
| 추가 컴포넌트 | 없음 | Eureka 서버 (HA면 2대 이상) |
| 언어 종속 | 없음 | Spring/Java 중심 |
| 로드밸런싱 | kube-proxy | Spring Cloud LoadBalancer |

**코드 차이**

CoreDNS — 추가 의존성 없음:
```yaml
order.service.url: http://order-svc.app.svc.cluster.local:8080
```

Eureka — 의존성·설정·서버 모두 필요:
```gradle
implementation 'org.springframework.cloud:spring-cloud-starter-netflix-eureka-client'
```
```yaml
eureka:
  client:
    service-url:
      defaultZone: http://eureka-server:8761/eureka/
```
```java
@LoadBalanced @Bean
WebClient.Builder webClientBuilder() { return WebClient.builder(); }
// 호출부는 서비스 ID로
webClient.get().uri("http://ORDER-SERVICE/api/orders")
```

여기에 Eureka 서버 애플리케이션을 별도로 만들어 배포해야 한다.

**결론**: 쿠버네티스 위에서는 Service와 Endpoints가 Eureka와 같은 일을 한다. 겹치는 정도가 아니라 충돌한다. 파드가 종료되면 쿠버네티스는 즉시 Endpoints에서 빼지만 Eureka는 하트비트 만료까지 살아 있다고 보고해, 그 구간 동안 사라진 파드로 요청이 나간다.

**여유가 있으면**: Eureka 서버를 파드로 하나 띄우고 order-service에 클라이언트를 붙여 실제 코드 차이를 확인한다. 시간이 부족하면 문서 비교로 충분하다.

---

## 12. 9단계 — 정리 (요구사항 8번)

**순서를 반드시 지킨다.**

```bash
# 1. LB Controller가 만든 리소스부터 삭제
kubectl delete ingress -n app app-ingress
kubectl delete svc -n gateway gateway-svc

# 2. ALB, NLB가 사라졌는지 확인 (1~2분 대기)
aws elbv2 describe-load-balancers --region ap-northeast-2 \
  --query 'LoadBalancers[].LoadBalancerName'

# 3. 네임스페이스 정리
kubectl delete ns app gateway

# 4. Terraform 정리 — 사용자 확인 후 실행
cd infra && terraform destroy
```

### 잔여 확인 체크리스트

- [ ] EC2 인스턴스 없음
- [ ] ALB / NLB 없음
- [ ] ENI 없음
- [ ] NAT Gateway 없음
- [ ] Elastic IP 없음 (NAT에 붙어 있던 것)
- [ ] VPC 없음
- [ ] ECR 리포 없음
- [ ] CloudWatch 로그 그룹 `/aws/eks/<클러스터명>/cluster` 삭제

> `terraform destroy`가 VPC 삭제에서 멈추면 거의 항상 ENI가 남아 있는 것이다. 1단계를 건너뛴 경우 발생한다. 콘솔에서 해당 VPC의 네트워크 인터페이스를 찾아 어떤 리소스가 붙잡고 있는지 확인한다.

---

## 13. 자주 막히는 지점

| 증상 | 원인 | 확인 |
|---|---|---|
| 노드가 Ready 안 됨 | 프라이빗 라우팅 테이블에 NAT 경로 없음 | 라우팅 테이블 |
| Service가 pending | 서브넷 `kubernetes.io/role/elb` 태그 누락 | 서브넷 태그 |
| LB Controller Running인데 LB 생성 안 됨 | 서비스어카운트 IRSA 어노테이션 누락 | `kubectl describe sa -n kube-system aws-load-balancer-controller` |
| NLB 주소 있는데 응답 없음 | 타겟 그룹 헬스체크 실패 | 콘솔 타겟 그룹 상태, `/actuator/health` 노출 여부 |
| 게이트웨이 502 | 라우팅 URI 오타 또는 Service 이름 불일치 | `kubectl get svc -n app` |
| `ImagePullBackOff` | NAT 없음, ECR URL/태그 불일치, 노드 역할 ECR 권한 | `kubectl describe pod` |
| 401이 계속 나옴 | `JWT_SECRET`이 gateway와 member에서 다름 | 두 네임스페이스 Secret 값 비교 |
| 로드밸런싱 안 되는 것처럼 보임 | SCG Netty 커넥션 재사용 | 클러스터 내부 직접 호출로 재확인 |