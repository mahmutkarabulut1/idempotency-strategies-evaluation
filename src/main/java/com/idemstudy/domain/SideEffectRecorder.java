package com.idemstudy.domain;

import com.idemstudy.metrics.IdemMetrics;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * The single point at which a business side effect is "applied". Every strategy
 * routes through here so the experiment can count side effects uniformly and
 * detect duplicate side-effect violations.
 */
@Service
public class SideEffectRecorder {

    private final Repositories.SideEffectRepo repo;
    private final IdemMetrics metrics;
    private final String instanceId;
    private final String experimentRun;

    public SideEffectRecorder(Repositories.SideEffectRepo repo,
                              IdemMetrics metrics,
                              @Value("${idem.instance-id}") String instanceId,
                              @Value("${idem.experiment-run}") String experimentRun) {
        this.repo = repo;
        this.metrics = metrics;
        this.instanceId = instanceId;
        this.experimentRun = experimentRun;
    }

    /**
     * Appends a side-effect row for the operation and updates the violation
     * counter if more than one effect now exists for the same logical operation.
     */
    @Transactional
    public void apply(UUID operationId, String idempotencyKey, String strategy) {
        entities.SideEffect e = new entities.SideEffect();
        e.operationId = operationId;
        e.idempotencyKey = idempotencyKey;
        e.strategy = strategy;
        e.experimentRun = experimentRun;
        e.instanceId = instanceId;
        repo.save(e);

        // Real-time visibility; the ground-truth rate is recomputed from the DB
        // view v_violation_rate during analysis.
        long count = repo.countByOperationId(operationId);
        if (count > 1) {
            metrics.violations.increment();
        }
    }
}
