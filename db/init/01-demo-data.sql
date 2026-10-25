-- Тестовые данные для проверки бэкапа/восстановления.
CREATE TABLE customers (
    id         bigserial PRIMARY KEY,
    email      text NOT NULL UNIQUE,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id          bigserial PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers(id),
    status      text NOT NULL CHECK (status IN ('new', 'paid', 'shipped', 'cancelled')),
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
    id         bigserial PRIMARY KEY,
    order_id   bigint NOT NULL REFERENCES orders(id),
    sku        text NOT NULL,
    quantity   int NOT NULL CHECK (quantity > 0),
    unit_price numeric(10, 2) NOT NULL
);

CREATE INDEX orders_customer_id_idx ON orders (customer_id);
CREATE INDEX order_items_order_id_idx ON order_items (order_id);

INSERT INTO customers (email, name, created_at)
SELECT 'user' || g || '@example.com', 'Customer ' || g, now() - (g % 365) * interval '1 day'
FROM generate_series(1, 5000) g;

INSERT INTO orders (customer_id, status, created_at)
SELECT 1 + (g % 5000),
       (ARRAY['new', 'paid', 'shipped', 'cancelled'])[1 + g % 4],
       now() - (g % 180) * interval '1 day'
FROM generate_series(1, 20000) g;

INSERT INTO order_items (order_id, sku, quantity, unit_price)
SELECT 1 + (g % 20000), 'SKU-' || (g % 300), 1 + g % 5, round((5 + (g % 200))::numeric, 2)
FROM generate_series(1, 50000) g;
