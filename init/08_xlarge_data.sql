-- 08_xlarge_data.sql -- Extra-large data set, 10 million orders (benchmark database sakura_xl; Chapters 10-14)
-- codes/sql-code-eng/init/08_xlarge_data.sql@v1.2.2
-- Prerequisite: sakura_xl with everything up to 07_large_data.sql loaded:
--   make init-xlarge DB=sakura_xl   (= loads small -> medium -> large -> xlarge in order)
-- Size: users 1,000,000 / products 100,000 / orders 10,000,000 / order_items about 30,000,000 /
--   status history about 40,000,000 / payments and shipments about 10,000,000 each.
-- Time and size: see VALIDATION.md (the Japanese edition measured about 25 minutes and 22 GB).
--   Watch the free disk space with df -h while loading.
-- Approach:
--   * Orders come from the shared procedure sakura.gen_orders (04b_generators.sql).
--     The business rules match small and medium
--     (status history, payments, shipments, returns, coupons, shipping fee, reviews).
--   * Commits every 100,000 orders. The period (past 730 days) is split into 99 slices,
--     created from oldest to newest. Orders are appended in time order, as in production.
--   * Amounts are computed from the order items before INSERT.
--     A later UPDATE of 10 million rows would almost double the table size.
--   * If the load stops partway: run this file again.
--     It creates only the orders still missing to reach 10 million.
--     (The added orders spread over the whole period, so the time order is slightly broken.)

SET search_path TO sakura, public;
SELECT setseed(0.45) \gset

-- Users up to 1,000,000 (user_xl_N, signup dates over the past 3 years)
SELECT GREATEST(0, 1000000 - count(*))::int AS n_users FROM users \gset
CALL sakura.gen_users('user_xl_', :n_users, 1095);

-- Products up to 100,000 (SKU-X-000001 and up) and inventory
SELECT GREATEST(0, 100000 - count(*))::int AS n_products FROM products \gset
CALL sakura.gen_products('SKU-X-', 'X', 6, :n_products);

ANALYZE users;
ANALYZE addresses;
ANALYZE products;
ANALYZE inventory;

-- Orders up to 10,000,000 (100,000 medium + 9,900,000 = 99 batches x 100,000)
SELECT GREATEST(0, 10000000 - count(*))::int AS n_orders FROM orders \gset
CALL sakura.gen_orders(:n_orders, 730, 5, 100000, 0.1, 0.12);

-- Statistics (all tables)
ANALYZE;
