package com.idemstudy.kafka;

import java.util.UUID;

/** Event carried on operations.requested.v1 / outbox topics. */
public record OperationEvent(
        UUID eventId,
        UUID operationId,
        String idempotencyKey,
        String operationType
) {
}
