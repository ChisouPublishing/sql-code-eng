-- 05_small_data.sql -- Small data set, about 100 rows per table (Chapter 5 section 5.6; checks for Chapter 6)
-- codes/sql-code-eng/init/05_small_data.sql@v1.2.2
-- Prerequisite: 01 to 04 and 04b_generators.sql are loaded.
-- Approach: reproducible. Run SELECT setseed(0.42), then call the shared gen_* procedures.
--   A rebuild gives the same users and products (except ids and times).
--   The order status mix changes a little with the load time.
-- Size (measured, v1.2.0): users 100 / addresses about 120 / products 100 / orders 50 /
--   order_items about 100 / status history about 190 / payments about 50 /
--   shipments about 45 / behavior_logs 200.
-- See the top of 04b_generators.sql for the business rules
-- (status flow, amount breakdown, coupons, shipping fee, and so on).

SET search_path TO sakura, public;
SELECT setseed(0.42) \gset

-- 100 users (signup dates spread over the past 365 days.
-- Ranks: platinum 1 / gold 5 / silver 20 / bronze 74)
CALL sakura.gen_users('user_', 100, 365);

-- 100 products (SKU-0001 to SKU-0100) and inventory
CALL sakura.gen_products('SKU-', '', 4, 100);

-- 50 orders (1 to 3 lines each).
-- To show NULLs and cancellations even in a small data set,
-- 30% of orders try a coupon and half of the delivered orders get a review.
--   45 orders: past 90 days (almost all delivered)
--    5 orders: past 1 day (some stay ordered, paid, or shipped)
CALL sakura.gen_orders(45, 90, 3, 100000, 0.5, 0.3);
CALL sakura.gen_orders(5, 1, 3, 100000, 0.5, 0.3);

-- 200 behavior log rows (past 30 days, in time order)
CALL sakura.gen_behavior_logs(200, 30);

-- Statistics. Small tables do not reach the autovacuum ANALYZE threshold,
-- so analyze every table explicitly.
ANALYZE;
