package com.practice.gateway.filter;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.JwtParser;
import io.jsonwebtoken.Jwts;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.util.AntPathMatcher;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import javax.crypto.SecretKey;
import java.util.List;

/**
 * 게이트웨이 전역 JWT 검증 필터.
 *
 * 처리 순서 (CLAUDE.md 4-5):
 *  1. 화이트리스트 경로면 통과
 *  2. 클라이언트가 보낸 X-User-Id 제거  ← 3~6보다 반드시 먼저
 *  3. Authorization: Bearer 파싱 → 없으면 401
 *  4. 서명 검증 → 실패 시 401
 *  5. exp 만료 확인 → 만료 시 401  (jjwt가 파싱 시점에 ExpiredJwtException으로 함께 처리)
 *  6. sub → X-User-Id 헤더 주입
 *  7. 다음 필터로
 *
 * 화이트리스트 경로라도 클라이언트의 X-User-Id는 신뢰하지 않으므로, 2번 제거는 1번보다 먼저 수행한다.
 * (1→2 순서보다 엄격하며, 스펙의 보안 의도와 동일하다.)
 */
public class JwtAuthenticationFilter implements GlobalFilter, Ordered {

    public static final String USER_ID_HEADER = "X-User-Id";
    private static final String BEARER_PREFIX = "Bearer ";

    private final JwtParser parser;
    private final List<String> whitelist;
    private final AntPathMatcher matcher = new AntPathMatcher();

    public JwtAuthenticationFilter(SecretKey key, List<String> whitelist) {
        this.parser = Jwts.parser().verifyWith(key).build();
        this.whitelist = whitelist;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        // 2. 클라이언트가 보낸 X-User-Id는 무조건 제거 (헤더 위조 차단)
        ServerHttpRequest stripped = exchange.getRequest().mutate()
                .headers(h -> h.remove(USER_ID_HEADER))
                .build();
        ServerWebExchange strippedExchange = exchange.mutate().request(stripped).build();

        // 1. 화이트리스트면 인증 없이 통과
        String path = stripped.getURI().getPath();
        if (whitelist.stream().anyMatch(p -> matcher.match(p, path))) {
            return chain.filter(strippedExchange);
        }

        // 3. Bearer 토큰 파싱
        String auth = stripped.getHeaders().getFirst(HttpHeaders.AUTHORIZATION);
        if (auth == null || !auth.startsWith(BEARER_PREFIX)) {
            return unauthorized(exchange);
        }
        String token = auth.substring(BEARER_PREFIX.length()).trim();

        // 4~5. 서명 검증 + 만료 확인
        Claims claims;
        try {
            claims = parser.parseSignedClaims(token).getPayload();
        } catch (JwtException | IllegalArgumentException e) {
            return unauthorized(exchange);
        }
        if (claims.getSubject() == null || claims.getSubject().isBlank()) {
            return unauthorized(exchange);
        }

        // 6. 검증된 sub를 X-User-Id로 주입
        ServerHttpRequest authenticated = stripped.mutate()
                .header(USER_ID_HEADER, claims.getSubject())
                .build();

        // 7. 다음 필터로
        return chain.filter(exchange.mutate().request(authenticated).build());
    }

    /** 401은 본문 없이 상태코드만 */
    private Mono<Void> unauthorized(ServerWebExchange exchange) {
        exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
        return exchange.getResponse().setComplete();
    }

    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE + 100;
    }
}
