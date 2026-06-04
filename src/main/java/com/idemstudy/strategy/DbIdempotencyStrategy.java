package com.idemstudy.strategy;

import com.idemstudy.domain.*;
import com.idemstudy.metrics.IdemMetrics;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.UUID;

/**
 * Strategy A — Database-level idempotency via a PostgreSQL unique constraint.
 *
 * Correctness primitive: the primary key on {@code idempotency_records}. The
 * first writer inserts the row and applies the side effect in the same
 * transaction ({@link OperationTx}); concurrent duplicates hit a unique
 * violation, roll back, and replay the stored result. No external lock manager.
 */
@Component("DB")
@ConditionalOnProperty(name = "idem.strategy", havingValue = "DB", matchIfMissing = true)
public class DbIdempotencyStrategy implements IdempotencyStrategy {

    private final Repositories.IdempotencyRepo idemRepo;
    private final OperationTx tx;
    private final PayloadHasher hasher;
    private final IdemMetrics metrics;

    public DbIdempotencyStrategy(Repositories.IdempotencyRepo idemRepo,
                                 OperationTx tx,
                                 PayloadHasher hasher,
                                 IdemMetrics metrics) {
        this.idemRepo = idemRepo;
        this.tx = tx;
        this.hasher = hasher;
        this.metrics = metrics;
    }

    @Override
    public String name() { return "DB"; }

    @Override
    public OperationResponse process(OperationRequest request) {
        metrics.requests.increment();
        String hash = hasher.hash(request);

        Optional<entities.IdempotencyRecord> existing = idemRepo.findById(request.idempotencyKey());
        if (existing.isPresent()) {
            return replayOrConflict(existing.get(), request, hash);
        }
        try {
            UUID operationId = metrics.processing.record(
                    () -> tx.insertAndApply(request, hash, name(), 201));
            return new OperationResponse(operationId, request.idempotencyKey(),
                    OperationResponse.Outcome.APPLIED, "applied");
        } catch (DataIntegrityViolationException dup) {
            metrics.duplicates.increment();
            return idemRepo.findById(request.idempotencyKey())
                    .map(r -> replayOrConflict(r, request, hash))
                    .orElseGet(() -> new OperationResponse(null, request.idempotencyKey(),
                            OperationResponse.Outcome.REJECTED, "race-without-record"));
        }
    }

    private OperationResponse replayOrConflict(entities.IdempotencyRecord rec,
                                               OperationRequest request, String hash) {
        if (!rec.payloadHash.equals(hash)) {
            metrics.conflicts.increment();
            return new OperationResponse(rec.operationId, request.idempotencyKey(),
                    OperationResponse.Outcome.CONFLICT, "same key, different payload");
        }
        metrics.duplicates.increment();
        return new OperationResponse(rec.operationId, request.idempotencyKey(),
                OperationResponse.Outcome.DUPLICATE_REPLAYED, "replayed");
    }
}
