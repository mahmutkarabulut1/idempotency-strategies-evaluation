package com.idemstudy.outbox;

import com.idemstudy.domain.Repositories;
import com.idemstudy.domain.entities;
import com.idemstudy.metrics.IdemMetrics;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * Polling relay for Strategy E. Periodically publishes PENDING outbox rows to
 * Kafka and marks them PUBLISHED. Only active when the outbox strategy is
 * selected. May publish a row more than once if it crashes between send and
 * mark-published — the idempotent consumer absorbs that duplicate.
 */
@Component
public class OutboxRelay {

    private final Repositories.OutboxRepo outboxRepo;
    private final KafkaTemplate<String, String> kafka;
    private final IdemMetrics metrics;
    private final boolean enabled;

    public OutboxRelay(Repositories.OutboxRepo outboxRepo,
                       KafkaTemplate<String, String> kafka,
                       IdemMetrics metrics,
                       @Value("${idem.strategy}") String strategy) {
        this.outboxRepo = outboxRepo;
        this.kafka = kafka;
        this.metrics = metrics;
        this.enabled = "OUTBOX".equalsIgnoreCase(strategy);
    }

    @Scheduled(fixedDelay = 200)
    @Transactional
    public void relay() {
        if (!enabled) return;
        List<entities.OutboxEvent> pending = outboxRepo.findPending();
        for (entities.OutboxEvent e : pending) {
            kafka.send(e.topic, e.aggregateId.toString(), e.payload);
            outboxRepo.markPublished(e.eventId);
            metrics.outboxPublished.increment();
        }
    }
}
