-- ch11_monitoring.sql -- Slow query log and monitoring (Chapter 11)
-- codes/sql-code-eng/queries/ch11_monitoring.sql@v1.2.2
-- Prerequisite: docker-compose.yml (shared_preload_libraries=pg_stat_statements, slow log at 200 ms).
--   Works on either database. To collect slow queries, run it on sakura_xl
--   after the queries of Chapters 10 and 12.

SET search_path TO sakura, public;

-- ===== Check the settings =====
SHOW log_min_duration_statement;  -- expect 200
SHOW shared_preload_libraries;    -- expect it to include pg_stat_statements

-- To change a setting: the compose file of this book sets log_min_duration_statement
-- and log_line_prefix as server start options (-c).
-- Start options take precedence over ALTER SYSTEM.
-- To change the values, edit docker-compose.yml and run docker compose up -d (restart).
-- (ALTER SYSTEM SET ... + pg_reload_conf() does not change them. This was confirmed by testing.)

-- ===== Enable pg_stat_statements =====
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top 20 by total time
SELECT queryid, calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows, left(query, 120) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC LIMIT 20;

-- By mean time (queries run 10 or more times)
SELECT queryid, calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       round(max_exec_time::numeric, 2) AS max_ms,
       left(query, 120) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%' AND calls >= 10
ORDER BY mean_exec_time DESC LIMIT 20;

-- By number of calls
SELECT queryid, calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       left(query, 120) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY calls DESC LIMIT 20;

-- By I/O load (queries that read the most blocks)
SELECT queryid, calls, shared_blks_read,
       round(100.0 * shared_blks_read / NULLIF(shared_blks_read + shared_blks_hit, 0), 2) AS read_ratio_pct,
       left(query, 120) AS query
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY shared_blks_read DESC LIMIT 20;

-- Reset (when you start a new measurement)
-- SELECT pg_stat_statements_reset();

-- ===== Snapshot table (collect regularly, then compare differences) =====
CREATE TABLE IF NOT EXISTS pgss_snapshots (
    snapshot_at timestamptz NOT NULL DEFAULT now(),
    queryid bigint NOT NULL,
    query text NOT NULL,
    calls bigint NOT NULL,
    total_exec_time double precision NOT NULL,
    mean_exec_time double precision NOT NULL,
    rows bigint NOT NULL
);

INSERT INTO pgss_snapshots (queryid, query, calls, total_exec_time, mean_exec_time, rows)
SELECT queryid, query, calls, total_exec_time, mean_exec_time, rows
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%';

-- Schedule it where pg_cron is available (skipped if the stock image does not have it)
DO
$do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('pgss-snapshot', '0 * * * *',
            $$INSERT INTO sakura.pgss_snapshots (queryid, query, calls, total_exec_time, mean_exec_time, rows)
              SELECT queryid, query, calls, total_exec_time, mean_exec_time, rows
              FROM pg_stat_statements WHERE query NOT LIKE '%pg_stat_statements%'$$);
        PERFORM cron.schedule('pgss-cleanup', '0 3 * * *',
            $$DELETE FROM sakura.pgss_snapshots WHERE snapshot_at < now() - interval '30 days'$$);
    ELSE
        RAISE NOTICE 'pg_cron not available; snapshot manually';
    END IF;
END;
$do$;

-- ===== Daily monitoring queries =====
-- Number of queries with a mean time over 1 second
SELECT count(*) AS slow_queries FROM pg_stat_statements WHERE mean_exec_time > 1000;
-- Unused indexes
SELECT relname, indexrelname FROM pg_stat_user_indexes
WHERE schemaname = 'sakura' AND idx_scan = 0 ORDER BY 1, 2;
-- Table sizes
SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables WHERE schemaname = 'sakura'
ORDER BY pg_total_relation_size(relid) DESC;
-- Cache hit ratio
SELECT relname,
       round(100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0), 2) AS hit_pct
FROM pg_statio_user_tables WHERE schemaname = 'sakura' ORDER BY relname;

-- ===== pgBadger (log reports; Chapter 11 section 08) =====
-- docker compose logs adds "sakura_market_db  | " to the start of each line.
-- pgBadger cannot parse that prefix, so remove it with sed first.
-- Also pass log_line_prefix (the same string as the compose -c option) with --prefix.
--   docker compose logs postgres > /tmp/postgresql.log
--   sed 's/^[^|]*| //' /tmp/postgresql.log > /tmp/pg.clean.log
--   pgbadger --prefix '%m [%p] %q%u@%d ' /tmp/pg.clean.log -o /tmp/pgbadger.html
