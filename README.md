# sql-code-eng -- core SQL for the English edition

This package holds the reproducible SQL that every chapter of the English edition of the book uses.
It is the English edition of the Japanese SQL package.
The business and the table structure are the same. Names, comments, and data are localized for the United States.
The code is MIT licensed. The book text is All Rights Reserved.

## Two databases

| Database | Contents | Chapters | How to build |
| --- | --- | --- | --- |
| `sakura_market` (default) | small + medium (100,000 users, 100,000 orders, about 300,000 order items, about 1,000,000 behavior log rows) | 4-9, 15 | `make init-medium` |
| `sakura_xl` (benchmarks) | The same schema with medium + large + xlarge (1,000,000 users, 10,000,000 orders, about 30,000,000 order items, 10,000,000 behavior log rows) | 10-14 | `make init-xlarge DB=sakura_xl` |

Both databases live in the same container (`sakura_market_db`).
`docker-compose.yml` creates only `sakura_market` on first start.
The Makefile creates `sakura_xl` with `CREATE DATABASE`.
Choose the target database with `DB=...` (default `sakura_market`).

The container and database names match the Japanese edition. Run only one edition at a time.

## Files and chapters

| Path | Chapter | Contents |
| --- | --- | --- |
| `docker-compose.yml` | 2, Appendix B, 13 | PostgreSQL 18 (`io_method=worker`, slow log at 200 ms, `TZ=America/New_York`) + PgBouncer connection pool (profile `pool`) |
| `docker-compose.pgvector.yml` | 15 | Override for pgvector |
| `init/01_schema.sql` | 2 | `sakura` schema and search_path (set on the current database) |
| `init/02_tables.sql` | 4, 5 | DDL for 18 tables (PK = `uuidv7()`, amount breakdown, status history, copy of the shipping address, updated_at triggers) |
| `init/03_indexes.sql` | 5 | Base indexes (foreign key columns of child tables, common search columns, partial indexes) |
| `init/04_master_data.sql` | 5 | Categories, sellers, coupons, campaigns |
| `init/04b_generators.sql` | 5, Appendix C | Shared data generators (`gen_users`, `gen_products`, `gen_orders`, `gen_behavior_logs`) |
| `init/05_small_data.sql` | 5, 6 | About 100 rows per table, deterministic (seed 0.42) |
| `init/06_medium_data.sql` | 4-9 | About 100,000 rows + 1,000,000 behavior log rows (the complete `sakura_market`) |
| `init/07_large_data.sql` | 10-14 | Rebuilds the behavior log with 10,000,000 rows in time order (for `sakura_xl`) |
| `init/08_xlarge_data.sql` | 10-14 | 1,000,000 users, 100,000 products, 10,000,000 orders (for `sakura_xl`) |
| `queries/ch01_ai_errors.sql` | 1 | Four typical errors and three contrasting cases |
| `queries/ch06_basic_10.sql` | 6 | Ten real business queries (one sales definition) |
| `queries/ch07_ai_design_3cases.sql` | 7 | Three designs for one requirement (A, B, C wrong example, C' fixed) |
| `queries/ch08_verify.sql` | 8 | Trial runs in four steps, verification, defense, privileges (rolled back) |
| `queries/ch09_explain_5.sql` | 9 | Five slow queries and their fixes |
| `queries/ch10_index_design.sql` | 10 | Index types, multicolumn, INCLUDE, partial, skip scan, duplicate and unused index checks (`sakura_xl`) |
| `queries/ch11_monitoring.sql` | 11 | pg_stat_statements, snapshots, pgBadger |
| `queries/ch12_tuning.sql` | 12 | Rewrites, parameters, partitioning, materialized views, the full case (`sakura_xl`) |
| `queries/ch14_dashboard.sql` | 14 | A complete real-time sales dashboard (`sakura_xl`) |
| `queries/ch15_pgvector.sql` | 15 | pgvector, the RAG data layer, hybrid search (pgvector image) |
| `queries/ch15_governance.sql` | 15 | Governance, column privileges, RLS, auditing (rolled back) |
| `bench/sakura_bench.sql` | 13 | Custom pgbench script (shopping flow, read only) |
| `bench/dashboard_bench.sql` | 14 | Custom pgbench script (dashboard reads) |
| `checks/verify_all.sql` | 5, 8 | Row counts, foreign keys, foreign keys without an index, dates, business rules, amount reconciliation, status history, skew, size |
| `prompts/templates.md` | 7, Appendix D | Prompt templates |

## Business rules (shared by all chapters)

Sakura Market is an online store. Customers order products.
Payment, shipping, delivery, and sometimes a return follow.
All money is in US dollars with cents (`numeric(12,2)`).
Business days follow US Eastern Time (`America/New_York`).

**Sales and other definitions**

- Sales (product sales) = `SUM(order_items.quantity * order_items.price)`
  (unit price at order time, before coupon discounts, without shipping. Sales tax is out of scope.)
- What the customer pays is `orders.amount` (amount charged)
  = `subtotal` (sum of the order items) - `discount_amount` (coupon discount) + `shipping_fee`.
  Do not mix it up with sales.
- Exclude = `orders.status NOT IN ('cancelled','returned')`
  (cancelled and returned orders are not sales).
- Select periods with a time range on `ordered_at` (order time).
  Day boundaries are in Eastern Time (America/New_York). Use half-open intervals with `>=` and `<`.
  Do not wrap the column in a function. Write `ordered_at >= start AND ordered_at < end`,
  not `ordered_at::date = ...`. The index can then be used, and the result does not depend on the TimeZone setting.
- Do not add up distinct counts such as customer counts across days.
  Use `count(DISTINCT ...)` over the whole period.
- Exclude soft-deleted rows with `deleted_at IS NULL`. `rank` is lowercase (bronze/silver/gold/platinum).

**Order flow and records**

| Event | orders.status | Records |
| --- | --- | --- |
| Order placed | `ordered` | orders, order_items, status history (from NULL to ordered) |
| Payment (card and PayPal: minutes; bank transfer: 1 to 72 hours) | `paid` | payments (payment amount = amount charged), status history |
| Shipping (6 to 48 hours after payment) | `shipped` | shipments (address copied from the default address), status history |
| Delivery (18 to 72 hours after shipping) | `delivered` | shipments.delivered_at, status history |
| Cancellation (1 to 72 hours after the order. Before payment, this is an expired bank transfer) | `cancelled` | status history (when it was cancelled). The payment is failed if not paid yet, or refunded if paid |
| Return (2 to 10 days after delivery) | `returned` | returns (refund amount. Returns for customer reasons do not refund shipping), payments is refunded |

- Answer "When was it cancelled?" and "When was it paid?" with `changed_at` in `order_status_histories`.
  (orders holds only the current status.)
- Shipping is $5.99 if the subtotal is under $50.00. Otherwise it is free.
- A coupon applies when the subtotal reaches its minimum ($0, $25, or $50)
  and uses remain under `max_uses` (NULL means no limit).
  Percentage coupons take 5% to 20% off, rounded to cents. Fixed coupons take $5 to $25 off.
- `coupons.used_count` = uses in orders that were not cancelled.
- Each user has one default shipping address. One product is one line per order (use quantity).
  Category names are unique under the same parent.

**Data localization**

- Addresses use `state` (two-letter code), `city`, `postal_code` (ZIP), and `street` (for example `1234 Oak St`).
  Labels are `Home` and `Work`. States are weighted by population (CA, TX, FL, NY, PA, IL, OH, GA, NC, WA).
- Display names are realistic first and last names. Emails stay `user_N@example.com`.
- Products have `name_en` (required), `name_es` (Spanish, about 20% NULL), and `name_fr` (French, mostly NULL).
  Prices range from $2.99 to $499.99 and end in .99.
- Payment methods: `credit_card`, `paypal`, `bank_transfer`. Carriers: `ups`, `usps`, `fedex`.

## Runtime: Docker Desktop (standard) or OrbStack (Chapter 2)

The standard runtime is **Docker Desktop**, because it also runs on Windows.
On macOS, you can use the lighter OrbStack instead.
The steps are the same as long as `docker compose` works.

| | Docker Desktop (standard) | OrbStack (macOS only, alternative) |
| --- | --- | --- |
| Install | Docker.app from [docker.com](https://www.docker.com/products/docker-desktop/) / Docker Desktop for Windows (requires WSL 2) | `brew install --cask orbstack` (or the official app) |
| Start | Start Docker.app | Start OrbStack.app (light; can stay running) |
| Check the active runtime | `docker context ls` | `docker context use orbstack` / `desktop-linux` |
| Start the book's database | `docker compose up -d` | Same (`docker compose` compatible) |
| Logs | `docker compose logs postgres` | Same |
| Stop and remove | `docker compose down` | Same |

Basic commands (same for both):

```bash
docker context ls            # show the active runtime (marked with *)
docker context use orbstack  # when you use OrbStack
docker images postgres       # check the image (pulled automatically if missing)
docker compose up -d         # start
docker compose ps            # status
docker compose logs postgres # logs (the slow log "duration:" lines are here)
docker compose down          # stop (removes the container; data stays in ./pgdata)
```

`io_method` (asynchronous I/O in PostgreSQL 18) is set to `worker`.
`io_uring` is a Linux kernel feature. Docker Desktop and OrbStack on macOS cannot use it.
Only when you test on a Linux server, change `io_method=worker` to `io_uring` in `docker-compose.yml` (Chapter 12, section 06).

## Quick start

```bash
git clone https://github.com/ChisouPublishing/sql-code-eng.git
cd sql-code-eng
make up            # start PostgreSQL 18 (pulls the image the first time)
make init-medium   # load schema through small and medium into sakura_market (about 30 seconds)
make verify        # integrity checks (the final summary must be ALL OK)
```

Benchmark database (takes time and disk space):

```bash
make init-xlarge DB=sakura_xl   # load small -> medium -> large -> xlarge into sakura_xl (about 20-30 minutes and about 20 GB)
make verify DB=sakura_xl        # takes a few minutes
make bench-init DB=sakura_xl    # pgbench built-in tables for Chapter 13 (pgbench_*, scale 10)
```

Start over (removes the data):

```bash
make reset         # = docker compose down + rm -rf pgdata
make init-medium
```

`./pgdata` is a bind mount (a folder on the host), so `docker compose down -v` does not remove it.
Remove it with `rm -rf pgdata` (`make reset`). The init scripts can rebuild everything in it.

Connect:

```bash
docker exec -it sakura_market_db psql -U sakura -d sakura_market
docker exec -it sakura_market_db psql -U sakura -d sakura_xl
```

DBeaver: host `localhost` / port `5432` / database `sakura_market` (or `sakura_xl`) / user `sakura` / password `sakura_dev`.

## pgbench (Chapters 13 and 14)

pgbench runs in a container, so the host does not need a PostgreSQL client:

```bash
make bench-smoke             # sakura_bench.sql with -c 2 -j 1 -t 10 (default database)
make bench-smoke DB=sakura_xl
```

The same run by hand. Custom scripts need `-n` (it skips VACUUM of the pgbench_* tables).
The compose network is named after this folder: `sql-code-eng_default`.

```bash
docker run --rm --network sql-code-eng_default -e PGPASSWORD=sakura_dev \
  -v "$PWD/bench:/bench:ro" postgres:18 \
  pgbench -n -c 10 -j 2 -T 60 -f /bench/sakura_bench.sql \
  -U sakura -d sakura_xl -h sakura_market_db
# Dashboard reads (run ch14 first)
docker run --rm --network sql-code-eng_default -e PGPASSWORD=sakura_dev \
  -v "$PWD/bench:/bench:ro" postgres:18 \
  pgbench -n -c 50 -j 8 -T 300 -f /bench/dashboard_bench.sql \
  -U sakura -d sakura_xl -h sakura_market_db
```

To initialize the built-in scripts (scale 10 = 1,000,000 accounts rows), run `make bench-init DB=sakura_xl`.

## Connection pool PgBouncer (Chapter 13)

If an application opens a new connection for each request, every request pays the connection cost (about 1 ms).
More concurrent connections than `max_connections` (default 100) fail with an error.
A connection pool reuses a small number of server connections.

```bash
make pool-up      # = docker compose --profile pool up -d pgbouncer (port 6432)
# From a pgbench container: -h sakura_pgbouncer -p 5432 / from the host: -h localhost -p 6432
make pool-down
```

- The image is pinned to `edoburu/pgbouncer:v1.26.0-p0` (PgBouncer 1.26.0).
- `pool_mode=transaction` (lends a server connection only for one transaction), `default_pool_size=20`, `max_client_conn=1000`.
- Development settings: plain-text password authentication (`AUTH_TYPE=plain`, written in the compose file).
  In production, use `scram-sha-256` with `auth_query`, and TLS.
- In transaction mode, `SET`, temporary tables, SQL `PREPARE`, and session-level advisory locks
  do not carry over to the next transaction (the next transaction may get a different server connection).
  Keep them inside one transaction, or use `SET LOCAL`.

### Monitoring screens: pgAdmin 4 (Chapters 11, 13, 14)

The "Check on screen" sections use pgAdmin 4, the official PostgreSQL admin tool. It is not started by default (profile `monitor`).

```bash
make monitor-up     # = docker compose --profile monitor up -d pgadmin
# open http://localhost:5050 in a browser (no login screen)
make monitor-down
```

- The image is pinned to `dpage/pgadmin4:9.18`. The port is bound to `127.0.0.1` only.
- Desktop mode: no login screen and no master password. Use it only on your own machine.
- `pgadmin/servers.json` registers two servers under the group "Sakura Market":
  `sakura_market (small + medium)` and `sakura_xl (benchmark)`. Both point at the compose service `postgres`.
  The password comes from `pgadmin/pgpass` (development password `sakura_dev`).

## pgvector (Chapter 15 only)

```bash
docker compose -f docker-compose.yml -f docker-compose.pgvector.yml up -d
docker exec -i sakura_market_db psql -U sakura -d sakura_market < queries/ch15_pgvector.sql
```

## Troubleshooting (Chapter 2, section 2.8)

| Symptom | Fix |
| --- | --- |
| `port is already allocated` | Stop the other PostgreSQL, or change `"5432:5432"` to `"5433:5432"` in the compose file |
| Startup fails with `io_uring` | Change `io_method` back to `worker` in `command` and restart (macOS or an old kernel) |
| `connection refused` | Check `docker compose logs postgres`. On first start, wait until initialization finishes |
| `relation "users" already exists` | You ran init again on a loaded database. Run `make reset`, then load again (for `sakura_xl` only: `DROP DATABASE sakura_xl`) |
| xlarge is slow or the disk is full | Check free space with `df -h`. Stop at medium, or stop `08_xlarge_data.sql` and run it again later (it creates only the missing rows) |

## Tested

- All init files (01-06), `checks/verify_all.sql`, every `queries/*.sql`, and `bench/*.sql`
  ran on postgres:18 in a temporary container. All checks are OK.
- The xlarge data set (`sakura_xl`) was not built for this edition. The generator code is the same as the Japanese edition,
  which was tested at 10,000,000 orders.


## CSV, external-LLM material and application binding exercises

- `examples/csv/input.csv` and `queries/ch05_csv_roundtrip.sql`: text staging, ISO dates, UTF-8, NULL versus empty text, leading zeros, export/reload comparison.
- `queries/ch07_llm_material.sql`: local status aggregates; it sends nothing to an external service.
- `examples/ch08_parameter_binding.py`: Psycopg value parameters and allowlisted identifiers, using a temporary table. Set `SAKURA_DSN` to the learning DB; keep credentials out of source and prompts.
- Chapter 8 §04: pg_dump custom-format snapshot and restore into a new database name before committed experiments.

The standalone English package uses `sakura_market` by default. Set `SAKURA_DSN` to the intended learning database when running the Python exercise. Do not reinitialize existing learning data. Business dates use `America/New_York`.

## Chapter 1 SQL comparison

- `prompts/templates.md`: prompt templates, including the one-column request.
- `queries/ch01_verified_ai_dialogue.sql`: SQL statements and the author reference used in Chapter 1. The script runs read-only and ends with ROLLBACK.
