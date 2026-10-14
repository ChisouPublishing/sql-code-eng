-- 07_large_data.sql -- Large data set: 10 million behavior log rows (benchmark database sakura_xl; Chapters 10-14)
-- codes/sql-code-eng/init/07_large_data.sql@v1.2.2
-- Prerequisite: 06_medium_data.sql is loaded. Load this into sakura_xl, not the default database:
--   make init-large DB=sakura_xl
-- What it does: empties behavior_logs and rebuilds 10 million rows over the past 365 days, in time order.
--   A log is append-only, so in real systems the physical order matches created_at.
--   BRIN then works well (Chapter 10).
--   Adding to the 1 million medium rows would make the time order wrap around twice,
--   so the table is rebuilt instead.
-- Time (measured, v1.2.0): see VALIDATION.md. Size about 1.6 GB (about 3 GB with indexes).
-- For a smaller test: CALL sakura.gen_behavior_logs(1000000, 365); (= 1 million rows)

SET search_path TO sakura, public;
SELECT setseed(0.44) \gset

TRUNCATE behavior_logs;
CALL sakura.gen_behavior_logs(10000000, 365, 1000000);

ANALYZE behavior_logs;
