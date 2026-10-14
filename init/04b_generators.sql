-- 04b_generators.sql -- Shared data generation procedures (Chapter 5, Appendix C)
-- codes/sql-code-eng/init/04b_generators.sql@v1.2.2
-- 05 (small), 06 (medium), 07 (large), and 08 (xlarge) call these procedures.
-- All sizes then follow the same business rules.
-- Separate code per size lets the rules drift apart (a lesson from v1.1.1 and earlier).
-- This file keeps the rules in one place.
--
-- Business rules (what the generated data promises)
--   * Users: the rank depends on the user number
--       (platinum 1% / gold 5% / silver 20% / bronze 74%).
--     Display names are realistic first and last names.
--     Every user has one "Home" address (the default). About 20% also have a "Work" address.
--     States are weighted by population (CA, TX, FL, NY, PA, IL, OH, GA, NC, WA).
--     City and ZIP prefix match the state.
--   * Products: prices range from about $2.99 to $499.99 and end in .99.
--     Cheap products are more common. About 3% have no stock.
--     The English name is always set. About 20% have no Spanish name (NULL).
--     About 95% have no French name (NULL).
--     The inventory log gets one first "restock" row.
--   * Orders: a user orders only after signing up.
--     Order times peak at lunch and in the evening (Eastern Time).
--     Each order has 1 to p_max_items lines (one line per product).
--     Some products sell more than others (lower product numbers sell better).
--     The status follows the flow of time:
--       placed -> paid (card and PayPal: minutes; bank transfer: 1 to 72 hours)
--       -> shipped (6 to 48 hours after payment) -> delivered (18 to 72 hours after shipping).
--     About 2% are cancelled 1 to 72 hours after the order.
--     A cancellation before payment is an expired bank transfer.
--     About 2.5% are returned 2 to 10 days after delivery.
--     Events later than "now" have not happened yet.
--     Recent orders therefore stay ordered (not paid), paid, or shipped.
--   * Amounts: subtotal = sum of quantity x unit price.
--     About 12% of orders try a coupon. The coupon applies if the subtotal reaches
--     the minimum and the coupon has uses left.
--     Percentage discounts are rounded to cents.
--     Shipping = $5.99 if the subtotal is under $50.00; otherwise free.
--     Amount charged = subtotal - discount + shipping.
--   * Status history: one row per event that happened (order_status_histories).
--   * Payments: one per order, except orders with status ordered.
--     Payment amount = amount charged.
--     A cancelled order has a failed payment if not paid yet, or a refunded payment if paid.
--   * Shipments: one per order with status shipped, delivered, or returned.
--     The shipping address is a copy of the default address.
--   * Returns: one per returned order. Refund = amount charged.
--     Returns for customer reasons do not refund shipping.
--   * Reviews: some delivered orders (p_review_rate) get one review of one product.
--   * Behavior log: rows are appended in time order.
--     The physical order then matches created_at, so BRIN works well.
--   * Random numbers: only random() is used.
--     Call SELECT setseed(...) first, and users, addresses, and products get the same content
--     (except ids and times).
--     Orders get their time-of-day peaks from the Eastern Time date.
--     The status mix and counts therefore change a little with the load time.
--   * Values are assigned by array index, or by joining a numbered (idx) temporary table.
--     (Lesson from v1.1.0: an uncorrelated subquery runs only once,
--     so every row gets the same value.)
-- Note: the procedures COMMIT inside. CALL them outside a transaction
-- (psql autocommit, the default, is fine).

SET search_path TO sakura, public;

-- ---------------------------------------------------------------
-- gen_users: create users and addresses
--   p_email_prefix: email prefix (for example 'user_medium_' -> user_medium_1@example.com)
--   p_count: number of users
--   p_days: spread the signup dates over this many days before now
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sakura.gen_users(
    p_email_prefix text, p_count int, p_days int)
LANGUAGE plpgsql AS
$proc$
DECLARE
    v_first text[] := ARRAY[
        'James', 'Mary', 'Robert', 'Patricia', 'John', 'Jennifer', 'Michael', 'Linda',
        'David', 'Elizabeth', 'William', 'Barbara', 'Richard', 'Susan', 'Joseph', 'Jessica',
        'Thomas', 'Sarah', 'Christopher', 'Karen', 'Daniel', 'Lisa', 'Matthew', 'Nancy',
        'Anthony', 'Emily', 'Mark', 'Ashley', 'Steven', 'Michelle', 'Andrew', 'Amanda',
        'Joshua', 'Melissa', 'Kevin', 'Laura', 'Brian', 'Olivia', 'Ethan', 'Sophia'];
    v_last text[] := ARRAY[
        'Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis',
        'Rodriguez', 'Martinez', 'Hernandez', 'Lopez', 'Gonzalez', 'Wilson', 'Anderson', 'Thomas',
        'Taylor', 'Moore', 'Jackson', 'Martin', 'Lee', 'Perez', 'Thompson', 'White',
        'Harris', 'Sanchez', 'Clark', 'Ramirez', 'Lewis', 'Robinson', 'Walker', 'Young',
        'Allen', 'King', 'Wright', 'Scott', 'Nguyen', 'Hill', 'Green', 'Baker'];
    v_streets text[] := ARRAY[
        'Oak', 'Maple', 'Pine', 'Cedar', 'Elm', 'Washington', 'Lake', 'Hill',
        'Park', 'Main', 'Sunset', 'Lincoln', 'Jefferson', 'Highland', 'River', 'Church'];
    v_suffixes text[] := ARRAY['St', 'Ave', 'Rd', 'Blvd', 'Dr', 'Ln'];
