-- 04_master_data.sql -- Load master data (Chapter 5)
-- codes/sql-code-eng/init/04_master_data.sql@v1.2.2
-- 10 categories (5 parents + 5 children), 20 sellers, 10 coupons, 2 campaigns.
-- Master data uses no random numbers. Every load gives the same content (except ids and times).

SET search_path TO sakura, public;

-- Categories: 5 parents
INSERT INTO categories (id, name, parent_id, display_order) VALUES
    (uuidv7(), 'electronics', NULL, 1),
    (uuidv7(), 'fashion', NULL, 2),
    (uuidv7(), 'foods', NULL, 3),
    (uuidv7(), 'books', NULL, 4),
    (uuidv7(), 'home', NULL, 5);

-- Categories: 5 children (look up the parent by name)
INSERT INTO categories (id, name, parent_id, display_order)
SELECT uuidv7(), c.name, p.id, c.display_order
FROM (VALUES
    ('smartphone', 'electronics', 11),
    ('laptop', 'electronics', 12),
    ('mens', 'fashion', 21),
    ('novel', 'books', 41),
    ('kitchen', 'home', 51)
) AS c (name, pname, display_order)
JOIN categories p ON p.name = c.pname AND p.parent_id IS NULL;

-- 20 sellers (deterministic)
INSERT INTO sellers (name, email, commission_rate)
SELECT 'seller_' || g, 'seller_' || g || '@example.com', 0.05 + (g % 10) * 0.01
FROM generate_series(1, 20) AS g;

-- 10 coupons
--   Even numbers: percentage (5% to 20% off). Odd numbers: fixed ($5 to $25 off).
--   Minimum subtotal (min_purchase): $0 / $25 / $50.
--   Use limit (max_uses): every third coupon (CPN0003/0006/0009) allows 1000 uses.
--   The others have no limit (NULL).
--   Issue date (created_at): two years ago, because orders from the past two years use them.
INSERT INTO coupons (code, discount_type, discount_value, min_purchase, max_uses,
                     expires_at, created_at)
SELECT
    'CPN' || lpad(g::text, 4, '0'),
    CASE WHEN g % 2 = 0 THEN 'percentage' ELSE 'fixed' END,
    CASE WHEN g % 2 = 0 THEN 5 + (g % 4) * 5 ELSE 5 + (g % 5) * 5 END,
    (g % 3) * 25,
    CASE WHEN g % 3 = 0 THEN 1000 END,
    now() + (interval '1 day' * (30 + g)),
    now() - interval '800 days'
FROM generate_series(1, 10) AS g;

-- 2 campaigns and the join table (an example that groups the first three coupons)
--   spring_sale = CPN0001 and CPN0002; new_user_cp = CPN0001 to CPN0003
INSERT INTO campaigns (name, start_at, end_at) VALUES
    ('spring_sale', now() - interval '10 days', now() + interval '20 days'),
    ('new_user_cp', now() - interval '5 days', now() + interval '25 days');

-- Always give row_number() an ORDER BY.
-- Without it, the numbering can change from one run to the next.
INSERT INTO campaign_coupons (campaign_id, coupon_id)
SELECT camp.id, coup.id
FROM (SELECT id, row_number() OVER (ORDER BY name DESC) AS rn FROM campaigns) AS camp
JOIN (SELECT id, row_number() OVER (ORDER BY code) AS rn FROM coupons) AS coup
  ON coup.rn <= 2 OR (camp.rn = 2 AND coup.rn = 3);
