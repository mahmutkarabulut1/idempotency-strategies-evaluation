package com.idemstudy.api;

import com.idemstudy.domain.OperationRequest;
import com.idemstudy.domain.OperationResponse;
import com.idemstudy.strategy.IdempotencyStrategy;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * Single entry point for logical operations. The active {@link IdempotencyStrategy}
 * (exactly one bean per run, selected by {@code idem.strategy}) handles the
 * request. Returns 201 (applied), 200 (duplicate replayed), 409 (conflict), or
 * 429 (rejected) so the load generator can classify outcomes.
 */
@RestController
@RequestMapping("/operations")
public class OperationController {

    private final IdempotencyStrategy strategy;

    public OperationController(List<IdempotencyStrategy> strategies) {
        if (strategies.size() != 1) {
            throw new IllegalStateException(
                    "Exactly one strategy must be active, found: " + strategies.stream()
                            .map(IdempotencyStrategy::name).toList());
        }
        this.strategy = strategies.get(0);
    }

    @PostMapping
    public ResponseEntity<OperationResponse> submit(@RequestBody OperationRequest request) {
        OperationResponse resp = strategy.process(request);
        return ResponseEntity.status(resp.httpStatus()).body(resp);
    }

    @GetMapping("/strategy")
    public String activeStrategy() {
        return strategy.name();
    }
}