BEGIN
    IF p_count <= 0 THEN
        RETURN;
    END IF;
    -- More populous states get more users (20 slots with weights)
    WITH st(k, state, city, zip3) AS (
        VALUES (1, 'CA', 'Los Angeles', '900'), (2, 'TX', 'Houston', '770'),
               (3, 'FL', 'Miami', '331'), (4, 'NY', 'New York', '100'),
               (5, 'PA', 'Philadelphia', '191'), (6, 'IL', 'Chicago', '606'),
               (7, 'OH', 'Columbus', '432'), (8, 'GA', 'Atlanta', '303'),
               (9, 'NC', 'Charlotte', '282'), (10, 'WA', 'Seattle', '981')
    ),
    ins AS (
        INSERT INTO users (email, display_name, rank, created_at, updated_at)
        SELECT p_email_prefix || g || '@example.com',
               v_first[1 + floor(random() * array_length(v_first, 1))::int] || ' '
                   || v_last[1 + floor(random() * array_length(v_last, 1))::int],
               CASE
                   WHEN g % 100 = 0 THEN 'platinum'
                   WHEN g % 100 < 6 THEN 'gold'
                   WHEN g % 100 < 26 THEN 'silver'
                   ELSE 'bronze'
               END,
               t, t
        FROM (SELECT g,
                     now() - interval '1 day' * (g % p_days)
                           - interval '1 second' * floor(random() * 86400) AS t
              FROM generate_series(1, p_count) AS g) AS s
        RETURNING id, created_at
    ),
    home AS (
        INSERT INTO addresses (user_id, label, postal_code, state, city, street,
                               is_default, created_at, updated_at)
        SELECT a.id, 'Home', p.zip3 || lpad(a.n2::text, 2, '0'),
               p.state, p.city, a.street, true, a.created_at, a.created_at
        FROM (SELECT id, created_at,
                     (ARRAY[1,1,1,1,2,2,2,3,3,3,4,4,5,5,6,6,7,8,9,10])[1 + floor(random() * 20)::int] AS k,
                     floor(random() * 100)::int AS n2,
                     (100 + floor(random() * 9900)::int) || ' '
                         || v_streets[1 + floor(random() * array_length(v_streets, 1))::int] || ' '
                         || v_suffixes[1 + floor(random() * array_length(v_suffixes, 1))::int] AS street
              FROM ins) AS a
        JOIN st p ON p.k = a.k
        RETURNING user_id
    )
    -- About 20% of users also have a work address (not the default)
    INSERT INTO addresses (user_id, label, postal_code, state, city, street,
                           is_default, created_at, updated_at)
    SELECT a.id, 'Work', p.zip3 || lpad(a.n2::text, 2, '0'),
           p.state, p.city, a.street, false, a.created_at, a.created_at
    FROM (SELECT id, created_at, r,
                 (ARRAY[1,1,1,1,2,2,2,3,3,3,4,4,5,5,6,6,7,8,9,10])[1 + floor(random() * 20)::int] AS k,
                 floor(random() * 100)::int AS n2,
                 (100 + floor(random() * 9900)::int) || ' '
                     || v_streets[1 + floor(random() * array_length(v_streets, 1))::int] || ' '
                     || v_suffixes[1 + floor(random() * array_length(v_suffixes, 1))::int] AS street
          FROM (SELECT id, created_at, random() AS r FROM ins) AS x) AS a
    JOIN st p ON p.k = a.k
    WHERE a.r < 0.2;
END;
$proc$;

-- ---------------------------------------------------------------
-- gen_products: create products and inventory
--   SKU = p_sku_prefix || zero-padded number (for example 'SKU-M-' and 5 digits -> SKU-M-00001)
--   Name = a product type that matches the category || ' ' || p_model_prefix || number
--     (for example 'Wireless Earbuds M1234')
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sakura.gen_products(
    p_sku_prefix text, p_model_prefix text, p_pad int, p_count int)
