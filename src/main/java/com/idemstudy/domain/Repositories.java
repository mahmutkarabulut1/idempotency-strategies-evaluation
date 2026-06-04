package com.idemstudy.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public final class Repositories {
    private Repositories() {}

    public interface IdempotencyRepo extends JpaRepository<entities.IdempotencyRecord, String> {
    }

    public interface SideEffectRepo extends JpaRepository<entities.SideEffect, Long> {
        long countByOperationId(UUID operationId);
    }

    public interface ProcessedMessageRepo extends JpaRepository<entities.ProcessedMessage, UUID> {
        boolean existsByOperationIdAndConsumerGroup(UUID operationId, String consumerGroup);
    }

    public interface OutboxRepo extends JpaRepository<entities.OutboxEvent, UUID> {
        @Query("select e from OutboxEvent e where e.status = 'PENDING' order by e.eventId")
        List<entities.OutboxEvent> findPending();

        @Modifying
        @Query("update OutboxEvent e set e.status = 'PUBLISHED' where e.eventId = :id")
        void markPublished(@Param("id") UUID id);
    }
}
