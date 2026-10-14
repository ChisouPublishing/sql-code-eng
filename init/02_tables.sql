-- 02_tables.sql -- DDL for the 18 Sakura Market tables (Chapters 4 and 5)
-- codes/sql-code-eng/init/02_tables.sql@v1.2.2
-- Design rules: primary keys are uuid DEFAULT uuidv7() (built into PostgreSQL 18).
-- Tables have the audit columns created_at and updated_at.
-- Main tables have deleted_at for soft deletes. All times are timestamptz.
-- Tables are created in foreign key order. Chapter 4 shows the full ER diagram.
-- Money columns are numeric(12,2) and hold US dollars with cents.
--
-- Business fixes made in v1.2.0 (each table comment gives the reason):
--   * orders: stores the amount breakdown (subtotal, discount_amount, shipping_fee).
--     A CHECK constraint ties the breakdown to amount (the amount charged).
--   * order_status_histories (new table): records when an order changed status.
--     It answers "When was this order cancelled?"
--   * shipments: stores a copy of the shipping address.
--     Later edits to an address do not change past shipments.
--   * categories: a parent cannot have two child categories with the same name.
--   * addresses: each user has exactly one default address.
--   * coupons: the use count cannot exceed the limit.
--   * returns: stores the refund amount. payments: stores the payment amount.
--     Both can be reconciled with the order total.
--   * order_items: one row per product per order (use quantity for more units).
--   * A trigger updates updated_at automatically.
-- v1.2.2 adds column comments to every column (COMMENT ON COLUMN only; no behavior or data change).

SET search_path TO sakura, public;

-- ============ Shared: automatic updated_at ============
-- Sets updated_at to the current time when a row is updated.
-- The last-modified time stays correct even if the application forgets to set it.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS
$fn$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION set_updated_at() IS 'BEFORE UPDATE trigger: sets updated_at to the current time';