LANGUAGE plpgsql AS
$proc$
DECLARE
    v_cats uuid[];
    v_name_en text[];
    v_name_es text[];
    v_name_fr text[];
    v_sellers uuid[];
    v_n_cats int;
    v_n_sellers int;
BEGIN
    IF p_count <= 0 THEN
        RETURN;
    END IF;
    -- Arrays are sorted by key. A different order would give different
    -- assignments for the same random numbers.
    -- The product type names follow the same order as the categories.
    SELECT array_agg(id ORDER BY name),
           array_agg(CASE name
                         WHEN 'books' THEN 'Hardcover Book'
                         WHEN 'electronics' THEN 'Wireless Earbuds'
                         WHEN 'fashion' THEN 'Denim Jacket'
                         WHEN 'foods' THEN 'Organic Coffee Beans'
                         WHEN 'home' THEN 'Throw Blanket'
                         WHEN 'kitchen' THEN 'Chef Knife'
                         WHEN 'laptop' THEN 'Laptop 14-inch'
                         WHEN 'mens' THEN 'Men''s Oxford Shirt'
                         WHEN 'novel' THEN 'Paperback Novel'
                         WHEN 'smartphone' THEN 'Smartphone Case'
                         ELSE 'Product' END ORDER BY name),
           array_agg(CASE name
                         WHEN 'books' THEN 'Libro de tapa dura'
                         WHEN 'electronics' THEN 'Auriculares inalámbricos'
                         WHEN 'fashion' THEN 'Chaqueta vaquera'
                         WHEN 'foods' THEN 'Café orgánico en grano'
                         WHEN 'home' THEN 'Manta decorativa'
                         WHEN 'kitchen' THEN 'Cuchillo de chef'
                         WHEN 'laptop' THEN 'Portátil de 14 pulgadas'
                         WHEN 'mens' THEN 'Camisa Oxford de hombre'
                         WHEN 'novel' THEN 'Novela de bolsillo'
                         WHEN 'smartphone' THEN 'Funda para smartphone'
                         ELSE 'Producto' END ORDER BY name),
           array_agg(CASE name
                         WHEN 'books' THEN 'Livre relié'
                         WHEN 'electronics' THEN 'Écouteurs sans fil'
                         WHEN 'fashion' THEN 'Veste en jean'
                         WHEN 'foods' THEN 'Café bio en grains'
                         WHEN 'home' THEN 'Plaid'
                         WHEN 'kitchen' THEN 'Couteau de chef'
                         WHEN 'laptop' THEN 'Ordinateur portable 14 pouces'
                         WHEN 'mens' THEN 'Chemise Oxford homme'
                         WHEN 'novel' THEN 'Roman de poche'
                         WHEN 'smartphone' THEN 'Coque de smartphone'
                         ELSE 'Produit' END ORDER BY name)
      INTO v_cats, v_name_en, v_name_es, v_name_fr
    FROM categories;
    SELECT array_agg(id ORDER BY email) INTO v_sellers FROM sellers;
    v_n_cats := array_length(v_cats, 1);
    v_n_sellers := array_length(v_sellers, 1);

    WITH ins AS (
        INSERT INTO products (sku, name_en, name_es, name_fr, price, category_id, seller_id,
                              created_at, updated_at)
        SELECT p_sku_prefix || lpad(g::text, p_pad, '0'),
               v_name_en[ci] || ' ' || p_model_prefix || g,
               -- About 20% have no Spanish name yet (translation is behind)
               CASE WHEN r_es < 0.2 THEN NULL
                    ELSE v_name_es[ci] || ' ' || p_model_prefix || g END,
               -- Only about 5% have a French name
               CASE WHEN r_fr < 0.95 THEN NULL
                    ELSE v_name_fr[ci] || ' ' || p_model_prefix || g END,
               price,
               v_cats[ci],
               v_sellers[1 + floor(r_seller * v_n_sellers)::int],
               now() - interval '1100 days', now() - interval '1100 days'
        FROM (
            SELECT g,
                   1 + floor(random() * v_n_cats)::int AS ci,
                   random() AS r_es, random() AS r_fr,
                   -- Log-uniform from $3 to $500 (cheap products are more common),
                   -- rounded to whole dollars, minus one cent: $2.99 to $499.99
                   GREATEST(2.99, round(exp(ln(3.0) + random() * ln(500.0 / 3.0))) - 0.01)::numeric(12, 2) AS price,
                   random() AS r_seller
            FROM generate_series(1, p_count) AS g
        ) AS s
        RETURNING id, created_at
    ),
    stk AS (
        SELECT id, created_at,
               CASE WHEN random() < 0.03 THEN 0 ELSE 1 + floor(random() * 200)::int END AS stock
        FROM ins
    ),
    inv AS (
        INSERT INTO inventory (product_id, stock)
        SELECT id, stock FROM stk
        RETURNING product_id
    )
    -- Inventory log: one first "restock" row. Stock = sum of change in the log.
    INSERT INTO inventory_logs (product_id, change, reason, created_at)
    SELECT id, stock, 'restock', created_at FROM stk WHERE stock > 0;
