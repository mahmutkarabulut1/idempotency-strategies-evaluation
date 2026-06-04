package com.idemstudy.domain;

import java.math.BigDecimal;
import java.util.Map;

/**
 * Domain-independent request for a single logical operation.
 * The same model carries PAYMENT, ORDER_CREATION, INVENTORY_RESERVATION, etc.
 */
public record OperationRequest(
        String idempotencyKey,
        String operationType,
        String entityId,
        String userId,
        BigDecimal amount,
        Integer quantity,
        Map<String, Object> metadata,
        Integer retryAttempt,
        String requestSource
) {
}
