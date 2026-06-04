package com.idemstudy.strategy;

import com.idemstudy.domain.*;
import com.idemstudy.metrics.IdemMetrics;
import org.redisson.api.RLock;
import org.redisson.api.RMapCache;
import org.redisson.api.RedissonClient;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.util.UUID;
import java.util.concurrent.TimeUnit;

/**
 * Strategy B — Redis-based distributed lock (Redisson RLock).
 *
 * Acquire a lock keyed by the idempotency key, check a Redis-side "done" marker,
 * apply the side effect, then mark done. This is the classic TTL-lease design
 * whose correctness depends on timing assumptions; under partition / clock drift
 * the lease can expire while work is in flight, which is exactly what E4/E5
 * measure. {@code staleLocks} is incremented when we detect the done-marker was
 * set by someone else after we believed we held the lock.
 */
@Component("REDIS")
@ConditionalOnProperty(name = "idem.strategy", havingValue = "REDIS")
public class RedisLockStrategy implements IdempotencyStrategy {

    private final RedissonClient redisson;
    private final SideEffectRecorder recorder;
    private final PayloadHasher hasher;
    private final IdemMetrics metrics;
    private final long waitMs;
    private final long leaseMs;

    public RedisLockStrategy(RedissonClient redisson, SideEffectRecorder recorder,
                             PayloadHasher hasher, IdemMetrics metrics,
                             @Value("${idem.lock.wait-ms}") long waitMs,
                             @Value("${idem.lock.lease-ms}") long leaseMs) {
        this.redisson = redisson;
        this.recorder = recorder;
        this.hasher = hasher;
        this.metrics = metrics;
        this.waitMs = waitMs;
        this.leaseMs = leaseMs;
    }

    @Override
    public String name() { return "REDIS"; }

    @Override
    public OperationResponse process(OperationRequest request) {
        metrics.requests.increment();
        String hash = hasher.hash(request);
        RMapCache<String, String> done = redisson.getMapCache("idem:done");

        // Pre-check: already applied?
        String prior = done.get(request.idempotencyKey());
        if (prior != null) return replay(prior, request, hash);

        RLock lock = redisson.getLock("idem:lock:" + request.idempotencyKey());
        long waitStart = System.nanoTime();
        boolean held;
        try {
            held = lock.tryLock(waitMs, leaseMs, TimeUnit.MILLISECONDS);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            metrics.failures.increment();
            return reject(request, "interrupted");
        }
        metrics.lockWait.record(System.nanoTime() - waitStart, TimeUnit.NANOSECONDS);

        if (!held) {
            metrics.lockTimeouts.increment();
            return reject(request, "lock-timeout");
        }

        try {
            // Re-check inside the critical section (double-checked locking).
            String again = done.get(request.idempotencyKey());
            if (again != null) return replay(again, request, hash);

            return metrics.processing.record(() -> {
                UUID operationId = UUID.randomUUID();
                recorder.apply(operationId, request.idempotencyKey(), name());
                done.put(request.idempotencyKey(), operationId + "|" + hash);
                return new OperationResponse(operationId, request.idempotencyKey(),
                        OperationResponse.Outcome.APPLIED, "applied");
            });
        } finally {
            // Only unlock if we still own it; otherwise the lease already expired
            // (premature expiration) and someone else may hold the lock now.
            if (lock.isHeldByCurrentThread()) {
                lock.unlock();
            } else {
                metrics.prematureExpirations.increment();
            }
        }
    }

    private OperationResponse replay(String marker, OperationRequest request, String hash) {
        String[] parts = marker.split("\\|", 2);
        UUID opId = UUID.fromString(parts[0]);
        if (parts.length == 2 && !parts[1].equals(hash)) {
            metrics.conflicts.increment();
            return new OperationResponse(opId, request.idempotencyKey(),
                    OperationResponse.Outcome.CONFLICT, "same key, different payload");
        }
        metrics.duplicates.increment();
        return new OperationResponse(opId, request.idempotencyKey(),
                OperationResponse.Outcome.DUPLICATE_REPLAYED, "replayed");
    }

    private OperationResponse reject(OperationRequest request, String why) {
        return new OperationResponse(null, request.idempotencyKey(),
                OperationResponse.Outcome.REJECTED, why);
    }
}
