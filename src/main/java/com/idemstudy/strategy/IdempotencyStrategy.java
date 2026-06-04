package com.idemstudy.strategy;

import com.idemstudy.domain.OperationRequest;
import com.idemstudy.domain.OperationResponse;

/**
 * One idempotency / locking strategy under evaluation. Exactly one bean is
 * active per run, chosen by the {@code idem.strategy} property.
 */
public interface IdempotencyStrategy {

    /** Identifier emitted in metrics and stored on every side-effect row. */
    String name();

    /** Process one logical operation, guaranteeing at most one side effect. */
    OperationResponse process(OperationRequest request);
}