-- ============ Users ============
CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    email varchar(255) NOT NULL UNIQUE,
    display_name varchar(100) NOT NULL,
    rank varchar(20) NOT NULL DEFAULT 'bronze'
        CHECK (rank IN ('bronze', 'silver', 'gold', 'platinum')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
COMMENT ON TABLE users IS 'Users (registered customers)';
COMMENT ON COLUMN users.email IS 'Email address (login ID)';
COMMENT ON COLUMN users.display_name IS 'Display name (shown as the customer name on screens and reports)';
COMMENT ON COLUMN users.rank IS 'Membership rank (bronze/silver/gold/platinum, lowercase)';
COMMENT ON COLUMN users.deleted_at IS 'Time the user closed the account (soft delete). NULL means active';
COMMENT ON COLUMN users.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN users.created_at IS 'Time the user signed up';
COMMENT ON COLUMN users.updated_at IS 'Last update time (kept current by a trigger)';

CREATE TABLE addresses (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    label varchar(50) NOT NULL,
    postal_code varchar(10) NOT NULL,
    state varchar(2) NOT NULL,
    city varchar(100) NOT NULL,
    street varchar(255) NOT NULL,
    is_default boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE addresses IS 'Addresses (a user can have several shipping addresses)';
COMMENT ON COLUMN addresses.postal_code IS 'ZIP code';
COMMENT ON COLUMN addresses.state IS 'Two-letter US state code (for example CA)';
COMMENT ON COLUMN addresses.is_default IS 'Default shipping address (true for exactly one row per user)';
COMMENT ON COLUMN addresses.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN addresses.user_id IS 'Owner of the address (references users; deleting the user deletes the address)';
COMMENT ON COLUMN addresses.label IS 'Address nickname (home, parents, and so on)';
COMMENT ON COLUMN addresses.city IS 'City';
COMMENT ON COLUMN addresses.street IS 'Street address (number, street, apartment)';
COMMENT ON COLUMN addresses.created_at IS 'Time the address was added';
COMMENT ON COLUMN addresses.updated_at IS 'Last update time (kept current by a trigger)';
-- Business rule: each user has one default address.
-- With two defaults, nobody knows where to ship.
-- This partial unique index allows only one is_default = true row per user_id.
CREATE UNIQUE INDEX uq_addresses_default_per_user ON addresses (user_id) WHERE is_default;

-- ============ Products ============
CREATE TABLE sellers (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    name varchar(255) NOT NULL,
    email varchar(255) NOT NULL UNIQUE,
    commission_rate numeric(5, 4) NOT NULL DEFAULT 0.10
        CHECK (commission_rate >= 0 AND commission_rate <= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE sellers IS 'Sellers (merchants)';
COMMENT ON COLUMN sellers.commission_rate IS 'Commission rate (0.05 = 5%)';
COMMENT ON COLUMN sellers.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN sellers.name IS 'Seller name';
COMMENT ON COLUMN sellers.email IS 'Contact email (unique)';
COMMENT ON COLUMN sellers.created_at IS 'Time the seller joined';
COMMENT ON COLUMN sellers.updated_at IS 'Last update time (kept current by a trigger)';

CREATE TABLE categories (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    name varchar(100) NOT NULL,
    parent_id uuid REFERENCES categories (id),
    display_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- A parent cannot have two children with the same name.
    -- Otherwise one category would split into two rows in a sales report.
    -- NULLS NOT DISTINCT (PostgreSQL 15+) also covers top-level rows (parent_id IS NULL).
    CONSTRAINT uq_categories_parent_name UNIQUE NULLS NOT DISTINCT (parent_id, name)
);
COMMENT ON TABLE categories IS 'Categories (a tree; parent_id NULL means top level)';
COMMENT ON COLUMN categories.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN categories.name IS 'Category name (unique within the same parent)';
COMMENT ON COLUMN categories.parent_id IS 'Parent category (NULL means top level; self-reference to categories)';
COMMENT ON COLUMN categories.display_order IS 'Display order (smaller comes first)';
COMMENT ON COLUMN categories.created_at IS 'Time the category was added';

CREATE TABLE products (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    sku varchar(50) NOT NULL UNIQUE,
    name_en varchar(255) NOT NULL,
    name_es varchar(255),
    name_fr varchar(255),
    price numeric(12, 2) NOT NULL CHECK (price >= 0),
    category_id uuid NOT NULL REFERENCES categories (id),
    seller_id uuid NOT NULL REFERENCES sellers (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
COMMENT ON TABLE products IS 'Products (one row per SKU). price is the current price. The price at order time is order_items.price';
COMMENT ON COLUMN products.name_en IS 'Product name in English (main name)';
COMMENT ON COLUMN products.name_es IS 'Product name in Spanish (NULL if not translated yet)';
COMMENT ON COLUMN products.name_fr IS 'Product name in French (NULL if not translated yet)';
COMMENT ON COLUMN products.price IS 'Current price in USD';
COMMENT ON COLUMN products.deleted_at IS 'Time the product was discontinued (soft delete). Past order items refer to it, so do not delete the row';
COMMENT ON COLUMN products.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN products.sku IS 'Product code (unique)';
COMMENT ON COLUMN products.category_id IS 'Category (references categories)';
COMMENT ON COLUMN products.seller_id IS 'Seller (references sellers)';
COMMENT ON COLUMN products.created_at IS 'Time the product was added';
COMMENT ON COLUMN products.updated_at IS 'Last update time (kept current by a trigger)';

CREATE TABLE inventory (
    product_id uuid PRIMARY KEY REFERENCES products (id) ON DELETE CASCADE,
    stock integer NOT NULL DEFAULT 0 CHECK (stock >= 0),
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE inventory IS 'Inventory (one row per product; the primary key is also the foreign key)';
COMMENT ON COLUMN inventory.product_id IS 'Product (references products and doubles as the primary key, so one row per product)';
COMMENT ON COLUMN inventory.stock IS 'Units in stock (0 or more)';
COMMENT ON COLUMN inventory.updated_at IS 'Last update time (kept current by a trigger)';

CREATE TABLE inventory_logs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    product_id uuid NOT NULL REFERENCES products (id),
    change integer NOT NULL,
    reason varchar(50) NOT NULL
        CHECK (reason IN ('order', 'cancel', 'return', 'restock', 'adjustment')),
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE inventory_logs IS 'Inventory change log (change: positive = stock in, negative = stock out)';
COMMENT ON COLUMN inventory_logs.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN inventory_logs.product_id IS 'Product (references products)';
COMMENT ON COLUMN inventory_logs.change IS 'Units added or removed (positive means stock in, negative means stock out)';
COMMENT ON COLUMN inventory_logs.reason IS 'Reason (order means shipped for an order, cancel means put back by a cancellation, return means put back by a return, restock means new stock, adjustment means an inventory count fix)';
COMMENT ON COLUMN inventory_logs.created_at IS 'Time of the change';

-- ============ Marketing ============
CREATE TABLE coupons (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    code varchar(50) NOT NULL UNIQUE,
    discount_type varchar(20) NOT NULL CHECK (discount_type IN ('percentage', 'fixed')),
    discount_value numeric(12, 2) NOT NULL CHECK (discount_value > 0),
    min_purchase numeric(12, 2) NOT NULL DEFAULT 0 CHECK (min_purchase >= 0),
    max_uses integer CHECK (max_uses IS NULL OR max_uses > 0),
    used_count integer NOT NULL DEFAULT 0 CHECK (used_count >= 0),
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- Do not allow more uses than max_uses. NULL means no limit.
    CONSTRAINT coupons_used_within_max CHECK (max_uses IS NULL OR used_count <= max_uses)
);
COMMENT ON TABLE coupons IS 'Coupons';
COMMENT ON COLUMN coupons.discount_type IS 'percentage = N% off the subtotal; fixed = N dollars off';
COMMENT ON COLUMN coupons.discount_value IS 'Percent for percentage coupons; USD for fixed coupons';
COMMENT ON COLUMN coupons.min_purchase IS 'Minimum subtotal in USD to use the coupon';
COMMENT ON COLUMN coupons.max_uses IS 'Maximum number of uses (NULL = no limit)';
COMMENT ON COLUMN coupons.used_count IS 'Number of uses (orders that were cancelled do not count)';
COMMENT ON COLUMN coupons.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN coupons.code IS 'Coupon code typed at checkout (unique)';
COMMENT ON COLUMN coupons.expires_at IS 'Expiry time (the coupon stops working after this)';
COMMENT ON COLUMN coupons.created_at IS 'Time the coupon was issued';

CREATE TABLE campaigns (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    name varchar(255) NOT NULL,
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (end_at > start_at)
);
COMMENT ON TABLE campaigns IS 'Campaigns (a group of coupons)';
COMMENT ON COLUMN campaigns.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN campaigns.name IS 'Campaign name';
COMMENT ON COLUMN campaigns.start_at IS 'Start time';
COMMENT ON COLUMN campaigns.end_at IS 'End time (must be after the start)';
COMMENT ON COLUMN campaigns.created_at IS 'Time the campaign was added';

CREATE TABLE campaign_coupons (
    campaign_id uuid NOT NULL REFERENCES campaigns (id) ON DELETE CASCADE,
    coupon_id uuid NOT NULL REFERENCES coupons (id) ON DELETE CASCADE,
    PRIMARY KEY (campaign_id, coupon_id)
);
COMMENT ON TABLE campaign_coupons IS 'Join table for the many-to-many link between campaigns and coupons';
COMMENT ON COLUMN campaign_coupons.campaign_id IS 'Campaign (references campaigns; half of the composite primary key)';
COMMENT ON COLUMN campaign_coupons.coupon_id IS 'Coupon (references coupons; half of the composite primary key)';

-- ============ Orders ============
-- Amount breakdown: amount (amount charged) = subtotal - discount_amount + shipping_fee.
-- Without the breakdown, you cannot answer "How much did coupons take off?"
-- or "How much shipping did we collect?"
-- A CHECK constraint enforces the formula, so a row whose parts do not add up is rejected.
CREATE TABLE orders (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id),
    status varchar(20) NOT NULL DEFAULT 'ordered'
        CHECK (status IN ('ordered', 'paid', 'shipped', 'delivered', 'cancelled', 'returned')),
    subtotal numeric(12, 2) NOT NULL CHECK (subtotal >= 0),
    discount_amount numeric(12, 2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    shipping_fee numeric(12, 2) NOT NULL DEFAULT 0 CHECK (shipping_fee >= 0),
    amount numeric(12, 2) NOT NULL CHECK (amount >= 0),
    coupon_id uuid REFERENCES coupons (id),
    ordered_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT orders_amount_breakdown CHECK (amount = subtotal - discount_amount + shipping_fee),
    CONSTRAINT orders_discount_within_subtotal CHECK (discount_amount <= subtotal)
);
COMMENT ON TABLE orders IS 'Orders (one purchase). Amounts are fixed at order time';
COMMENT ON COLUMN orders.status IS 'Current status: ordered (not paid yet) -> paid -> shipped -> delivered. cancelled = cancelled before delivery; returned = returned after delivery';
COMMENT ON COLUMN orders.subtotal IS 'Subtotal in USD (sum of quantity x unit price over the order items)';
COMMENT ON COLUMN orders.discount_amount IS 'Coupon discount in USD (0 if no coupon)';
COMMENT ON COLUMN orders.shipping_fee IS 'Shipping fee in USD ($5.99 if the subtotal is under $50.00; otherwise free)';
COMMENT ON COLUMN orders.amount IS 'Amount charged = subtotal - discount + shipping (what the customer pays; equals the payment amount)';
COMMENT ON COLUMN orders.ordered_at IS 'Order time (the basis for period reports)';
COMMENT ON COLUMN orders.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN orders.user_id IS 'Buyer (references users)';
COMMENT ON COLUMN orders.coupon_id IS 'Coupon used (NULL means none; references coupons)';
COMMENT ON COLUMN orders.created_at IS 'Time the order row was added';
COMMENT ON COLUMN orders.updated_at IS 'Last update time (kept current by a trigger)';

-- Order status history: add one row for each status change. Never overwrite.
-- orders.status holds only the current status.
-- Use this table to find when an order was paid or cancelled.
CREATE TABLE order_status_histories (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    from_status varchar(20)
        CHECK (from_status IN ('ordered', 'paid', 'shipped', 'delivered', 'cancelled', 'returned')),
    to_status varchar(20) NOT NULL
        CHECK (to_status IN ('ordered', 'paid', 'shipped', 'delivered', 'cancelled', 'returned')),
    changed_at timestamptz NOT NULL DEFAULT now(),
    note varchar(255),
    CHECK (from_status IS DISTINCT FROM to_status)
);
COMMENT ON TABLE order_status_histories IS 'Order status history (several rows per order. The first row has from_status NULL, meaning the order was placed)';
COMMENT ON COLUMN order_status_histories.changed_at IS 'Time of the status change (for example, changed_at of the to_status = cancelled row is the cancellation time)';
COMMENT ON COLUMN order_status_histories.note IS 'Note (for example, the cancellation reason)';
COMMENT ON COLUMN order_status_histories.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN order_status_histories.order_id IS 'Order (references orders; deleting the order deletes the history)';
COMMENT ON COLUMN order_status_histories.from_status IS 'Status before the change (NULL on the first row, when the order was placed)';
COMMENT ON COLUMN order_status_histories.to_status IS 'Status after the change';

CREATE TABLE order_items (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    product_id uuid NOT NULL REFERENCES products (id),
    quantity integer NOT NULL CHECK (quantity > 0),
    price numeric(12, 2) NOT NULL CHECK (price >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    -- Do not split one product into two rows of the same order.
    -- Two units are one row with quantity = 2.
    -- Split rows would miscount "orders per product".
    CONSTRAINT uq_order_items_order_product UNIQUE (order_id, product_id)
);
COMMENT ON TABLE order_items IS 'Order items (price is the unit price in USD at order time. Later price changes do not alter past sales)';
COMMENT ON COLUMN order_items.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN order_items.order_id IS 'Order (references orders)';
COMMENT ON COLUMN order_items.product_id IS 'Product (references products; one row per order-product pair)';
COMMENT ON COLUMN order_items.quantity IS 'Quantity (1 or more; extra units go in quantity, not in extra rows)';
COMMENT ON COLUMN order_items.price IS 'Unit price in USD at order time (later price changes do not alter this row)';
COMMENT ON COLUMN order_items.created_at IS 'Time the item was added';

CREATE TABLE payments (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL UNIQUE REFERENCES orders (id) ON DELETE CASCADE,
    method varchar(30) NOT NULL
        CHECK (method IN ('credit_card', 'paypal', 'bank_transfer')),
    status varchar(20) NOT NULL
        CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
    -- Payment amount. It should equal the amount charged (orders.amount).
    -- Reconciliation finds rows where the two differ.
    amount numeric(12, 2) NOT NULL CHECK (amount >= 0),
    paid_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE payments IS 'Payments (one per order. An order that is placed but not paid yet has no row)';
COMMENT ON COLUMN payments.method IS 'credit_card / paypal / bank_transfer (a bank transfer clears in 1 to 72 hours and can expire unpaid)';
COMMENT ON COLUMN payments.status IS 'completed = paid / pending = waiting for payment / failed = not completed (for example, expired) / refunded = refunded';
COMMENT ON COLUMN payments.amount IS 'Payment amount in USD. Equals orders.amount';
COMMENT ON COLUMN payments.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN payments.order_id IS 'Order (references orders; one payment per order)';
COMMENT ON COLUMN payments.paid_at IS 'Time of payment (NULL means not paid yet)';
COMMENT ON COLUMN payments.created_at IS 'Time the payment row was added';

CREATE TABLE shipments (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL UNIQUE REFERENCES orders (id) ON DELETE CASCADE,
    -- The saved address this shipment came from (for reference).
    -- Shipment records stay when the address is deleted, so the column allows NULL (SET NULL).
    address_id uuid REFERENCES addresses (id) ON DELETE SET NULL,
    -- Copy of the shipping address at shipping time.
    -- Later edits to addresses do not change where past orders went (like a shipping label).
    ship_postal_code varchar(10) NOT NULL,
    ship_state varchar(2) NOT NULL,
    ship_city varchar(100) NOT NULL,
    ship_street varchar(255) NOT NULL,
    carrier varchar(50) NOT NULL,
    tracking_number varchar(100),
    shipped_at timestamptz,
    delivered_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE shipments IS 'Shipments (one per order. The address is a copy taken at shipping time)';
COMMENT ON COLUMN shipments.address_id IS 'Saved address used (for reference. NULL if the address was deleted)';
COMMENT ON COLUMN shipments.carrier IS 'Carrier (ups / fedex / usps)';
COMMENT ON COLUMN shipments.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN shipments.order_id IS 'Order (references orders; one shipment per order)';
COMMENT ON COLUMN shipments.ship_postal_code IS 'Destination ZIP code (copy taken at shipping time)';
COMMENT ON COLUMN shipments.ship_state IS 'Destination state (copy taken at shipping time)';
COMMENT ON COLUMN shipments.ship_city IS 'Destination city (copy taken at shipping time)';
COMMENT ON COLUMN shipments.ship_street IS 'Destination street address (copy taken at shipping time)';
COMMENT ON COLUMN shipments.tracking_number IS 'Tracking number (NULL means not issued yet)';
COMMENT ON COLUMN shipments.shipped_at IS 'Shipping time (NULL means not shipped yet)';
COMMENT ON COLUMN shipments.delivered_at IS 'Delivery time (NULL means not delivered yet)';
COMMENT ON COLUMN shipments.created_at IS 'Time the shipment row was added';

CREATE TABLE returns (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    reason varchar(255) NOT NULL,
    status varchar(20) NOT NULL
        CHECK (status IN ('requested', 'approved', 'received', 'refunded', 'rejected')),
    -- Refund amount. Lets you total how much money returns cost (0 until refunded).
    refund_amount numeric(12, 2) NOT NULL DEFAULT 0 CHECK (refund_amount >= 0),
    returned_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE returns IS 'Returns (an order can have several)';
COMMENT ON COLUMN returns.refund_amount IS 'Refund amount in USD';
COMMENT ON COLUMN returns.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN returns.order_id IS 'Order (references orders; one order can have several returns)';
COMMENT ON COLUMN returns.reason IS 'Return reason';
COMMENT ON COLUMN returns.status IS 'Status (requested means asked, approved means accepted, received means the item arrived, refunded means the money was sent back, rejected means refused)';
COMMENT ON COLUMN returns.returned_at IS 'Time the return arrived (NULL means not received yet)';
COMMENT ON COLUMN returns.created_at IS 'Time the return was requested';

CREATE TABLE reviews (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id),
    product_id uuid NOT NULL REFERENCES products (id),
    rating integer NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, product_id)
);
COMMENT ON TABLE reviews IS 'Reviews (one per user per product)';
COMMENT ON COLUMN reviews.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN reviews.user_id IS 'Reviewer (references users)';
COMMENT ON COLUMN reviews.product_id IS 'Product (references products)';
COMMENT ON COLUMN reviews.rating IS 'Rating (1 to 5)';
COMMENT ON COLUMN reviews.comment IS 'Review text (NULL allowed)';
COMMENT ON COLUMN reviews.created_at IS 'Time of posting';

-- ============ Behavior log ============
-- An append-only table (no UPDATE). Rows are stored in created_at order,
-- so a BRIN index works well (Chapter 10).
CREATE TABLE behavior_logs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid REFERENCES users (id),
    product_id uuid REFERENCES products (id),
    action varchar(30) NOT NULL
        CHECK (action IN ('view', 'add_to_cart', 'remove_from_cart', 'search', 'purchase')),
    search_keyword varchar(255),
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE behavior_logs IS 'Behavior log (for analysis; append-only. user_id is NULL for guests; product_id is NULL for searches)';
COMMENT ON COLUMN behavior_logs.id IS 'Primary key (auto-generated with uuidv7)';
COMMENT ON COLUMN behavior_logs.user_id IS 'Actor (NULL means a guest; references users)';
COMMENT ON COLUMN behavior_logs.product_id IS 'Product (NULL for searches with no product)';
COMMENT ON COLUMN behavior_logs.action IS 'Action (view means a page view, add_to_cart means added to the cart, remove_from_cart means removed from the cart, search means a search, purchase means a purchase)';
COMMENT ON COLUMN behavior_logs.search_keyword IS 'Search words (NULL for non-search actions)';
COMMENT ON COLUMN behavior_logs.created_at IS 'Time of the action';

-- ============ updated_at triggers (every table with updated_at) ============
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_addresses_updated_at BEFORE UPDATE ON addresses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sellers_updated_at BEFORE UPDATE ON sellers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_inventory_updated_at BEFORE UPDATE ON inventory
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated_at BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