END;
$proc$;

-- ---------------------------------------------------------------
-- gen_user_pool: create the temporary table tmp_gen_users with users numbered by signup time.
--   Returns a cumulative array of "users who signed up before a given day".
--   Orders and log rows go only to users who already signed up.
--   Return value: cum[i] = number of users who signed up before v_base + (i-1) days (i = 1..p_days+1)
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION sakura.gen_user_pool(p_base timestamptz, p_days int)
RETURNS int[]
LANGUAGE plpgsql AS
$fn$
DECLARE
    v_cum int[];
BEGIN
    IF to_regclass('pg_temp.tmp_gen_users') IS NOT NULL THEN
        DROP TABLE tmp_gen_users;
    END IF;
    CREATE TEMP TABLE tmp_gen_users AS
    SELECT row_number() OVER (ORDER BY u.created_at, u.email)::int AS idx,
           u.id AS user_id, u.created_at,
           a.id AS address_id, a.postal_code, a.state, a.city, a.street
    FROM users u
    LEFT JOIN addresses a ON a.user_id = u.id AND a.is_default
    WHERE u.deleted_at IS NULL;
    ALTER TABLE tmp_gen_users ADD PRIMARY KEY (idx);
    ANALYZE tmp_gen_users;

    WITH b AS (
        SELECT GREATEST(floor(extract(epoch FROM created_at - p_base) / 86400)::int + 2, 1) AS j,
               count(*) AS c
        FROM tmp_gen_users GROUP BY 1
    )
    SELECT array_agg(cs ORDER BY i) INTO v_cum
    FROM (SELECT d.i, (sum(COALESCE(b.c, 0)) OVER (ORDER BY d.i))::int AS cs
          FROM generate_series(1, p_days + 1) AS d(i)
          LEFT JOIN b ON b.j = d.i) AS x;
    RETURN v_cum;
END;
$fn$;

-- ---------------------------------------------------------------
-- gen_orders: create orders, order items, status history, payments, shipments,
--   returns, and reviews. Then set the coupon use counts.
--   p_count: number of orders / p_days: spread orders from this many days ago until now
--   p_max_items: maximum lines per order
--   p_batch_size: orders created per batch (each batch is committed)
--   Orders are created in time order (batch b covers the b-th slice of the period).
--   As in a real shop, older orders come first in the table.
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sakura.gen_orders(
    p_count int, p_days int, p_max_items int,
    p_batch_size int DEFAULT 100000,
    p_review_rate float8 DEFAULT 0.1,
    p_coupon_rate float8 DEFAULT 0.12)
LANGUAGE plpgsql AS
$proc$
DECLARE
    v_base timestamptz := now() - interval '1 day' * p_days;
    v_span interval := interval '1 day' * p_days;
    v_cum int[];
    v_np int;
    v_cp_id uuid[];
    v_cp_pct boolean[];
    v_cp_value numeric[];
    v_cp_min numeric[];
    v_cp_rem int[];
    v_nc int;
    v_nb int;
    v_n int;
    v_slice_start timestamptz;
    v_slice interval;
    v_t0 timestamptz;
    v_hours int[];
    v_nh int;
    r record;
    b int;
