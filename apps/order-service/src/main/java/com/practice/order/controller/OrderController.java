package com.practice.order.controller;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    /** 파드별 인메모리 저장소. 레플리카마다 별도 상태를 가진다는 점도 관찰 포인트. */
    private final Map<String, Map<String, Object>> store = new ConcurrentHashMap<>();

    /** 응답마다 파드명을 실어 로드밸런싱 분산을 눈으로 확인한다. */
    @Value("${POD_NAME:local}")
    private String podName;

    public OrderController() {
        store.put("order-1", Map.of("orderId", "order-1", "userId", "user1", "item", "keyboard"));
        store.put("order-2", Map.of("orderId", "order-2", "userId", "user2", "item", "mouse"));
    }

    @GetMapping
    public Map<String, Object> list() {
        return Map.of("pod", podName, "data", store.values());
    }

    @PostMapping
    public Map<String, Object> create(
            @RequestHeader(value = "X-User-Id", required = false) String userId,
            @RequestBody(required = false) Map<String, Object> body) {
        String orderId = "order-" + UUID.randomUUID().toString().substring(0, 8);
        Object item = body == null ? "unknown" : body.getOrDefault("item", "unknown");
        store.put(orderId, Map.of(
                "orderId", orderId,
                "userId", userId == null ? "anonymous" : userId,
                "item", item));
        return Map.of("pod", podName, "orderId", orderId);
    }
}
