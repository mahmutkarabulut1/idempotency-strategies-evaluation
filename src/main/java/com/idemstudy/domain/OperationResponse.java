package com.idemstudy.domain;

import java.util.UUID;

/** Outcome of processing a logical operation. */
public record OperationResponse(
        UUID operationId,
        String idempotencyKey,
        Outcome outcome,
        String message
) {
    public enum Outcome {
        /** First successful application of the side effect. */
        APPLIED,
        /** Same key + same payload: a true duplicate; previous result replayed. */
        DUPLICATE_REPLAYED,
        /** Same key + different payload hash: a semantic conflict (Strategy F). */
        CONFLICT,
        /** Could not acquire lock / coordination within budget. */
        REJECTED
    }

    public int httpStatus() {
        return switch (outcome) {
            case APPLIED -> 201;
            case DUPLICATE_REPLAYED -> 200;
            case CONFLICT -> 409;
            case REJECTED -> 429;
        };
    }
}
