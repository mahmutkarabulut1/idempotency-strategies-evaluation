package com.idemstudy.domain;

import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

/**
 * Computes a stable SHA-256 over the *semantically relevant* fields of a request.
 * Strategy F binds the idempotency key to this hash: same key + different hash =
 * semantic conflict, not a legitimate retry.
 */
@Component
public class PayloadHasher {

    public String hash(OperationRequest r) {
        // Deterministic field ordering; nulls normalised to empty.
        String canonical = String.join("|",
                nz(r.operationType()),
                nz(r.entityId()),
                nz(r.userId()),
                r.amount() == null ? "" : r.amount().stripTrailingZeros().toPlainString(),
                r.quantity() == null ? "" : r.quantity().toString());
        return sha256(canonical);
    }

    private static String nz(String s) { return s == null ? "" : s; }

    private static String sha256(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(s.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(d);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    /** Exposed for tests / payload-hash experiment data generation. */
    public String hashAmount(BigDecimal amount) {
        return sha256(amount == null ? "" : amount.toPlainString());
    }
}
