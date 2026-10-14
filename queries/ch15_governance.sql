-- ch15_governance.sql -- Governance, privileges, and auditing (Chapter 15, section 15.3)
-- codes/sql-code-eng/queries/ch15_governance.sql@v1.2.2
-- Prerequisite: default database sakura_market. Runs on plain postgres:18 (no vector extension needed).
-- The whole file runs between BEGIN and ROLLBACK.
-- Roles, privileges, RLS, triggers, and the audit table do not stay in the database.
-- To apply it for real, change the final ROLLBACK to COMMIT
-- (note that roles apply to the whole database cluster).

SET search_path TO sakura, public;

BEGIN;

-- ===== Roles and privileges =====
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE ROLE analyst WITH LOGIN PASSWORD 'analyst_dev';      -- analyst (read only)
CREATE ROLE developer WITH LOGIN PASSWORD 'developer_dev';  -- developer (read and write)

GRANT USAGE ON SCHEMA sakura TO analyst, developer;
GRANT SELECT ON ALL TABLES IN SCHEMA sakura TO analyst;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sakura TO developer;

-- Column restriction (hide email addresses from analyst)
-- Wrong: REVOKE SELECT (email) ON users FROM analyst;
--   -> The table-level SELECT privilege remains, so email is still readable.
--      (A column-level REVOKE does not reduce a table-level privilege.)
-- Correct: revoke SELECT on the table, then grant only the allowed columns.
REVOKE SELECT ON users FROM analyst;
GRANT SELECT (id, display_name, rank, created_at, updated_at, deleted_at) ON users TO analyst;

-- Check: which columns of users can analyst read?
SELECT column_name, privilege_type
FROM information_schema.column_privileges
WHERE grantee = 'analyst' AND table_schema = 'sakura' AND table_name = 'users'
ORDER BY column_name;

-- Try it (SET LOCAL ROLE lasts only for this transaction)
SET LOCAL ROLE analyst;
SELECT id, display_name, rank FROM users LIMIT 1;   -- readable
SAVEPOINT try_email;
DO
$do$
BEGIN
    PERFORM email FROM sakura.users LIMIT 1;
    RAISE NOTICE 'NG: analyst was able to read email';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: analyst cannot read email (%)', SQLERRM;
END;
$do$;
RESET ROLE;

-- ===== Row-level security (RLS) =====
-- analyst sees only the orders of the user set by the application (app.current_user_id).
-- current_setting(..., true) returns NULL when the setting is missing,
-- and can return an empty string '' after a reset.
-- ''::uuid raises an error, so NULLIF turns '' into NULL before the cast (NULL gives 0 rows).
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_orders_self ON orders
    FOR SELECT TO analyst
    USING (user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid);

-- Limit order items to the same user's orders too.
-- (With RLS on orders only, every order item is still visible.)
-- The analyst RLS also applies to orders in the subquery, so only that user's items remain.
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_order_items_self ON order_items
    FOR SELECT TO analyst
    USING (order_id IN (SELECT id FROM orders));
-- Note: other tables tied to orders (payments, shipments, returns, and so on)
--   are not covered by RLS in this example.
--   To hide them per user in production, add policies of the same form.

-- Test: pick one user who has orders, and count as that user
SELECT user_id AS sample_user FROM orders ORDER BY ordered_at DESC LIMIT 1 \gset
SET LOCAL ROLE analyst;
SELECT count(*) AS orders_without_setting FROM orders;          -- not set -> 0
SELECT set_config('app.current_user_id', :'sample_user', true);
SELECT count(*) AS orders_visible FROM orders;                  -- only that user's orders
SELECT count(*) AS items_visible FROM order_items;              -- only that user's order items
SELECT set_config('app.current_user_id', '', true);
SELECT count(*) AS orders_after_reset FROM orders;              -- empty string -> 0 (no error)
RESET ROLE;

-- ===== Audit log =====
CREATE TABLE audit_logs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_name text NOT NULL,
    action text NOT NULL,
    table_name text NOT NULL,
    record_id uuid,
    old_value jsonb,
    new_value jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION audit_trigger() RETURNS trigger
LANGUAGE plpgsql AS
$fn$
BEGIN
    INSERT INTO audit_logs (user_name, action, table_name, record_id, old_value, new_value)
    VALUES (current_user, TG_OP, TG_TABLE_NAME,
            COALESCE((to_jsonb(NEW)->>'id')::uuid, (to_jsonb(OLD)->>'id')::uuid),
            to_jsonb(OLD), to_jsonb(NEW));
    RETURN COALESCE(NEW, OLD);
END;
$fn$;

CREATE TRIGGER users_audit
AFTER INSERT OR UPDATE OR DELETE ON users
FOR EACH ROW EXECUTE FUNCTION audit_trigger();

-- Test: a rank change leaves the old and new values in the audit log
-- (the trigger updates updated_at automatically)
UPDATE users SET rank = 'platinum' WHERE email = 'user_1@example.com';   -- gold -> platinum
SELECT user_name, action, table_name,
       old_value->>'rank' AS old_rank, new_value->>'rank' AS new_rank,
       (new_value->>'updated_at')::timestamptz > (old_value->>'updated_at')::timestamptz AS updated_at_moved
FROM audit_logs;

-- ===== Privacy and quality =====
-- Anonymization (hash email with SHA-256; cannot be reversed)
SELECT encode(digest(email, 'sha256'), 'hex') AS anon_email
FROM users ORDER BY email LIMIT 5;

-- Quality checks (NULLs, negative values, and amount breakdown across tables)
SELECT 'users_null_email' AS chk, count(*) FROM users WHERE email IS NULL
UNION ALL
SELECT 'orders_negative_amount', count(*) FROM orders WHERE amount < 0
UNION ALL
SELECT 'orders_breakdown_mismatch', count(*) FROM orders
WHERE amount <> subtotal - discount_amount + shipping_fee;

ROLLBACK;   -- undo everything (roles, privileges, RLS, trigger, audit table, extension)
