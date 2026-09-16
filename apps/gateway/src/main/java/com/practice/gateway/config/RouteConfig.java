package com.practice.gateway.config;

import com.practice.gateway.filter.JwtAuthenticationFilter;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.List;

/**
 * 라우팅 규칙 자체는 application.yml에 있다 (Ingress YAML과 1:1로 비교하기 위해).
 * 여기서는 JWT 검증 필터에 필요한 키와 화이트리스트를 조립한다.
 */
@Configuration
public class RouteConfig {

    /** 인증 없이 통과시키는 경로 (Ant 패턴) */
    private static final List<String> WHITELIST = List.of(
            "/api/auth/**",
            "/actuator/**"
    );

    @Bean
    public SecretKey jwtKey(@Value("${JWT_SECRET}") String secret) {
        return Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
    }

    @Bean
    public JwtAuthenticationFilter jwtAuthenticationFilter(SecretKey jwtKey) {
        return new JwtAuthenticationFilter(jwtKey, WHITELIST);
    }
}
