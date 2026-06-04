package com.idemstudy.strategy;

import com.idemstudy.domain.*;
import com.idemstudy.metrics.IdemMetrics;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * Strategy E — Transactional outbox + idempotent consumer.
 *
 * The idempotency record (de-dup at the producer) AND the outbox event are
 * written in ONE local transaction ({@link OperationTx#insertWithOutbox}). A
 * relay later publishes the outbox row to Kafka; the idempotent
 * {@link com.idemstudy.kafka.OperationConsumer} applies the side effect. This
 * closes the commit-vs-publish gap (no lost events) while tolerating duplicate
 * publication.
 */
@Component("OUTBOX")
@ConditionalOnProperty(name = "idem.strategy", havingValue = "OUTBOX")
public class OutboxStrategy implements IdempotencyStrategy {

    private final Repositories.IdempotencyRepo idemRepo;
    private final OperationTx tx;
    private final PayloadHasher hasher;
    private final IdemMetrics metrics;

    public OutboxStrategy(Repositories.IdempotencyRepo idemRepo,
                          OperationTx tx,
                          PayloadHasher hasher, IdemMetrics metrics) {
        this.idemRepo = idemRepo;
        this.tx = tx;
        this.hasher = hasher;
        this.metrics = metrics;
    }

    @Override
    public String name() { return "OUTBOX"; }

    @Override
    public OperationResponse process(OperationRequest request) {
        metrics.requests.increment();
        String hash = hasher.hash(request);
        try {
            UUID operationId = metrics.processing.record(() -> tx.insertWithOutbox(request, hash));
            return new OperationResponse(operationId, request.idempotencyKey(),
                    OperationResponse.Outcome.APPLIED, "accepted-outbox");
        } catch (DataIntegrityViolationException dup) {
            metrics.duplicates.increment();
            return idemRepo.findById(request.idempotencyKey())
                    .map(r -> new OperationResponse(r.operationId, request.idempotencyKey(),
                            r.payloadHash.equals(hash)
                                    ? OperationResponse.Outcome.DUPLICATE_REPLAYED
                                    : OperationResponse.Outcome.CONFLICT, "replayed-or-conflict"))
                    .orElseGet(() -> new OperationResponse(null, request.idempotencyKey(),
                            OperationResponse.Outcome.REJECTED, "race"));
        }
    }
}
