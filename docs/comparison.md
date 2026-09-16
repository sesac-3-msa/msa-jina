# 비교 학습: Ingress vs Spring Cloud Gateway / CoreDNS vs Eureka

> EKS 1.34, Spring Boot 3.5.15, Spring Cloud 2025.0.3 기준. 실제 배포 관찰 결과는 "실습에서 관찰한 것" 항목 참조.

---

## 1. Ingress (ALB) vs Spring Cloud Gateway (SCG)

이 실습에서는 둘을 **같은 클러스터에 동시에** 띄워 같은 백엔드(`c2-member-svc`, `c2-order-svc`)를 두 경로로 노출했다.

```
[클라이언트] ──> NLB ──> c2-gateway-svc 파드(SCG, JWT 검증) ──> c2-member-svc / c2-order-svc   (5단계)
[클라이언트] ──> ALB(Ingress) ─────────────────────────────> c2-member-svc / c2-order-svc   (6단계)
```

### 1-1. 비교표

| | Ingress (ALB) | Spring Cloud Gateway |
|---|---|---|
| 계층 | 플랫폼 (K8s 리소스) | 애플리케이션 (Java 프로세스) |
| 실체 | ALB — AWS 관리형 | 파드 — 직접 운영 (레플리카, 프로브, 리소스 관리 필요) |
| 라우팅 정의 | YAML (`Ingress` 리소스) | `application.yml` / Java DSL |
| 커스텀 로직 | 어노테이션 범위 내 | `GlobalFilter` / `GatewayFilter`로 무제한 |
| 인증 | ALB OIDC / Cognito 연동 정도 | JWT 검증 직접 구현 (이 실습) |
| 헤더 조작 | 제한적 (ALB 자체는 헤더 삽입/삭제 불가) | 자유 (`X-User-Id` 제거·주입) |
| 경로 추가 시 | YAML 적용만 (`kubectl apply`) | 재배포 또는 ConfigMap 갱신 + 재시작 |
| 장애 지점 | AWS가 관리 (SLA) | 파드가 죽으면 전체 다운 → 레플리카 필수 |
| 홉 수 | 1 (ALB → 파드) | 2 (NLB → SCG 파드 → 서비스 파드) |
| 관측성 | ALB 액세스 로그, CloudWatch | 애플리케이션 로그/메트릭 (Actuator) |
| 비용 | ALB 시간당 + LCU | NLB 시간당 + 파드 리소스 |

### 1-2. 코드 차이 — 경로 하나(`/api/payments`) 추가할 때

**Ingress** — YAML 한 블록, `kubectl apply`로 끝:
```yaml
- path: /api/payments
  pathType: Prefix
  backend:
    service: { name: payment-svc, port: { number: 8080 } }
```

**SCG** — `application.yml` 수정 후 게이트웨이 파드 재시작 필요:
```yaml
- id: payment
  uri: http://payment-svc.c2-app.svc.cluster.local:8080
  predicates:
    - Path=/api/payments/**
```

### 1-3. 코드 차이 — 인증을 넣을 때

**Ingress**: 요청 헤더를 읽어 검증하고 거부하는 로직을 **표현할 방법이 없다**. 선택지는
- ALB의 OIDC/Cognito 인증 어노테이션 (외부 IdP에 위임), 또는
- 각 백엔드 서비스가 스스로 JWT를 검증 (중복 구현), 또는
- 별도 인증 프록시(oauth2-proxy 등)를 사이에 끼움.

**SCG**: 필터 하나로 끝난다. 이 실습의 `JwtAuthenticationFilter`가 그것이다.
```java
public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
    // 1. 클라이언트가 보낸 X-User-Id 제거 (위조 차단)
    // 2. 화이트리스트(/api/auth/**, /actuator/**)면 통과
    // 3. Bearer 토큰 없으면 401
    // 4~5. 서명·만료 검증 실패 시 401
    // 6. 검증된 sub → X-User-Id 주입
    // 7. 다음 필터로
}
```
백엔드(`c2-member-svc`, `c2-order-svc`)는 JWT 라이브러리조차 없이 `X-User-Id` 헤더만 신뢰하면 된다. 단, 이 신뢰는 **게이트웨이를 우회할 수 없을 때만** 성립하므로 `c2-app` 네임스페이스에 NetworkPolicy로 `c2-gateway` 네임스페이스 외 인그레스를 차단했다.

### 1-4. 실습에서 관찰한 것

같은 백엔드를 NLB→SCG 경로와 ALB(Ingress) 경로로 각각 호출한 결과:

