package com.idemstudy.domain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.idemstudy.kafka.OperationEvent;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Transactional unit-of-work shared by the database-backed strategies (A, E, F).
 *
 * Kept as a separate bean (not a self-invoked method on a strategy) so Spring's
 * transactional proxy actually applies: the idempotency-record insert and the
 * side effect commit atomically. A unique-key violation propagates to the caller
 * as {@code DataIntegrityViolationException}, which the strategy turns into a
 * replay/conflict.
 */
@Service
public class OperationTx {

    private final Repositories.IdempotencyRepo idemRepo;
    private final Repositories.OutboxRepo outboxRepo;
    private final Repositories.ProcessedMessageRepo processedRepo;
    private final SideEffectRecorder recorder;
    private final ObjectMapper json;

    public OperationTx(Repositories.IdempotencyRepo idemRepo,
                       Repositories.OutboxRepo outboxRepo,
                       Repositories.ProcessedMessageRepo processedRepo,
                       SideEffectRecorder recorder,
                       ObjectMapper json) {
        this.idemRepo = idemRepo;
        this.outboxRepo = outboxRepo;
        this.processedRepo = processedRepo;
        this.recorder = recorder;
        this.json = json;
    }

    /**
     * D/E consumer path: dedup on event id and apply the side effect atomically.
     * Returns {@code true} if the side effect was applied, {@code false} if this
     * event was already processed (duplicate delivery → no duplicate side effect).
     */
    @Transactional
    public boolean consumeIdempotently(OperationEvent ev, String consumerGroup) {
        // Dedup on operationId (derived from the idempotency key), not eventId, so
        // that BOTH message redelivery (same event) AND distinct requests sharing
        // a key (different events, same operation) are suppressed to one side effect.
        if (processedRepo.existsByOperationIdAndConsumerGroup(ev.operationId(), consumerGroup)) {
            return false;
        }
        entities.ProcessedMessage pm = new entities.ProcessedMessage();
        pm.eventId = ev.eventId();
        pm.operationId = ev.operationId();
        pm.consumerGroup = consumerGroup;
        processedRepo.saveAndFlush(pm);   // unique(operation_id,consumer_group) violation on race → rollback
        recorder.apply(ev.operationId(), ev.idempotencyKey(), "KAFKA");
        return true;
    }

    /** A/F: insert idempotency record + apply side effect atomically. */
    @Transactional
    public UUID insertAndApply(OperationRequest request, String hash, String strategy, int responseCode) {
        UUID operationId = UUID.randomUUID();
        idemRepo.saveAndFlush(record(request, hash, operationId, responseCode));
        recorder.apply(operationId, request.idempotencyKey(), strategy);
        return operationId;
    }

    /** E: insert idempotency record + outbox event atomically (no side effect yet). */
    @Transactional
    public UUID insertWithOutbox(OperationRequest request, String hash) {
        UUID operationId = UUID.randomUUID();
        idemRepo.saveAndFlush(record(request, hash, operationId, 202));
        try {
            UUID eventId = UUID.randomUUID();
            entities.OutboxEvent ob = new entities.OutboxEvent();
            ob.eventId = eventId;
            ob.aggregateId = operationId;
            ob.topic = "operations.outbox.v1";
            ob.payload = json.writeValueAsString(new OperationEvent(
                    eventId, operationId, request.idempotencyKey(), request.operationType()));
            outboxRepo.save(ob);
        } catch (Exception e) {
            throw new IllegalStateException("outbox serialization failed", e);
        }
        return operationId;
    }

    private entities.IdempotencyRecord record(OperationRequest request, String hash,
                                              UUID operationId, int responseCode) {
        entities.IdempotencyRecord rec = new entities.IdempotencyRecord();
        rec.idempotencyKey = request.idempotencyKey();
        rec.payloadHash = hash;
        rec.operationId = operationId;
        rec.responseCode = responseCode;
        rec.completedAt = OffsetDateTime.now();
        return rec;
    }
}
