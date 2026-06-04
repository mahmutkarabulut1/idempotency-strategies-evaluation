package com.idemstudy;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Idempotent Operation Service.
 *
 * A domain-independent "logical operation" processor used as the experimental
 * testbed for comparing idempotency and distributed-locking strategies. The
 * active strategy is selected at startup via the {@code idem.strategy} property.
 */
@SpringBootApplication
@EnableScheduling
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