| 요청 | NLB → SCG | ALB (Ingress) |
|---|---|---|
| `GET /api/orders` 토큰 없음 | **401** | **200** |
| `GET /api/members/me` + `X-User-Id: hacker` (유효 토큰) | `userId: user1` (헤더 제거·재주입) | `userId: hacker` (그대로 전달) |
| 20회 `GET /api/orders` 파드 분포 | 16 : 4 (Netty 커넥션 재사용으로 쏠림) | — |

- **Ingress에는 JWT 검증이 없다.** ALB는 요청 헤더를 보고 거부하는 규칙을 표현할 수 없기 때문에, 토큰이 없어도 200이 나온다. 이 실습에서 SCG를 택한 이유가 정확히 이것이다.
- **NetworkPolicy와의 충돌**: `c2-app` 네임스페이스는 `c2-gateway` 네임스페이스만 허용하도록 잠겨 있어 ALB(퍼블릭 서브넷 ENI → 파드 IP)에서 오는 트래픽이 처음엔 막혔다. 비교를 위해 퍼블릭 서브넷 CIDR(`10.0.0.0/24`, `10.0.1.0/24`)을 허용하는 정책(`allow-from-alb`)을 추가해야 했다. **Ingress를 쓰면 뒷단 보호를 인증이 아니라 이런 네트워크 수단에 의존하게 된다.**
- **홉 수 차이가 응답 지연으로 보인다**: ALB는 파드로 직행하지만 SCG 경로는 NLB → SCG 파드 → 서비스 파드로 한 홉이 더 있다.
- **LB 컨트롤러는 같다**: 둘 다 AWS Load Balancer Controller가 만든다. Service(type=LoadBalancer, `aws-load-balancer-type: external`) → NLB, Ingress(class=alb) → ALB. 어노테이션 하나로 어느 쪽이 되는지가 갈린다.

### 1-5. 결론

- **플랫폼이 제공하는 것(TLS 종료, 경로 라우팅, 헬스체크)은 Ingress**가 싸고 안정적이다.
- **요청 내용을 보고 판단해야 하는 것(인증, 헤더 정규화, 레이트리밋, 요청 변환)은 SCG** 같은 앱 게이트웨이가 필요하다.
- 실무에서는 둘을 겹쳐 쓴다: `ALB(Ingress) → SCG → 서비스`. 이 실습은 SCG 앞에 NLB를 두는 단순 구성을 택했다.

---

## 2. CoreDNS (K8s Service) vs Netflix Eureka

### 2-1. 비교표

| | CoreDNS (K8s Service) | Netflix Eureka |
|---|---|---|
| 방식 | 서버 사이드 디스커버리 | 클라이언트 사이드 디스커버리 |
| 등록 주체 | 쿠버네티스 (파드 Ready 시 자동) | 애플리케이션 (기동 시 스스로 등록) |
| 목록 관리 | `Endpoints` / `EndpointSlice` 오브젝트 | Eureka 서버 인메모리 레지스트리 |
| 제거 시점 | 파드 종료·Not Ready 즉시 | 하트비트 만료 후 (기본 90초) |
| 추가 컴포넌트 | 없음 (CoreDNS는 클러스터 기본) | Eureka 서버 (HA면 2대 이상, 피어 복제) |
| 언어 종속 | 없음 (DNS는 어디서나) | Spring/Java 중심 |
| 로드밸런싱 | kube-proxy (iptables/IPVS, L4) | Spring Cloud LoadBalancer (클라이언트, L7) |
| 헬스체크 | readinessProbe → Endpoints 반영 | 하트비트 (30초 간격) + 자기보호 모드 |
| 호출 주소 | `http://c2-order-svc.c2-app.svc.cluster.local:8080` | `http://ORDER-SERVICE/...` (서비스 ID) |

### 2-2. 코드 차이

**CoreDNS** — 추가 의존성 없음. DNS 이름만 알면 된다. 이 실습의 게이트웨이가 정확히 이렇게 한다:
```yaml
# ansible/03-deploy.yml → gateway 환경변수
MEMBER_SERVICE_URL: http://c2-member-svc.c2-app.svc.cluster.local:8080
ORDER_SERVICE_URL:  http://c2-order-svc.c2-app.svc.cluster.local:8080
```
```yaml
# apps/gateway/src/main/resources/application.yml
- id: order
  uri: ${ORDER_SERVICE_URL}
  predicates:
    - Path=/api/orders/**
```

