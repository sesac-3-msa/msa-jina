package com.practice.member.controller;

import com.practice.member.util.JwtProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    /** 인메모리 사용자: username -> password */
    private static final Map<String, String> USERS = Map.of(
            "user1", "pass1",
            "user2", "pass2"
    );

    @Value("${POD_NAME:local}")
    private String podName;

    private final JwtProvider jwtProvider;

    public AuthController(JwtProvider jwtProvider) {
        this.jwtProvider = jwtProvider;
    }

    public record LoginRequest(String username, String password) {}

    @PostMapping("/login")
    public ResponseEntity<Map<String, Object>> login(@RequestBody LoginRequest req) {
        String expected = req.username() == null ? null : USERS.get(req.username());
        if (expected == null || !expected.equals(req.password())) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).build();
        }
        String token = jwtProvider.issue(req.username(), "USER");
        return ResponseEntity.ok(Map.of("token", token, "pod", podName));
    }
}
