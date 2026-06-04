package com.idemstudy.kafka;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.idemstudy.domain.OperationTx;
import com.idemstudy.metrics.IdemMetrics;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.stereotype.Component;

/**
 * Idempotent consumer for Strategies D and E.
 *
 * Dedup key is the event's {@code eventId} stored in {@code processed_messages}.
 * The dedup insert and the side effect commit in one DB transaction
 * ({@link OperationTx#consumeIdempotently}); the Kafka offset is committed only
 * AFTER that transaction commits. A crash before the offset commit causes
 * redelivery (counted), but the processed-message guard makes the redelivery a
 * no-op, so no duplicate side effect is produced.
 */
@Component
public class OperationConsumer {

    private final OperationTx tx;
    private final ObjectMapper json;
    private final IdemMetrics metrics;
    private static final String CONSUMER_GROUP = "operation-consumer-group";

    public OperationConsumer(OperationTx tx, ObjectMapper json, IdemMetrics metrics) {
        this.tx = tx;
        this.json = json;
        this.metrics = metrics;
    }

    @KafkaListener(topics = {"operations.requested.v1", "operations.outbox.v1"})
    public void onMessage(String payload, Acknowledgment ack) throws Exception {
        OperationEvent ev = json.readValue(payload, OperationEvent.class);
        try {
            boolean applied = tx.consumeIdempotently(ev, CONSUMER_GROUP);
            if (!applied) {
                metrics.duplicates.increment();   // duplicate delivery, suppressed
            }
            ack.acknowledge();                    // commit offset after DB tx commits
        } catch (DataIntegrityViolationException race) {
            // Concurrent redelivery lost the processed-message insert race: the
            // other delivery already applied the side effect. Safe to ack.
            metrics.duplicates.increment();
            ack.acknowledge();
        } catch (Exception e) {
            // Do NOT ack: Kafka redelivers; the processed-message guard keeps it safe.
            metrics.messageRedeliveries.increment();
            throw e;
        }
    }
}
