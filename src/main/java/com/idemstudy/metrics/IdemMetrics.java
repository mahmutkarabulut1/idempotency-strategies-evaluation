package com.idemstudy.metrics;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

/**
 * Central registry of the custom correctness + performance metrics the paper
 * relies on. Correctness counters (violations, stale locks, conflicts) are
 * collected alongside latency timers so a single Prometheus scrape captures both.
 */
@Component
public class IdemMetrics {

    public final Counter requests;
    public final Counter duplicates;
    public final Counter conflicts;
    public final Counter violations;          // duplicate_side_effect_violations_total
    public final Counter lockTimeouts;
    public final Counter staleLocks;
    public final Counter prematureExpirations;
    public final Counter messageRedeliveries;
    public final Counter outboxPublished;
    public final Counter failures;
    public final Timer   processing;          // operation_processing_duration_seconds
    public final Timer   lockAcquisition;     // lock_acquisition_duration_seconds
    public final Timer   lockWait;            // lock_wait_duration_seconds

    public IdemMetrics(MeterRegistry reg) {
        this.requests            = Counter.builder("idempotency_requests_total").register(reg);
        this.duplicates          = Counter.builder("idempotency_duplicates_total").register(reg);
        this.conflicts           = Counter.builder("idempotency_conflicts_total").register(reg);
        this.violations          = Counter.builder("duplicate_side_effect_violations_total").register(reg);
        this.lockTimeouts        = Counter.builder("lock_timeout_total").register(reg);
        this.staleLocks          = Counter.builder("stale_lock_total").register(reg);
        this.prematureExpirations= Counter.builder("premature_lock_expiration_total").register(reg);
        this.messageRedeliveries = Counter.builder("message_redeliveries_total").register(reg);
        this.outboxPublished     = Counter.builder("outbox_events_published_total").register(reg);
        this.failures            = Counter.builder("operation_failures_total").register(reg);
        this.processing          = Timer.builder("operation_processing_duration_seconds")
                .publishPercentiles(0.5, 0.95, 0.99).register(reg);
        this.lockAcquisition     = Timer.builder("lock_acquisition_duration_seconds")
                .publishPercentiles(0.5, 0.95, 0.99).register(reg);
        this.lockWait            = Timer.builder("lock_wait_duration_seconds")
                .publishPercentiles(0.5, 0.95, 0.99).register(reg);
    }
}