BEGIN
    IF p_count <= 0 THEN
        RETURN;
    END IF;
    v_cum := sakura.gen_user_pool(v_base, p_days);

    IF to_regclass('pg_temp.tmp_gen_products') IS NOT NULL THEN
        DROP TABLE tmp_gen_products;
    END IF;
    CREATE TEMP TABLE tmp_gen_products AS
    SELECT row_number() OVER (ORDER BY sku)::int AS idx, id AS product_id, price
    FROM products WHERE deleted_at IS NULL;
    ALTER TABLE tmp_gen_products ADD PRIMARY KEY (idx);
    ANALYZE tmp_gen_products;
    SELECT count(*) INTO v_np FROM tmp_gen_products;

    -- Coupons (about 10, so keep them in arrays).
    -- Uses left = limit - uses so far. Cancelled orders count here too,
    -- so the limit is never exceeded.
    SELECT array_agg(c.id ORDER BY c.code),
           array_agg(c.discount_type = 'percentage' ORDER BY c.code),
           array_agg(c.discount_value ORDER BY c.code),
           array_agg(c.min_purchase ORDER BY c.code),
           array_agg(c.max_uses - (SELECT count(*) FROM orders o WHERE o.coupon_id = c.id)::int
                     ORDER BY c.code)
      INTO v_cp_id, v_cp_pct, v_cp_value, v_cp_min, v_cp_rem
    FROM coupons c;
    v_nc := COALESCE(array_length(v_cp_id, 1), 0);

    v_nb := ceil(p_count::numeric / p_batch_size)::int;
    v_slice := v_span / v_nb;

    -- Hour-of-day weights (0 to 23, Eastern Time).
    -- Each hour appears in the array as many times as its weight. Pick one at random.
    SELECT array_agg(h ORDER BY h, k), count(*) INTO v_hours, v_nh
    FROM unnest(ARRAY[2,1,1,1,1,1,2,3,4,4,5,6,8,6,5,5,5,5,6,7,9,10,9,5]) WITH ORDINALITY AS w(wt, h1)
    CROSS JOIN LATERAL generate_series(1, w.wt) AS k
    CROSS JOIN LATERAL (SELECT (w.h1 - 1)::int AS h) AS hh;

    FOR b IN 1..v_nb LOOP
        v_t0 := clock_timestamp();
        v_n := LEAST(p_batch_size, p_count - (b - 1) * p_batch_size);
        v_slice_start := v_base + v_slice * (b - 1);

        -- (1) Order skeleton: time, user, and planned event times.
        --     Random numbers are in the SELECT list, so each row gets its own values.
        CREATE TEMP TABLE tmp_o ON COMMIT DROP AS
        SELECT g, t AS ordered_at,
               1 + floor(r_user * GREATEST(v_cum[LEAST(GREATEST(
                   floor(extract(epoch FROM t - v_base) / 86400)::int + 1, 1), p_days + 1)], 1))::int AS user_idx,
               1 + floor(r_lines * p_max_items)::int AS n_lines,
               fate, method, t_paid, t_cancel, t_ship, t_deliv,
               CASE WHEN fate = 'return' THEN t_deliv + interval '1 day' * (2 + r_ret * 8) END AS t_ret,
               CASE WHEN v_nc > 0 AND r_coupon < p_coupon_rate
                    THEN 1 + floor(r_cidx * v_nc)::int END AS coupon_idx,
               r_review, r_carrier
        FROM (
            SELECT g, t, r_user, r_lines, fate, method, r_ret, r_coupon, r_cidx, r_review, r_carrier,
                   t_paid,
                   CASE WHEN fate = 'cancel' THEN t + interval '1 hour' * (1 + r_cancel * 71) END AS t_cancel,
                   t_paid + interval '1 hour' * (6 + r_ship * 42) AS t_ship,
                   t_paid + interval '1 hour' * (6 + r_ship * 42)
                          + interval '1 hour' * (18 + r_deliv * 54) AS t_deliv
            FROM (
                SELECT g, t, r_user, r_lines, r_ret, r_coupon, r_cidx, r_review, r_carrier,
                       r_cancel, r_ship, r_deliv,
                       CASE WHEN r_fate < 0.02 THEN 'cancel'
                            WHEN r_fate < 0.045 THEN 'return' ELSE 'normal' END AS fate,
                       method,
                       t + CASE WHEN method = 'bank_transfer'
                                THEN interval '1 hour' * (1 + r_pay * 71)
                                ELSE interval '1 minute' * (1 + r_pay * 29) END AS t_paid
                FROM (
                    SELECT g,
                           -- Time: the date is uniform within the slice. The hour peaks at
                           -- lunch (12:00) and in the evening (20:00 to 22:00), Eastern Time.
                           -- If the result falls outside the slice or after now,
                           -- use the uniform time instead.
                           CASE WHEN th BETWEEN v_base AND now() THEN th ELSE t0 END AS t,
                           random() AS r_user, random() AS r_lines, random() AS r_fate,
                           CASE WHEN m < 0.60 THEN 'credit_card'
                                WHEN m < 0.85 THEN 'paypal' ELSE 'bank_transfer' END AS method,
                           random() AS r_pay, random() AS r_cancel, random() AS r_ship,
                           random() AS r_deliv, random() AS r_ret, random() AS r_coupon,
                           random() AS r_cidx, random() AS r_review, random() AS r_carrier
                    FROM (
                        SELECT g, m, t0,
                               (date_trunc('day', t0 AT TIME ZONE 'America/New_York')
                                + interval '1 hour' * v_hours[1 + floor(random() * v_nh)::int]
                                + interval '1 second' * floor(random() * 3600)) AT TIME ZONE 'America/New_York' AS th
                        FROM (SELECT g, random() AS m, v_slice_start + v_slice * random() AS t0
                              FROM generate_series(1, v_n) AS g) AS z
                    ) AS s0
                ) AS s1
            ) AS s2
        ) AS s3;

        -- (2) Order items: n_lines lines per order.
        --     If the same product comes up twice, merge it into one line and add the quantities.
        CREATE TEMP TABLE tmp_i ON COMMIT DROP AS
        SELECT o.g, x.pidx, sum(x.qty)::int AS qty
        FROM tmp_o o
        CROSS JOIN LATERAL (
            SELECT 1 + floor(power(random(), 1.5) * v_np)::int AS pidx,   -- lower numbers sell better
                   1 + floor(power(random(), 3) * 3)::int AS qty           -- about 70% buy 1 unit
            FROM generate_series(1, o.n_lines)
        ) AS x
        GROUP BY o.g, x.pidx;
        ANALYZE tmp_i;

        -- (3) Fix amounts and status. Drop coupons beyond the uses left.
        CREATE TEMP TABLE tmp_f ON COMMIT DROP AS
        WITH s AS (
            SELECT i.g, sum(i.qty * p.price)::numeric(12, 2) AS subtotal
            FROM tmp_i i JOIN tmp_gen_products p ON p.idx = i.pidx
            GROUP BY i.g
        ),
        cand AS (
            SELECT o.g, o.coupon_idx,
                   row_number() OVER (PARTITION BY o.coupon_idx ORDER BY o.g) AS rn
            FROM tmp_o o JOIN s ON s.g = o.g
            WHERE o.coupon_idx IS NOT NULL AND s.subtotal >= v_cp_min[o.coupon_idx]
        ),
        k AS (
            SELECT o.*, s.subtotal,
                   CASE WHEN cand.g IS NOT NULL
                         AND (v_cp_rem[cand.coupon_idx] IS NULL OR cand.rn <= v_cp_rem[cand.coupon_idx])
                        THEN cand.coupon_idx END AS cidx,
                   CASE
                       WHEN o.fate = 'cancel' AND o.t_cancel <= now() THEN 'cancelled'
                       WHEN o.fate = 'return' AND o.t_ret <= now() THEN 'returned'
                       WHEN o.fate <> 'cancel' AND o.t_deliv <= now() THEN 'delivered'
                       WHEN o.fate <> 'cancel' AND o.t_ship <= now() THEN 'shipped'
                       WHEN o.t_paid <= now() AND (o.fate <> 'cancel' OR o.t_paid < o.t_cancel) THEN 'paid'
                       ELSE 'ordered'
                   END AS status
            FROM tmp_o o
            JOIN s ON s.g = o.g
            LEFT JOIN cand ON cand.g = o.g
        )
        SELECT k.*,
               uuidv7(k.ordered_at - now()) AS id,      -- the time part of the id matches the order time (PG18)
               u.user_id, u.address_id, u.postal_code, u.state, u.city, u.street,
               CASE WHEN k.cidx IS NULL THEN 0
                    WHEN v_cp_pct[k.cidx] THEN round(k.subtotal * v_cp_value[k.cidx] / 100, 2)
                    ELSE LEAST(v_cp_value[k.cidx], k.subtotal) END::numeric(12, 2) AS discount_amount,
               CASE WHEN k.subtotal < 50 THEN 5.99 ELSE 0 END::numeric(12, 2) AS shipping_fee
        FROM k JOIN tmp_gen_users u ON u.idx = k.user_idx;
        ANALYZE tmp_f;

        -- Reduce the uses left on each coupon
        FOR r IN SELECT cidx, count(*)::int AS n FROM tmp_f WHERE cidx IS NOT NULL GROUP BY cidx LOOP
            IF v_cp_rem[r.cidx] IS NOT NULL THEN
                v_cp_rem[r.cidx] := v_cp_rem[r.cidx] - r.n;
            END IF;
        END LOOP;

        -- (4) Orders (appended in time order)
        INSERT INTO orders (id, user_id, status, subtotal, discount_amount, shipping_fee, amount,
                            coupon_id, ordered_at, created_at, updated_at)
        SELECT f.id, f.user_id, f.status, f.subtotal, f.discount_amount, f.shipping_fee,
               f.subtotal - f.discount_amount + f.shipping_fee,
               v_cp_id[f.cidx], f.ordered_at, f.ordered_at,
               CASE f.status
                   WHEN 'cancelled' THEN f.t_cancel WHEN 'returned' THEN f.t_ret
                   WHEN 'delivered' THEN f.t_deliv WHEN 'shipped' THEN f.t_ship
                   WHEN 'paid' THEN f.t_paid ELSE f.ordered_at END
        FROM tmp_f f
        ORDER BY f.ordered_at;

        -- (5) Order items (unit price = product price at order time)
        INSERT INTO order_items (order_id, product_id, quantity, price, created_at)
        SELECT f.id, p.product_id, i.qty, p.price, f.ordered_at
        FROM tmp_i i
        JOIN tmp_f f ON f.g = i.g
        JOIN tmp_gen_products p ON p.idx = i.pidx
        ORDER BY f.ordered_at, i.pidx;

        -- (6) Status history (only events that happened)
        INSERT INTO order_status_histories (order_id, from_status, to_status, changed_at, note)
        SELECT id, from_s, to_s, at, note FROM (
            SELECT f.id, NULL::varchar AS from_s, 'ordered'::varchar AS to_s,
                   f.ordered_at AS at, NULL::varchar AS note
            FROM tmp_f f
            UNION ALL
            SELECT f.id, 'ordered', 'paid', f.t_paid, NULL FROM tmp_f f
            WHERE f.status IN ('paid', 'shipped', 'delivered', 'returned')
               OR (f.status = 'cancelled' AND f.t_paid < f.t_cancel)
            UNION ALL
            SELECT f.id, 'paid', 'shipped', f.t_ship, NULL FROM tmp_f f
            WHERE f.status IN ('shipped', 'delivered', 'returned')
            UNION ALL
            SELECT f.id, 'shipped', 'delivered', f.t_deliv, NULL FROM tmp_f f
            WHERE f.status IN ('delivered', 'returned')
            UNION ALL
            SELECT f.id, 'delivered', 'returned', f.t_ret, 'Return requested' FROM tmp_f f
            WHERE f.status = 'returned'
            UNION ALL
            SELECT f.id, CASE WHEN f.t_paid < f.t_cancel THEN 'paid' ELSE 'ordered' END,
                   'cancelled', f.t_cancel,
                   CASE WHEN f.t_paid < f.t_cancel THEN 'Customer request (refunded)'
                        ELSE 'Payment not received (expired)' END
            FROM tmp_f f WHERE f.status = 'cancelled'
        ) AS h
        ORDER BY at;

        -- (7) Payments (all orders except status ordered. Payment amount = amount charged)
        INSERT INTO payments (order_id, method, status, amount, paid_at, created_at)
        SELECT f.id, f.method,
               CASE
                   WHEN f.status = 'cancelled' AND f.t_paid < f.t_cancel THEN 'refunded'
                   WHEN f.status = 'cancelled' THEN 'failed'
                   WHEN f.status = 'returned' THEN 'refunded'
                   ELSE 'completed'
               END,
               f.subtotal - f.discount_amount + f.shipping_fee,
               CASE WHEN f.status = 'cancelled' AND f.t_paid >= f.t_cancel THEN NULL ELSE f.t_paid END,
               f.ordered_at
        FROM tmp_f f
        WHERE f.status <> 'ordered'
        ORDER BY f.ordered_at;

        -- (8) Shipments (the address is a copy of the default address)
        INSERT INTO shipments (order_id, address_id, ship_postal_code, ship_state, ship_city,
                               ship_street, carrier, tracking_number, shipped_at, delivered_at, created_at)
        SELECT f.id, f.address_id, f.postal_code, f.state, f.city, f.street,
               CASE WHEN f.r_carrier < 0.4 THEN 'ups'
                    WHEN f.r_carrier < 0.75 THEN 'usps' ELSE 'fedex' END,
               'TRK' || lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
               f.t_ship,
               CASE WHEN f.status IN ('delivered', 'returned') THEN f.t_deliv END,
               f.t_ship
        FROM tmp_f f
        WHERE f.status IN ('shipped', 'delivered', 'returned')
        ORDER BY f.t_ship;

        -- (9) Returns (returns for customer reasons do not refund shipping)
        INSERT INTO returns (order_id, reason, status, refund_amount, returned_at, created_at)
        SELECT x.id, x.reason, 'refunded',
               x.amount - CASE WHEN x.reason IN ('Wrong size', 'Not what I expected', 'Ordered by mistake')
                               THEN x.shipping_fee ELSE 0 END,
               x.t_ret, x.t_ret
        FROM (
            SELECT f.id, f.t_ret, f.shipping_fee,
                   f.subtotal - f.discount_amount + f.shipping_fee AS amount,
                   (ARRAY['Wrong size', 'Not what I expected', 'Defective item',
                          'Damaged in shipping', 'Ordered by mistake'])
                       [1 + floor(random() * 5)::int] AS reason
            FROM tmp_f f WHERE f.status = 'returned'
        ) AS x
        ORDER BY x.t_ret;

        -- (10) Reviews (some delivered orders. At most one per user and product)
        INSERT INTO reviews (user_id, product_id, rating, comment, created_at)
        SELECT y.user_id, y.product_id, y.rating,
               (ARRAY['Disappointed', 'Not great', 'It is okay', 'Satisfied', 'Excellent'])[y.rating],
               y.at
        FROM (
            SELECT x.user_id, x.product_id,
                   CASE WHEN rr < 0.07 THEN 1 WHEN rr < 0.15 THEN 2 WHEN rr < 0.30 THEN 3
                        WHEN rr < 0.60 THEN 4 ELSE 5 END AS rating,
                   x.t_deliv + interval '1 hour' * (1 + random() * 335) AS at
            FROM (
                SELECT DISTINCT ON (f.g) f.user_id, p.product_id, f.t_deliv, random() AS rr
                FROM tmp_f f
                JOIN tmp_i i ON i.g = f.g
                JOIN tmp_gen_products p ON p.idx = i.pidx
                WHERE f.status = 'delivered' AND f.r_review < p_review_rate
                ORDER BY f.g, i.pidx
            ) AS x
        ) AS y
        WHERE y.at <= now()
        ON CONFLICT (user_id, product_id) DO NOTHING;

        COMMIT;
        IF v_nb > 1 THEN
            RAISE NOTICE 'gen_orders batch % / % (% orders) % s', b, v_nb, v_n,
                round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1);
        END IF;
    END LOOP;

    -- Coupon use count = uses in orders that were not cancelled
    UPDATE coupons c SET used_count = (
        SELECT count(*) FROM orders o WHERE o.coupon_id = c.id AND o.status <> 'cancelled');
    COMMIT;

    DROP TABLE tmp_gen_users;
    DROP TABLE tmp_gen_products;
