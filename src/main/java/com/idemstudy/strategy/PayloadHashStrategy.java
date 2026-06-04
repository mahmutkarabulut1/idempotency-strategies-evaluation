package com.idemstudy.strategy;

import com.idemstudy.domain.*;
import com.idemstudy.metrics.IdemMetrics;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * Strategy F — Payload-hash-aware idempotency.
 *
 * Same correctness primitive as Strategy A (unique key + {@link OperationTx}),
 * but its purpose is the semantic axis evaluated by E7: when the same idempotency
 * key is reused with a DIFFERENT payload hash, return 409 CONFLICT rather than
 * silently replaying the prior result. A key-only implementation would return the
 * wrong (stale) response; binding the key to the payload hash detects the conflict.
 */
@Component("PAYLOAD_HASH")
@ConditionalOnProperty(name = "idem.strategy", havingValue = "PAYLOAD_HASH")
public class PayloadHashStrategy implements IdempotencyStrategy {

    private final Repositories.IdempotencyRepo idemRepo;
    private final OperationTx tx;
    private final PayloadHasher hasher;
    private final IdemMetrics metrics;

    public PayloadHashStrategy(Repositories.IdempotencyRepo idemRepo,
                               OperationTx tx,
                               PayloadHasher hasher, IdemMetrics metrics) {
        this.idemRepo = idemRepo;
        this.tx = tx;
        this.hasher = hasher;
        this.metrics = metrics;
    }

    @Override
    public String name() { return "PAYLOAD_HASH"; }

    @Override
    public OperationResponse process(OperationRequest request) {
        metrics.requests.increment();
        String hash = hasher.hash(request);

        var existing = idemRepo.findById(request.idempotencyKey());
        if (existing.isPresent()) {
            return decide(existing.get(), request, hash);
        }
        try {
            UUID operationId = metrics.processing.record(
                    () -> tx.insertAndApply(request, hash, name(), 201));
            return new OperationResponse(operationId, request.idempotencyKey(),
                    OperationResponse.Outcome.APPLIED, "applied");
        } catch (DataIntegrityViolationException dup) {
            return idemRepo.findById(request.idempotencyKey())
                    .map(r -> decide(r, request, hash))
                    .orElseGet(() -> new OperationResponse(null, request.idempotencyKey(),
                            OperationResponse.Outcome.REJECTED, "race"));
        }
    }

    /** The semantic decision E7 measures. */
    private OperationResponse decide(entities.IdempotencyRecord rec,
                                     OperationRequest request, String hash) {
        if (!rec.payloadHash.equals(hash)) {
            metrics.conflicts.increment();
            return new OperationResponse(rec.operationId, request.idempotencyKey(),
                    OperationResponse.Outcome.CONFLICT,
                    "idempotency key reused with different payload");
        }
        metrics.duplicates.increment();
        return new OperationResponse(rec.operationId, request.idempotencyKey(),
                OperationResponse.Outcome.DUPLICATE_REPLAYED, "replayed");
    }
}
