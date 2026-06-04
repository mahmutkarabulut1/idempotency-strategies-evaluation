-- =====================================================================
-- Schema for the idempotency / distributed-locking experimental testbed.
-- Domain-independent "logical operation" model (see docs/research_questions.md).
-- =====================================================================

-- ---- Core operation record ------------------------------------------
CREATE TABLE IF NOT EXISTS operations (
    operation_id    UUID PRIMARY KEY,
    idempotency_key TEXT        NOT NULL,
    operation_type  TEXT        NOT NULL,   -- PAYMENT, ORDER_CREATION, ...
    entity_id       TEXT        NOT NULL,
    user_id         TEXT        NOT NULL,
    payload_hash    TEXT        NOT NULL,   -- SHA-256 of semantically-relevant payload
    amount          NUMERIC(18,2),
    quantity        INTEGER,
    metadata        JSONB,
    retry_attempt   INTEGER     NOT NULL DEFAULT 0,
    request_source  TEXT,
    status          TEXT        NOT NULL DEFAULT 'COMPLETED', -- COMPLETED | CONFLICT | FAILED
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---- Strategy A: DB-level idempotency -------------------------------
-- The UNIQUE constraint is the correctness primitive: the first writer wins,
-- all concurrent duplicates fail with a unique violation and replay the result.
CREATE TABLE IF NOT EXISTS idempotency_records (
    idempotency_key TEXT        NOT NULL,
    payload_hash    TEXT        NOT NULL,
    operation_id    UUID        NOT NULL,
    response_code   INTEGER     NOT NULL,
    response_body   JSONB,
    locked_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ,
    CONSTRAINT pk_idempotency_records PRIMARY KEY (idempotency_key)
);
-- Composite index supports Strategy F (key + payload-hash conflict detection).
CREATE INDEX IF NOT EXISTS ix_idem_key_hash
    ON idempotency_records (idempotency_key, payload_hash);

-- ---- The audited side effect ----------------------------------------
-- Every successful business effect appends one row. The core correctness
-- metric is computed by GROUP BY operation_id HAVING count(*) > 1.
CREATE TABLE IF NOT EXISTS operation_side_effects (
    side_effect_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id    UUID        NOT NULL,
    idempotency_key TEXT        NOT NULL,
    strategy        TEXT        NOT NULL,   -- DB | REDIS | ZK | KAFKA | OUTBOX | PAYLOAD_HASH
    experiment_run  TEXT        NOT NULL,
    instance_id     TEXT,
    applied_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS ix_side_effects_op  ON operation_side_effects (operation_id);
CREATE INDEX IF NOT EXISTS ix_side_effects_run ON operation_side_effects (experiment_run);

-- ---- Strategy D/E: Kafka consumer idempotency -----------------------
CREATE TABLE IF NOT EXISTS processed_messages (
    event_id      UUID        NOT NULL PRIMARY KEY,
    operation_id  UUID        NOT NULL,
    consumer_group TEXT       NOT NULL,
    processed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Dedup at the logical-operation level: at most one processed row (hence one
    -- side effect) per operation per consumer group, regardless of how many
    -- distinct events (redeliveries or same-key duplicates) carry it.
    CONSTRAINT uq_processed_operation UNIQUE (operation_id, consumer_group)
);

-- ---- Strategy E: Transactional outbox -------------------------------
CREATE TABLE IF NOT EXISTS outbox_events (
    event_id      UUID        PRIMARY KEY,
    aggregate_id  UUID        NOT NULL,
    topic         TEXT        NOT NULL,
    -- Serialized event JSON stored as TEXT (the relay reads it back as a string
    -- and republishes verbatim; no server-side JSON querying is needed). Using
    -- TEXT avoids the varchar->jsonb implicit-cast error from the JDBC driver.
    payload       TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at  TIMESTAMPTZ,
    status        TEXT        NOT NULL DEFAULT 'PENDING' -- PENDING | PUBLISHED
);
CREATE INDEX IF NOT EXISTS ix_outbox_pending ON outbox_events (status, created_at)
    WHERE status = 'PENDING';

-- ---- Experiment bookkeeping -----------------------------------------
CREATE TABLE IF NOT EXISTS experiment_runs (
    run_id        TEXT        PRIMARY KEY,
    strategy      TEXT        NOT NULL,
    scenario      TEXT        NOT NULL,   -- E1..E7
    params        JSONB,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS experiment_results (
    run_id        TEXT        NOT NULL REFERENCES experiment_runs(run_id),
    metric        TEXT        NOT NULL,
    value         DOUBLE PRECISION NOT NULL,
    recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---- Correctness verification view ----------------------------------
-- A "violation" = a logical operation with more than one successful side effect.
CREATE OR REPLACE VIEW v_duplicate_side_effects AS
SELECT experiment_run,
       strategy,
       operation_id,
       count(*) AS side_effect_count
FROM   operation_side_effects
GROUP  BY experiment_run, strategy, operation_id
HAVING count(*) > 1;

-- Duplicate Side-Effect Violation Rate per run (the paper's headline metric).
CREATE OR REPLACE VIEW v_violation_rate AS
WITH per_run AS (
    SELECT experiment_run,
           strategy,
           count(DISTINCT operation_id)                                  AS logical_ops,
           count(DISTINCT operation_id) FILTER (WHERE TRUE)              AS total_ops
    FROM   operation_side_effects
    GROUP  BY experiment_run, strategy
), violations AS (
    SELECT experiment_run, strategy, count(*) AS violating_ops
    FROM   v_duplicate_side_effects
    GROUP  BY experiment_run, strategy
)
SELECT p.experiment_run,
       p.strategy,
       p.logical_ops,
       COALESCE(v.violating_ops, 0)                                     AS violating_ops,
       ROUND(COALESCE(v.violating_ops,0)::numeric / NULLIF(p.logical_ops,0), 6) AS violation_rate
FROM   per_run p
LEFT   JOIN violations v USING (experiment_run, strategy);
