# Makefile -- codes/sql-code-eng v1.2.2
# Choose the database with DB=...: the default is sakura_market (small + medium; Chapters 4-9 and 15).
#   Benchmark database (Chapters 10-14): make init-xlarge DB=sakura_xl
DB ?= sakura_market
CONTAINER := sakura_market_db
PSQL = docker exec -i $(CONTAINER) psql -U sakura -d $(DB) -v ON_ERROR_STOP=1 -q
# Feed SQL files from the host through standard input (./init is not mounted into the container)
RUNSQL = $(PSQL) <
# Run pgbench in a container (no PostgreSQL client is needed on the host).
# The compose network is named after this folder: sql-code-eng_default.
PGBENCH = docker run --rm --network sql-code-eng_default -e PGPASSWORD=sakura_dev \
	-v "$(PWD)/bench:/bench:ro" postgres:18 pgbench -U sakura -h $(CONTAINER)

.PHONY: up down reset logs ps db init-small init-medium init-large init-xlarge verify \
	bench-smoke bench-init pool-up pool-down monitor-up monitor-down

up:
	docker compose up -d
	for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
	  docker exec $(CONTAINER) pg_isready -U sakura -d sakura_market > /dev/null 2>&1 && break; \
	  sleep 5; \
	done
	docker exec $(CONTAINER) pg_isready -U sakura -d sakura_market

# Stop and remove the containers. The data (./pgdata is a bind mount) stays.
down:
	docker compose --profile pool --profile monitor down

# Remove the data too (deletes ./pgdata. The next make up initializes from scratch.)
reset: down
	rm -rf pgdata

logs:
	docker compose logs postgres | tail -n 100

ps:
	docker compose ps

# Create the database if it does not exist
# (compose creates sakura_market on first start; sakura_xl is created here)
db: up
	docker exec -i $(CONTAINER) psql -U sakura -d sakura_market -tAc \
	  "SELECT 1 FROM pg_database WHERE datname = '$(DB)'" | grep -q 1 || \
	  docker exec -i $(CONTAINER) psql -U sakura -d sakura_market -c 'CREATE DATABASE "$(DB)"'

init-small: db
	$(RUNSQL) init/01_schema.sql
	$(RUNSQL) init/02_tables.sql
	$(RUNSQL) init/03_indexes.sql
	$(RUNSQL) init/04_master_data.sql
	$(RUNSQL) init/04b_generators.sql
	$(RUNSQL) init/05_small_data.sql

init-medium: init-small
	$(RUNSQL) init/06_medium_data.sql

init-large: init-medium
	$(RUNSQL) init/07_large_data.sql

init-xlarge: init-large
	$(RUNSQL) init/08_xlarge_data.sql

verify:
	$(RUNSQL) checks/verify_all.sql

# Custom scripts need -n (skip VACUUM of the pgbench_* tables; works without those tables)
bench-smoke:
	$(PGBENCH) -n -c 2 -j 1 -t 10 -f /bench/sakura_bench.sql -d $(DB)

# Chapter 13: tables for the built-in scripts (pgbench_*; scale 10 = 1 million accounts).
# Create them in the benchmark database.
bench-init:
	$(PGBENCH) -i -s 10 -d $(DB)

# Connection pool (PgBouncer, port 6432). Chapter 13
pool-up:
	docker compose --profile pool up -d pgbouncer

pool-down:
	docker compose --profile pool stop pgbouncer

# Monitoring screens pgAdmin 4 (http://localhost:5050, port 5050). Chapters 11, 13, 14 "Check on screen"
monitor-up:
	docker compose --profile monitor up -d pgadmin

monitor-down:
	docker compose --profile monitor stop pgadmin
