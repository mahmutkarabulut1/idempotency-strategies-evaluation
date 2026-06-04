package com.idemstudy.domain;

import jakarta.persistence.*;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * JPA entities for the testbed. Co-located for brevity; one class per table.
 */
public final class entities {
    private entities() {}

    /** Strategy A: the idempotency record guarded by a unique key constraint. */
    @Entity
    @Table(name = "idempotency_records")
    public static class IdempotencyRecord {
        @Id
        @Column(name = "idempotency_key")
        public String idempotencyKey;
        @Column(name = "payload_hash", nullable = false)
        public String payloadHash;
        @Column(name = "operation_id", nullable = false)
        public UUID operationId;
        @Column(name = "response_code", nullable = false)
        public int responseCode;
        @Column(name = "completed_at")
        public OffsetDateTime completedAt;
    }

    /** Every successful business effect appends one row here. */
    @Entity
    @Table(name = "operation_side_effects")
    public static class SideEffect {
        @Id
        @GeneratedValue(strategy = GenerationType.IDENTITY)
        @Column(name = "side_effect_id")
        public Long id;
        @Column(name = "operation_id", nullable = false)
        public UUID operationId;
        @Column(name = "idempotency_key", nullable = false)
        public String idempotencyKey;
        @Column(nullable = false)
        public String strategy;
        @Column(name = "experiment_run", nullable = false)
        public String experimentRun;
        @Column(name = "instance_id")
        public String instanceId;
    }

    /** Strategy D/E: processed-message dedup store for Kafka consumers. */
    @Entity
    @Table(name = "processed_messages")
    public static class ProcessedMessage {
        @Id
        @Column(name = "event_id")
        public UUID eventId;
        @Column(name = "operation_id", nullable = false)
        public UUID operationId;
        @Column(name = "consumer_group", nullable = false)
        public String consumerGroup;
    }

    /** Strategy E: transactional outbox row. */
    @Entity(name = "OutboxEvent")
    @Table(name = "outbox_events")
    public static class OutboxEvent {
        @Id
        @Column(name = "event_id")
        public UUID eventId;
        @Column(name = "aggregate_id", nullable = false)
        public UUID aggregateId;
        @Column(nullable = false)
        public String topic;
        @Column(nullable = false)
        public String payload;   // serialized event JSON, stored as TEXT
        @Column(nullable = false)
        public String status = "PENDING";
    }
}
