package com.practice.member.util;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.Date;

/**
 * HS256 JWT 발급. 시크릿은 JWT_SECRET 환경변수(32바이트 이상)에서 읽는다.
 * 게이트웨이와 동일한 시크릿을 써야 서명 검증이 통과한다.
 */
@Component
public class JwtProvider {

    private static final long EXPIRE_MS = 3600_000L; // 1시간

    private final SecretKey key;

    public JwtProvider(@Value("${JWT_SECRET}") String secret) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
    }

    public String issue(String userId, String role) {
        return Jwts.builder()
                .subject(userId)
                .claim("role", role)
                .issuedAt(new Date())
                .expiration(new Date(System.currentTimeMillis() + EXPIRE_MS))
                .signWith(key, Jwts.SIG.HS256)   // 계약: HS256 고정 (jjwt는 키 길이에 따라 HS384/512를 자동 선택하므로 명시)
                .compact();
    }
}
