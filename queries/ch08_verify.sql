-- ch08_verify.sql -- Trial runs in four steps, verification, defense, and privileges (Chapter 8)
-- codes/sql-code-eng/queries/ch08_verify.sql@v1.2.2
-- Run the steps in order. Every write in section 8.4 is rolled back.
-- Prerequisite: default database sakura_market (small + medium).
-- The privileges section also ends with ROLLBACK, so no roles stay in the database.
SET search_path TO sakura, public;

-- ===== Step 1: syntax check (does not run the query) =====
EXPLAIN
SELECT u.display_name, count(o.id) AS orders
FROM users u LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.display_name;

-- ===== Step 2: small sample (LIMIT 100) =====
SELECT o.id, o.status, o.amount, o.ordered_at
FROM orders o ORDER BY o.ordered_at DESC LIMIT 100;

-- ===== Step 3: edge cases =====
-- NULL: are there orders without a coupon?
SELECT count(*) AS no_coupon FROM orders WHERE coupon_id IS NULL;
-- Zero rows: a rank that does not exist
SELECT count(*) AS zero_case FROM users WHERE rank = 'diamond';
-- Minimum and maximum: both ends of the order amount
SELECT MIN(amount) AS min_amount, MAX(amount) AS max_amount FROM orders;
-- Duplicates: does UNIQUE prevent two reviews of the same product by the same user?
SELECT user_id, product_id, count(*) FROM reviews
GROUP BY user_id, product_id HAVING count(*) > 1;

-- ===== Count reconciliation (all users - users who ordered = users who never ordered) =====
SELECT (SELECT count(*) FROM users) AS all_users,
       (SELECT count(DISTINCT user_id) FROM orders) AS ordered_users,
       (SELECT count(*) FROM users u WHERE NOT EXISTS (
           SELECT 1 FROM orders o WHERE o.user_id = u.id)) AS never_ordered;

-- ===== Data integrity checks (expect 0 each) =====
-- Foreign keys
SELECT count(*) AS orphan_items FROM order_items oi
LEFT JOIN orders o ON oi.order_id = o.id WHERE o.id IS NULL;
-- Date logic
SELECT count(*) AS bad_dates FROM shipments s
JOIN orders o ON s.order_id = o.id
WHERE s.shipped_at < o.ordered_at;
-- Business rules
SELECT count(*) AS negative_stock FROM inventory WHERE stock < 0;
-- Amount reconciliation (v1.2.0 and later): payment amount = amount charged,
-- and amount charged = subtotal - discount + shipping
SELECT count(*) AS payment_mismatch FROM payments p
JOIN orders o ON o.id = p.order_id WHERE p.amount <> o.amount;
SELECT count(*) AS breakdown_mismatch FROM orders
WHERE amount <> subtotal - discount_amount + shipping_fee;

-- Find when orders were cancelled from the status history
-- (orders.status holds only the current status)
SELECT o.id, o.ordered_at, h.changed_at AS cancelled_at, h.from_status, h.note
FROM orders o
JOIN order_status_histories h ON h.order_id = o.id AND h.to_status = 'cancelled'
ORDER BY h.changed_at DESC
LIMIT 5;

-- ===== Step 4: wrap full runs in a transaction =====
BEGIN;
UPDATE products SET price = price * 1.1 WHERE sku = 'SKU-0001';
SELECT sku, price FROM products WHERE sku = 'SKU-0001';
ROLLBACK;

-- Using a savepoint
BEGIN;
UPDATE coupons SET used_count = used_count + 1 WHERE code = 'CPN0001';
SAVEPOINT sp1;
UPDATE coupons SET used_count = 999999 WHERE code = 'CPN0001';
ROLLBACK TO SAVEPOINT sp1;
SELECT code, used_count FROM coupons WHERE code = 'CPN0001';
ROLLBACK;

-- ===== Separation of privileges (a read-only user) =====
-- Roles are shared by the whole database cluster.
-- To leave no trial roles in a shared development database,
-- this section runs between BEGIN and ROLLBACK.
-- (CREATE ROLE and GRANT can both be rolled back.)
-- To create the roles for real, change ROLLBACK to COMMIT,
-- and run the cleanup at the end when you are done.
BEGIN;
CREATE ROLE app_readonly WITH LOGIN PASSWORD 'readonly_dev';
CREATE ROLE app_readwrite WITH LOGIN PASSWORD 'readwrite_dev';

GRANT USAGE ON SCHEMA sakura TO app_readonly;
-- Note: ON ALL TABLES also grants on views and materialized views, not only on tables
GRANT SELECT ON ALL TABLES IN SCHEMA sakura TO app_readonly;
-- Grant SELECT automatically on tables created later
-- (applies to tables owned by the role that runs this SQL)
ALTER DEFAULT PRIVILEGES IN SCHEMA sakura GRANT SELECT ON TABLES TO app_readonly;

GRANT USAGE ON SCHEMA sakura TO app_readwrite;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sakura TO app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA sakura
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_readwrite;

-- Check the privileges
SELECT grantee, table_name, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
FROM information_schema.table_privileges
WHERE grantee IN ('app_readonly', 'app_readwrite') AND table_schema = 'sakura'
GROUP BY grantee, table_name
ORDER BY grantee, table_name
LIMIT 20;

-- Confirm that the read-only role cannot write (SET LOCAL ROLE lasts only for this transaction)
SET LOCAL ROLE app_readonly;
SELECT count(*) AS readable_orders FROM orders;
SAVEPOINT before_write;
-- The next UPDATE should fail with "permission denied for table products"
DO
$do$
BEGIN
    UPDATE sakura.products SET price = price WHERE sku = 'SKU-0001';
    RAISE NOTICE 'NG: app_readonly was able to update';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: app_readonly cannot update (%)', SQLERRM;
END;
$do$;
RESET ROLE;
ROLLBACK;   -- undoes the roles, privileges, and default privileges

-- Cleanup (only if you created the roles with COMMIT): remove the privileges and
-- default privileges first, then drop the roles.
-- DROP OWNED BY removes privileges, default privileges, and owned objects in the current database
-- (run it in each database).
-- DROP ROLE fails with "role cannot be dropped because some objects depend on it" until then.
-- DROP OWNED BY app_readonly, app_readwrite;
-- DROP ROLE app_readonly;
-- DROP ROLE app_readwrite;
