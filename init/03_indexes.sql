-- 03_indexes.sql -- Base indexes (Chapter 5, section 5.4)
-- codes/sql-code-eng/init/03_indexes.sql@v1.2.2
-- Rules: create a B-tree index on each foreign key column of the child table,
-- and on columns that queries search often. Soft-delete tables get partial indexes.
-- Advanced indexes (multicolumn, INCLUDE, GIN, BRIN) are in queries/ch10_index_design.sql.
--
-- v1.2.0 review (Chapter 5 found 7 foreign key columns without an index):
--   * Added: shipments.address_id / orders.coupon_id / returns.order_id /
--            inventory_logs.product_id / addresses.user_id / campaign_coupons.coupon_id
--     Each one is used to find child rows from the parent,
--     for example when you delete a parent or list the returns of an order.
--   * Covered by another index: categories.parent_id is the leading column of
--     the unique constraint uq_categories_parent_name (parent_id, name).
--   * Removed: idx_order_items_order duplicates the leading column of
--     the unique constraint uq_order_items_order_product (order_id, product_id).
--     Two indexes that do the same job only slow down writes.
-- Check: the Chapter 5 query finds 0 foreign key columns without an index.

SET search_path TO sakura, public;

-- Products
CREATE INDEX IF NOT EXISTS idx_products_category ON products (category_id);
CREATE INDEX IF NOT EXISTS idx_products_seller ON products (seller_id);

-- Orders
CREATE INDEX IF NOT EXISTS idx_orders_user ON orders (user_id);
CREATE INDEX IF NOT EXISTS idx_orders_ordered_at ON orders (ordered_at);
CREATE INDEX IF NOT EXISTS idx_orders_coupon ON orders (coupon_id);
-- uq_order_items_order_product also serves order_items (order_id)
CREATE INDEX IF NOT EXISTS idx_order_items_product ON order_items (product_id);
-- Status history: one index returns the history of an order in time order
CREATE INDEX IF NOT EXISTS idx_order_status_histories_order
    ON order_status_histories (order_id, changed_at);
CREATE INDEX IF NOT EXISTS idx_returns_order ON returns (order_id);
CREATE INDEX IF NOT EXISTS idx_shipments_address ON shipments (address_id);

-- Customers, inventory, promotions
CREATE INDEX IF NOT EXISTS idx_addresses_user ON addresses (user_id);
CREATE INDEX IF NOT EXISTS idx_inventory_logs_product ON inventory_logs (product_id, created_at);
CREATE INDEX IF NOT EXISTS idx_campaign_coupons_coupon ON campaign_coupons (coupon_id);

-- Behavior log and reviews
CREATE INDEX IF NOT EXISTS idx_behavior_logs_user_time ON behavior_logs (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_behavior_logs_product_time ON behavior_logs (product_id, created_at);
CREATE INDEX IF NOT EXISTS idx_reviews_product ON reviews (product_id);
-- reviews (user_id) is covered by the leading column of the unique constraint (user_id, product_id)

-- Soft-delete tables: partial indexes on active rows only
CREATE INDEX IF NOT EXISTS idx_users_active ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_products_active ON products (sku) WHERE deleted_at IS NULL;
