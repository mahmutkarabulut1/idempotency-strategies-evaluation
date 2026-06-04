package com.idemstudy.strategy;

import com.idemstudy.domain.*;
import com.idemstudy.metrics.IdemMetrics;
import org.apache.curator.framework.CuratorFramework;
import org.apache.curator.framework.recipes.locks.InterProcessMutex;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.util.UUID;
import java.util.concurrent.TimeUnit;

/**
 * Strategy C — Consensus-based coordination via ZooKeeper (Apache Curator
 * {@link InterProcessMutex}). Unlike a TTL lease, a ZooKeeper lock is tied to an
 * ephemeral, session-bound znode: ownership is decided by the ZAB-replicated
 * quorum, not by wall-clock time, so it is robust to clock drift but pays a
 * coordination round-trip on every acquire. Existence of an applied marker is
 * tracked by a durable znode under {@code /idem/done}.
 */
@Component("ZK")
@ConditionalOnProperty(name = "idem.strategy", havingValue = "ZK")
public class ZooKeeperLockStrategy implements IdempotencyStrategy {

    private final CuratorFramework curator;
    private final SideEffectRecorder recorder;
    private final PayloadHasher hasher;
    private final IdemMetrics metrics;
    private final long waitMs;

    public ZooKeeperLockStrategy(CuratorFramework curator, SideEffectRecorder recorder,
                                 PayloadHasher hasher, IdemMetrics metrics,
                                 @Value("${idem.lock.wait-ms}") long waitMs) {
        this.curator = curator;
        this.recorder = recorder;
        this.hasher = hasher;
        this.metrics = metrics;
        this.waitMs = waitMs;
    }

    @Override
    public String name() { return "ZK"; }

    @Override
    public OperationResponse process(OperationRequest request) {
        metrics.requests.increment();
        String hash = hasher.hash(request);
        String donePath = "/idem/done/" + safe(request.idempotencyKey());

        try {
            byte[] prior = readIfExists(donePath);
            if (prior != null) return replay(prior, request, hash);

            InterProcessMutex mutex = new InterProcessMutex(curator,
                    "/idem/lock/" + safe(request.idempotencyKey()));
            long waitStart = System.nanoTime();
            boolean held = mutex.acquire(waitMs, TimeUnit.MILLISECONDS);
            long elapsed = System.nanoTime() - waitStart;
            metrics.lockWait.record(elapsed, TimeUnit.NANOSECONDS);
            metrics.lockAcquisition.record(elapsed, TimeUnit.NANOSECONDS);

            if (!held) {
                metrics.lockTimeouts.increment();
                return new OperationResponse(null, request.idempotencyKey(),
                        OperationResponse.Outcome.REJECTED, "lock-timeout");
            }
            try {
                byte[] again = readIfExists(donePath);
                if (again != null) return replay(again, request, hash);

                return metrics.processing.record(() -> {
                    UUID operationId = UUID.randomUUID();
                    recorder.apply(operationId, request.idempotencyKey(), name());
                    createDoneMarker(donePath, operationId + "|" + hash);
                    return new OperationResponse(operationId, request.idempotencyKey(),
                            OperationResponse.Outcome.APPLIED, "applied");
                });
            } finally {
                mutex.release();
            }
        } catch (Exception e) {
            metrics.failures.increment();
            return new OperationResponse(null, request.idempotencyKey(),
                    OperationResponse.Outcome.REJECTED, "zk-error:" + e.getClass().getSimpleName());
        }
    }

    private byte[] readIfExists(String path) throws Exception {
        if (curator.checkExists().forPath(path) == null) return null;
        return curator.getData().forPath(path);
    }

    private void createDoneMarker(String path, String value) {
        try {
            curator.create().creatingParentsIfNeeded().forPath(path, value.getBytes());
        } catch (Exception ignored) {
            // already created concurrently — fine, marker is idempotent
        }
    }

    private OperationResponse replay(byte[] marker, OperationRequest request, String hash) {
        String[] parts = new String(marker).split("\\|", 2);
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

    private static String safe(String key) {
        return key.replaceAll("[^a-zA-Z0-9_-]", "_");
    }
}
