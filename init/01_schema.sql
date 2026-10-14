-- 01_schema.sql -- Create the working schema (Chapter 2)
-- codes/sql-code-eng/init/01_schema.sql@v1.2.2
-- Run: psql -U sakura -d sakura_market -f init/01_schema.sql
--      (The benchmark database sakura_xl uses the same file: -d sakura_xl)

CREATE SCHEMA IF NOT EXISTS sakura;

SET search_path TO sakura, public;

-- Make sakura the first schema for all later connections too.
-- psql replaces :"DBNAME" with the name of the current database.
-- The file therefore works for both sakura_market and sakura_xl.
ALTER DATABASE :"DBNAME" SET search_path TO sakura, public;
