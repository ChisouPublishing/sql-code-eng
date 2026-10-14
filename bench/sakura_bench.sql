-- sakura_bench.sql -- Custom pgbench script: shopping flow (read only; Chapter 13, section 13.4)
-- codes/sql-code-eng/bench/sakura_bench.sql@v1.2.2
-- One transaction = one user who logs in -> views a product -> browses the same category
-- -> views the order history.
-- Each lookup reads a few rows through a unique index or a foreign key index
-- (the same access pattern as real screens).
-- Users and products come from the medium numbers
-- (user_medium_1 to 99900, SKU-M-00001 to 09900).
-- Both sakura_market and sakura_xl have them.
-- (A database with only the small data returns 0 rows, but the SQL does not fail.)
-- Run (pgbench in a container):
--   docker run --rm --network sql-code-eng_default -e PGPASSWORD=sakura_dev -v "$PWD/bench:/bench:ro" postgres:18 \
--     pgbench -n -c 10 -j 2 -T 60 -f /bench/sakura_bench.sql -U sakura -d sakura_xl -h sakura_market_db
-- Debug: pgbench -n -c 1 -j 1 -t 1 -f /bench/sakura_bench.sql ...
\set user_no random(1, 99900)
\set product_no random(1, 9900)

-- Login: look up the user by email address (unique index)
SELECT id, rank FROM sakura.users
WHERE email = 'user_medium_' || :user_no || '@example.com';
-- Product page: look up the product and its stock by SKU (unique index)
SELECT p.id, p.name_en, p.price, i.stock
FROM sakura.products p JOIN sakura.inventory i ON i.product_id = p.id
WHERE p.sku = 'SKU-M-' || lpad(:product_no::text, 5, '0');
-- Product search: the 5 cheapest products in the same category
SELECT id, name_en, price FROM sakura.products
WHERE category_id = (SELECT category_id FROM sakura.products
                     WHERE sku = 'SKU-M-' || lpad(:product_no::text, 5, '0'))
  AND deleted_at IS NULL
ORDER BY price LIMIT 5;
-- Order history: the user's 10 newest orders
SELECT o.id, o.status, o.amount, o.ordered_at
FROM sakura.orders o
WHERE o.user_id = (SELECT id FROM sakura.users WHERE email = 'user_medium_' || :user_no || '@example.com')
ORDER BY o.ordered_at DESC LIMIT 10;
