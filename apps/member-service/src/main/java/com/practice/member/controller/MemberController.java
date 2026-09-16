package com.practice.member.controller;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/members")
public class MemberController {

    private static final List<Map<String, String>> MEMBERS = List.of(
            Map.of("id", "user1", "name", "Alice"),
            Map.of("id", "user2", "name", "Bob")
    );

    /** 응답마다 파드명을 실어 로드밸런싱 분산을 눈으로 확인한다. */
    @Value("${POD_NAME:local}")
    private String podName;

    @GetMapping
    public Map<String, Object> list() {
        return Map.of("pod", podName, "data", MEMBERS);
    }

    /**
     * 게이트웨이가 JWT의 sub를 X-User-Id로 주입한다.
     * 클라이언트가 직접 보낸 X-User-Id는 게이트웨이에서 제거되므로 여기 도달하지 않는다.
     */
    @GetMapping("/me")
    public Map<String, Object> me(@RequestHeader(value = "X-User-Id", required = false) String userId) {
        return Map.of("pod", podName, "userId", userId == null ? "anonymous" : userId);
    }
}