**Eureka** — 의존성·설정·서버 세 가지가 모두 필요:
```gradle
// 각 서비스 build.gradle
implementation 'org.springframework.cloud:spring-cloud-starter-netflix-eureka-client'
```
```yaml
# 각 서비스 application.yml
eureka:
  client:
    service-url:
      defaultZone: http://eureka-server:8761/eureka/
  instance:
    prefer-ip-address: true
```
```java
// 호출측 — 서비스 ID로 호출, 클라이언트가 인스턴스를 고른다
@LoadBalanced @Bean
WebClient.Builder webClientBuilder() { return WebClient.builder(); }

webClient.get().uri("http://ORDER-SERVICE/api/orders")
```
```yaml
# SCG 라우팅도 lb:// 스킴으로 바뀐다
- id: order
  uri: lb://ORDER-SERVICE
```
여기에 `@EnableEurekaServer`가 붙은 **Eureka 서버 애플리케이션을 별도로 만들어 파드로 배포**해야 한다.

### 2-3. 쿠버네티스 위에서 Eureka를 쓰면 생기는 문제

쿠버네티스의 Service/Endpoints는 Eureka가 하는 일(등록·목록·제거)을 이미 한다. 겹치는 정도가 아니라 **충돌**한다.

| 상황 | 쿠버네티스 | Eureka |
|---|---|---|
| 파드 삭제 (`kubectl delete pod`) | Endpoints에서 **즉시** 제거 → 트래픽 안 감 | 하트비트 만료(최대 90초)까지 살아 있다고 보고 → **사라진 파드로 요청 전송 → 오류** |
| 롤링 업데이트 | 새 파드 Ready 후 구 파드 제거, 무중단 | 구 파드 제거 후에도 레지스트리에 잔존 → 오류 구간 발생 |
| 스케일 아웃 | 즉시 반영 | 클라이언트 캐시 갱신(30초)까지 새 파드로 안 감 |

7단계 9번 시나리오(파드 삭제 중 무중단)가 CoreDNS 방식에서는 통과하지만, Eureka 방식이었다면 삭제된 파드로 요청이 나가는 구간이 생긴다.

### 2-4. 실습에서 관찰한 것

이 실습은 Eureka 없이 CoreDNS만으로 동작한다. 관찰한 것:

- 게이트웨이는 `http://c2-order-svc.c2-app.svc.cluster.local:8080` 라는 **DNS 이름만** 알고 있다. 파드 IP를 알 필요도, 레지스트리에 등록할 필요도 없다. order-service에는 디스커버리 관련 의존성이 한 줄도 없다(`build.gradle`에 web + actuator뿐).
- 클러스터 내부에서 `c2-order-svc`를 20회 직접 호출하면 두 파드가 6 : 14 로 섞여 나온다. kube-proxy가 Endpoints 목록을 보고 분산한 것이다. 클라이언트 쪽 로드밸런서(Spring Cloud LoadBalancer)가 없어도 된다.
- 게이트웨이를 경유하면 16 : 4 로 쏠린다. SCG의 Netty 클라이언트가 커넥션을 재사용하기 때문이며, DNS/kube-proxy는 **새 커넥션**을 맺을 때만 분산한다. Eureka + Spring Cloud LoadBalancer였다면 요청 단위 라운드로빈이 됐을 것이다 — 클라이언트 사이드 디스커버리의 장점 중 하나.
- `kubectl delete pod` 로 c2-order-svc 파드 하나를 지우는 동안 게이트웨이 경유 호출이 계속 200을 반환했다. 파드가 Terminating으로 바뀌는 순간 Endpoints에서 빠지므로 새 요청이 죽은 파드로 가지 않는다. Eureka였다면 하트비트 만료(최대 90초)까지 레지스트리에 남아 실패 응답이 섞였을 것이다.
- `-n default` 에서 같은 DNS 이름으로 호출하면 타임아웃된다. DNS 조회는 성공하지만(CoreDNS는 네임스페이스 구분 없이 응답) NetworkPolicy가 패킷을 막는다 — **디스커버리와 접근 제어는 별개 계층**이다. Eureka는 후자를 제공하지 않는다.

### 2-5. 결론

- Eureka는 **쿠버네티스 없던 시절**(VM/EC2 위 Spring 앱)의 서비스 디스커버리다. 그 환경에서는 필수였다.
- 쿠버네티스 위에서는 CoreDNS + Service가 같은 일을 더 빠르고(즉시 반영) 언어 중립적으로 한다. Eureka를 추가하면 운영할 컴포넌트가 늘고 상태 불일치 구간이 생긴다.
- Spring Cloud도 이를 인정해 `spring-cloud-kubernetes`(K8s API를 디스커버리 소스로 쓰는 어댑터)를 제공한다. 하지만 이 실습처럼 SCG가 DNS 이름으로 직접 호출하면 그것마저 필요 없다.
