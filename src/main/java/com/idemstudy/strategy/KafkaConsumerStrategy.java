package com.idemstudy.strategy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.idemstudy.domain.OperationRequest;
import com.idemstudy.domain.OperationResponse;
import com.idemstudy.kafka.OperationEvent;
import com.idemstudy.metrics.IdemMetrics;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * Strategy D — Kafka consumer-level idempotency.
 *
 * The synchronous API merely publishes an {@link OperationEvent} (with a unique
 * eventId) to {@code operations.requested.v1} and returns immediately. The side
 * effect is applied asynchronously by {@link com.idemstudy.kafka.OperationConsumer},
 * which deduplicates on the processed-message table. This separates duplicate
 * *delivery* (which Kafka can do) from duplicate *side effects* (which the
 * consumer prevents).
 */
@Component("KAFKA")
@ConditionalOnProperty(name = "idem.strategy", havingValue = "KAFKA")
public class KafkaConsumerStrategy implements IdempotencyStrategy {

    private final KafkaTemplate<String, String> kafka;
    private final ObjectMapper json;
    private final IdemMetrics metrics;

    public KafkaConsumerStrategy(KafkaTemplate<String, String> kafka,
                                 ObjectMapper json, IdemMetrics metrics) {
        this.kafka = kafka;
        this.json = json;
        this.metrics = metrics;
    }

    @Override
    public String name() { return "KAFKA"; }

    @Override
    public OperationResponse process(OperationRequest request) {
        metrics.requests.increment();
        // operationId is DERIVED from the idempotency key so that N duplicate
        // requests for the same key map to ONE logical operation. eventId stays
        // random (each publish is a distinct delivery). The consumer dedups on
        // operationId, so same-key duplicates produce at most one side effect.
        UUID eventId = UUID.randomUUID();
        UUID operationId = UUID.nameUUIDFromBytes(
                request.idempotencyKey().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        OperationEvent ev = new OperationEvent(eventId, operationId,
                request.idempotencyKey(), request.operationType());
        try {
            // Key by idempotency key so all duplicates land on the same partition,
            // preserving per-key ordering.
            kafka.send("operations.requested.v1", request.idempotencyKey(),
                    json.writeValueAsString(ev));
        } catch (Exception e) {
            metrics.failures.increment();
            return new OperationResponse(operationId, request.idempotencyKey(),
                    OperationResponse.Outcome.REJECTED, "publish-failed");
        }
        // Accepted for asynchronous, idempotent processing.
        return new OperationResponse(operationId, request.idempotencyKey(),
                OperationResponse.Outcome.APPLIED, "accepted");
    }
}
