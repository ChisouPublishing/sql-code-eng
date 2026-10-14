# Prompt templates (Chapter 7, Appendix D)

`codes/sql-code-eng/prompts/templates.md@v1.2.2`. Reusable templates for asking an AI to design SQL.
Always check the AI output with the steps in `queries/ch08_verify.sql`.

## Basic template

```
You are a database design expert.
Design SQL for PostgreSQL 18 from the requirements below.

[Schema]
(Paste the DDL from init/02_tables.sql)
(Approved synthetic examples with explicit columns, if needed; no production personal data or credentials.)

[Business definitions]
- Sales = SUM(order_items.quantity * order_items.price) in USD (before coupon discounts, without shipping)
- What the customer pays is orders.amount (= subtotal - discount_amount + shipping_fee). Do not mix it up with sales
- Money columns are numeric(12,2) (US dollars with cents)
- Exclude: orders.status NOT IN ('cancelled', 'returned')
- Period: based on ordered_at, dates in Eastern Time (America/New_York), half-open interval with >= / <
- Grain: (for example, daily by category)

[Constraints]
- Under 1 second, last 30 days
- Output columns: (for example, category_name, total_sales, growth_pct)
- CTEs, window functions, and FILTER are allowed; SELECT * is not allowed

[Output]
1. SQL
2. Expected plan (where is the bottleneck?)
3. Self-critique (3 weaknesses of your own SQL)
4. Alternative (readability, performance, maintainability)
```

## Step-by-step prompting (Step 1 -> Step 3)

1. Step 1: ask only for the tables and columns to use (no joins or grain yet).
2. Step 2: ask only for the join conditions and the aggregation grain.
3. Step 3: ask for the full SQL. A person checks that it agrees with Steps 1 and 2.

## Verification (ask for counterexamples)

```
List 3 cases (counterexamples) where the SQL above gives a wrong answer.
Consider: NULL, zero rows, edge values (the ends of the period), duplicates (fan-out),
missing status filters, and time zones.
Also write a query that detects each counterexample.
```

## Boundary rules (separate the database from business logic; apply to every template)

- The database only aggregates. Discount calculation, rank decisions, and status changes belong in the application layer.
- Do not propose new stored procedures (except the data generators in init/04b_generators.sql).
- Read status times (when an order was paid or cancelled) from order_status_histories. Do not add time columns to orders.


## Verified customer-name request (English, trial 08)

Executed October 13, 2026 with `claude-opus-5-5`, Claude Code 2.1.296, no tools/MCP and no previous conversation. The English learning DB result matched the reference: five rows, one customer_name column. This records that trial; it does not guarantee that future outputs will be identical.

### System prompt

```text
You are an assistant helping write PostgreSQL SQL. Answer the user in English. External tools are unavailable.
```

### User prompt (exact input)

```text
The actual table structure is below. The connection search_path is sakura, public.
CREATE TABLE users (
 id uuid PRIMARY KEY,
 email varchar(255) NOT NULL UNIQUE,
 display_name varchar(100) NOT NULL,
 rank varchar(20) NOT NULL CHECK (rank IN ('bronze','silver','gold','platinum')),
 created_at timestamptz NOT NULL,
 updated_at timestamptz NOT NULL,
 deleted_at timestamptz
);

Add these business definitions and requirements:
- "Customer name" means users.display_name. email is the login email address and must not be displayed as the customer name.
- Gold tier means rank = 'gold'.
- Exclude customers who have closed their accounts: return only deleted_at IS NULL.
- Return 5 customers in ascending id order, with display_name named customer_name.
Output exactly one column named customer_name. Do not return id, email, or any other column; id is only the sort key.
Write PostgreSQL SQL that meets these requirements. Return only one SQL statement.
```

Raw response and DB comparison: `evidence/20261012_ai_response_verification/08-exact-output.response.json` and `db-results.json`. Chapter 1 records all preceding trials, including the repeat that corrected the email column and the request that returned an extra id column. Do not remove those qualifications when describing the result.
