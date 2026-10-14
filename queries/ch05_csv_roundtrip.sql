-- ch05_csv_roundtrip.sql -- Import CSV, validate types, and check a round trip (Chapter 5)
-- codes/sql-code-eng/queries/ch05_csv_roundtrip.sql@v1.2.2
-- Copy examples/csv/input.csv to /tmp/ai-sql-eng-csv-input.csv in the container first.
-- Uses temporary tables only; existing business tables are unchanged.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL DateStyle TO 'ISO, YMD';
SET LOCAL TIME ZONE 'America/New_York';

-- 1. Preserve the input representation by importing every column as text.
CREATE TEMP TABLE csv_stage (
    item_code text, label text, observed_on text, amount text, memo text
) ON COMMIT DROP;
\copy csv_stage FROM '/tmp/ai-sql-eng-csv-input.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8', NULL '\N')

-- 2. Validate the representation before converting dates and USD amounts.
SELECT count(*) AS imported_rows FROM csv_stage;
SELECT count(*) AS invalid_rows
FROM csv_stage
WHERE item_code IS NULL OR item_code !~ '^[0-9]{5}$'
   OR label IS NULL OR label = ''
   OR observed_on IS NULL OR observed_on !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
   OR amount IS NULL OR amount !~ '^[0-9]+\.[0-9]{2}$';
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM csv_stage
        WHERE item_code IS NULL OR item_code !~ '^[0-9]{5}$'
           OR label IS NULL OR label = ''
           OR observed_on IS NULL OR observed_on !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
           OR amount IS NULL OR amount !~ '^[0-9]+\.[0-9]{2}$'
    ) THEN
        RAISE EXCEPTION 'Check the CSV representation before converting types';
    END IF;
END;
$$;
-- Casting also rejects impossible dates such as 2026-02-30.
CREATE TEMP TABLE csv_typed ON COMMIT DROP AS
SELECT item_code, label, observed_on::date AS observed_on,
       amount::numeric(12,2) AS amount, memo
FROM csv_stage;
SELECT item_code, observed_on, amount,
       memo IS NULL AS memo_is_null,
       memo = '' AS memo_is_empty
FROM csv_typed ORDER BY item_code;

-- 3. Fix both column order and row order for the export.
\copy (SELECT item_code, label, observed_on, amount, memo FROM csv_typed ORDER BY item_code) TO '/tmp/ai-sql-eng-csv-output.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8', NULL '\N')

-- 4. Reload the exported file and compare both directions, including duplicates.
CREATE TEMP TABLE csv_reloaded (LIKE csv_typed) ON COMMIT DROP;
\copy csv_reloaded FROM '/tmp/ai-sql-eng-csv-output.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8', NULL '\N')
SELECT count(*) AS roundtrip_diff
FROM (
    (SELECT * FROM csv_typed EXCEPT ALL SELECT * FROM csv_reloaded)
    UNION ALL
    (SELECT * FROM csv_reloaded EXCEPT ALL SELECT * FROM csv_typed)
) AS differences;
ROLLBACK;
