package com.idemstudy;

import com.idemstudy.domain.OperationRequest;
import com.idemstudy.domain.PayloadHasher;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for the payload hashing that underpins Strategy F's conflict
 * detection (H6, experiment E7).
 */
class PayloadHasherTest {

    private final PayloadHasher hasher = new PayloadHasher();

    private OperationRequest req(BigDecimal amount, int qty) {
        return new OperationRequest("k1", "PAYMENT", "e1", "u1", amount, qty,
                Map.of(), 0, "test");
    }

    @Test
    void sameSemanticPayloadProducesSameHash() {
        assertEquals(hasher.hash(req(new BigDecimal("42.00"), 1)),
                     hasher.hash(req(new BigDecimal("42.0"), 1)),
                "trailing-zero-equivalent amounts must hash identically");
    }

    @Test
    void differentAmountProducesDifferentHash() {
        assertNotEquals(hasher.hash(req(new BigDecimal("100.00"), 1)),
                        hasher.hash(req(new BigDecimal("999.99"), 1)),
                "different amount = semantic conflict = different hash");
    }

    @Test
    void differentQuantityProducesDifferentHash() {
        assertNotEquals(hasher.hash(req(new BigDecimal("10.00"), 1)),
                        hasher.hash(req(new BigDecimal("10.00"), 2)));
    }

    @Test
    void hashIsHex64() {
        assertTrue(hasher.hash(req(new BigDecimal("1.00"), 1)).matches("[0-9a-f]{64}"));
    }
}