END;
$proc$;

-- ---------------------------------------------------------------
-- gen_behavior_logs: append behavior log rows in time order
--   Spreads p_count rows evenly from p_days days ago until now.
--   Commits every p_batch_size rows.
--   About 15% are guests (user_id NULL). Searches have product_id NULL and a keyword.
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sakura.gen_behavior_logs(
    p_count bigint, p_days int, p_batch_size int DEFAULT 1000000)
LANGUAGE plpgsql AS
$proc$
DECLARE
    v_base timestamptz := now() - interval '1 day' * p_days;
    v_span interval := interval '1 day' * p_days;
    v_cum int[];
    v_users uuid[];
    v_products uuid[];
    v_np int;
    v_nb int;
    v_n int;
    v_off bigint;
    b int;
BEGIN
    IF p_count <= 0 THEN
        RETURN;
    END IF;
    v_cum := sakura.gen_user_pool(v_base, p_days);
    SELECT array_agg(user_id ORDER BY idx) INTO v_users FROM tmp_gen_users;
    SELECT array_agg(id ORDER BY sku) INTO v_products FROM products WHERE deleted_at IS NULL;
    v_np := array_length(v_products, 1);
    v_nb := ceil(p_count::numeric / p_batch_size)::int;

    FOR b IN 1..v_nb LOOP
        v_off := (b - 1)::bigint * p_batch_size;
        v_n := LEAST(p_batch_size::bigint, p_count - v_off)::int;

        INSERT INTO behavior_logs (user_id, product_id, action, search_keyword, created_at)
        SELECT CASE WHEN r_anon < 0.15 THEN NULL
                    ELSE v_users[1 + floor(r_user * GREATEST(v_cum[LEAST(GREATEST(
                        floor(extract(epoch FROM t - v_base) / 86400)::int + 1, 1), p_days + 1)], 1))::int]
               END,
               CASE WHEN action = 'search' THEN NULL
                    ELSE v_products[1 + floor(power(r_prod, 1.5) * v_np)::int] END,
               action,
               CASE WHEN action = 'search'
                    THEN (ARRAY['smartphone', 'laptop', 'novel', 'kitchen', 'sale', 'mens', 'grocery', 'earbuds'])
                         [1 + floor(r_kw * 8)::int] END,
               t
        FROM (
            -- Compute a 0-to-1 fraction first, then multiply the period.
            -- Multiplying an interval by a large number overflows.
            SELECT v_base + v_span * (((v_off + g - 1) + random()) / p_count) AS t,
                   random() AS r_anon, random() AS r_user, random() AS r_prod, random() AS r_kw,
                   CASE WHEN a < 0.60 THEN 'view' WHEN a < 0.75 THEN 'add_to_cart'
                        WHEN a < 0.80 THEN 'remove_from_cart' WHEN a < 0.95 THEN 'search'
                        ELSE 'purchase' END AS action
            FROM (SELECT g, random() AS a FROM generate_series(1, v_n) AS g) AS s0
        ) AS s
        ORDER BY t;

        COMMIT;
        IF v_nb > 1 THEN
            RAISE NOTICE 'gen_behavior_logs batch % / % done', b, v_nb;
        END IF;
    END LOOP;
    DROP TABLE tmp_gen_users;
END;
$proc$;
