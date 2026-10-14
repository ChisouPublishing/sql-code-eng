-- 06_medium_data.sql -- Medium data set, about 100,000 rows (default database sakura_market; Chapters 4-9 and 15)
-- codes/sql-code-eng/init/06_medium_data.sql@v1.2.2
-- Prerequisite: 05_small_data.sql is loaded (this file adds to the small data).
-- Size: users 100,000 / products 10,000 / orders 100,000 /
--   order_items about 300,000 (1 to 5 lines, 3 on average) /
--   status history about 400,000 / behavior_logs about 1,000,000 (past 365 days, in time order).
-- Time (measured, v1.2.0): see VALIDATION.md (about 30 seconds).
-- Bug in v1.1.1 and earlier: category_id and seller_id of products came from an
--   uncorrelated subquery (SELECT id FROM categories ORDER BY random() LIMIT 1).
--   PostgreSQL ran it only once as an InitPlan,
--   so all 9,900 added products got the same category and seller.
--   v1.2.0 uses the shared procedures (array index assignment) instead.
-- See the top of 04b_generators.sql for the business rules.

SET search_path TO sakura, public;
SELECT setseed(0.43) \gset

-- +99,900 users (signup dates over the past 3 years.
-- Some users signed up before the 2-year order period starts.)
CALL sakura.gen_users('user_medium_', 99900, 1095);

-- +9,900 products (SKU-M-00001 and up) and inventory
CALL sakura.gen_products('SKU-M-', 'M', 5, 9900);

-- +99,950 orders (past 730 days, 1 to 5 lines). With the 50 small orders, 100,000 in total
CALL sakura.gen_orders(99950, 730, 5);

-- +1,000,000 behavior log rows (past 365 days, appended in time order)
CALL sakura.gen_behavior_logs(1000000, 365);

-- Statistics for every table, for accurate EXPLAIN estimates (including small tables such as categories)
ANALYZE;
