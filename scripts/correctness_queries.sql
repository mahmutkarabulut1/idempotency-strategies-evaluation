-- Ground-truth correctness verification, computed directly from the side-effect
-- audit table (independent of any in-app counter). :run is the experiment_run id.
\set run :run

-- Headline metric: Duplicate Side-Effect Violation Rate for this run.
SELECT 'violation_rate' AS metric,
       strategy,
       logical_ops,
       violating_ops,
       violation_rate
FROM   v_violation_rate
WHERE  experiment_run = :'run';

-- Number of logical operations that received more than one side effect.
SELECT 'violating_ops_count' AS metric,
       count(*) AS value
FROM   v_duplicate_side_effects
WHERE  experiment_run = :'run';

-- Total side effects vs distinct logical operations (suppression check).
SELECT 'side_effects_total'  AS metric, count(*) AS value
FROM   operation_side_effects WHERE experiment_run = :'run'
UNION ALL
SELECT 'logical_ops_distinct', count(DISTINCT operation_id)
FROM   operation_side_effects WHERE experiment_run = :'run';

-- Processed-message dedup (Strategy D/E): processed rows vs distinct operations.
SELECT 'processed_messages' AS metric, count(*) AS value FROM processed_messages
UNION ALL
SELECT 'processed_distinct_ops', count(DISTINCT operation_id) FROM processed_messages;
