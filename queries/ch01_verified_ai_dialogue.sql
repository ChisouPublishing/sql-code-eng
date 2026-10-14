-- ch01_verified_ai_dialogue.sql — Observed English replies and reference checks
-- Evidence: evidence/20261012_ai_response_verification/
-- Run against the intended English learning DB (sakura_market_eng in the shared workspace).
-- These are observed SELECTs, not a prediction of future model replies.
BEGIN READ ONLY;
SET LOCAL search_path TO sakura, public;
SET LOCAL TIME ZONE 'America/New_York';
SET LOCAL statement_timeout TO '5s';

-- 04-legacy-example (observed SQL; full reply retained in evidence)
SELECT email AS customer_name FROM users WHERE rank = 'gold' LIMIT 5;

-- 05-improved (observed SQL; full reply retained in evidence)
SELECT display_name AS customer_name FROM users WHERE rank = 'gold' AND deleted_at IS NULL ORDER BY id ASC LIMIT 5;

-- 06-legacy-repeat (observed SQL; full reply retained in evidence)
-- Uses display_name instead of email because the request is for customer names; the column alias stays customer_name.
-- Excludes soft-deleted users (deleted_at IS NULL) and orders by created_at, id so the same 5 rows return each time.
SELECT display_name AS customer_name
FROM users
WHERE rank = 'gold'
  AND deleted_at IS NULL
ORDER BY created_at, id
LIMIT 5;

-- 07-explicit-definitions (observed SQL; full reply retained in evidence)
SELECT
    id,
    display_name AS customer_name
FROM sakura.users
WHERE rank = 'gold'
  AND deleted_at IS NULL
ORDER BY id ASC
LIMIT 5;

-- 08-exact-output (observed SQL; full reply retained in evidence)
SELECT display_name AS customer_name
FROM users
WHERE rank = 'gold'
  AND deleted_at IS NULL
ORDER BY id ASC
LIMIT 5;

-- Author reference, not an AI response
SELECT display_name AS customer_name
FROM sakura.users
WHERE rank = 'gold'
  AND deleted_at IS NULL
ORDER BY id
LIMIT 5;

ROLLBACK;
