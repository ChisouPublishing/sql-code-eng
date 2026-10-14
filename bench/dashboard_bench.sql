-- dashboard_bench.sql -- Custom pgbench script: read the dashboard (Chapter 14)
-- codes/sql-code-eng/bench/dashboard_bench.sql@v1.2.2
-- Prerequisite: queries/ch14_dashboard.sql has run (the materialized view exists).
-- Measure on the benchmark database sakura_xl.
-- Run: docker run --rm --network sql-code-eng_default -e PGPASSWORD=sakura_dev -v "$PWD/bench:/bench:ro" postgres:18 \
--        pgbench -n -c 50 -j 8 -T 300 -f /bench/dashboard_bench.sql -U sakura -d sakura_xl -h sakura_market_db
-- P95/P99: collect with pgbench --log --log-prefix=/tmp/... and aggregate the log (Chapter 13, section 13.6).
SELECT category_name, total_sales, order_count, customer_count, prev_sales, growth_pct, refreshed_at
FROM sakura.mv_category_sales_dashboard ORDER BY total_sales DESC;
