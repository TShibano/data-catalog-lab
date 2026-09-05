-- サンプルデータ投入．
-- 各テーブル数十行程度で十分なので，顧客は手書き，注文・注文明細は
-- generate_series を使い決定的な（毎回同じ結果になる）データにしている
-- （random() は使わない．up.sh を何度実行しても同じ内容になる）．

-- customers: 20 件．
INSERT INTO customers (customer_name, email, country, signup_date) VALUES
    ('Aiko Tanaka',      'aiko.tanaka@example.com',      'Japan',   '2023-01-10'),
    ('Bruno Silva',      'bruno.silva@example.com',      'Brazil',  '2023-01-22'),
    ('Chloe Martin',     'chloe.martin@example.com',     'France',  '2023-02-03'),
    ('David Kim',        'david.kim@example.com',        'Korea',   '2023-02-14'),
    ('Elena Petrova',    'elena.petrova@example.com',    'Russia',  '2023-03-01'),
    ('Felix Wagner',     'felix.wagner@example.com',     'Germany', '2023-03-19'),
    ('Grace Lee',        'grace.lee@example.com',        'Korea',   '2023-04-02'),
    ('Hiroshi Sato',     'hiroshi.sato@example.com',     'Japan',   '2023-04-15'),
    ('Isabella Rossi',   'isabella.rossi@example.com',   'Italy',   '2023-05-01'),
    ('Jack Wilson',      'jack.wilson@example.com',      'UK',      '2023-05-20'),
    ('Karin Larsen',     'karin.larsen@example.com',     'Denmark', '2023-06-04'),
    ('Liam O''Brien',    'liam.obrien@example.com',      'Ireland', '2023-06-18'),
    ('Mei Chen',         'mei.chen@example.com',         'China',   '2023-07-02'),
    ('Noah Garcia',      'noah.garcia@example.com',      'Spain',   '2023-07-21'),
    ('Olivia Brown',     'olivia.brown@example.com',     'USA',     '2023-08-05'),
    ('Pedro Alvarez',    'pedro.alvarez@example.com',    'Mexico',  '2023-08-23'),
    ('Quinn Taylor',     'quinn.taylor@example.com',     'USA',     '2023-09-09'),
    ('Rin Yamamoto',     'rin.yamamoto@example.com',     'Japan',   '2023-09-27'),
    ('Sara Johansson',   'sara.johansson@example.com',   'Sweden',  '2023-10-11'),
    ('Tom Anderson',     'tom.anderson@example.com',     'USA',     '2023-10-30');

-- orders: 40 件．customer_id は 1..20 を巡回させ，全顧客に注文が付くようにする．
-- status は pending / shipped / delivered / cancelled を順に巡回させる．
INSERT INTO orders (customer_id, order_date, status)
SELECT
    ((n - 1) % 20) + 1,
    DATE '2023-11-01' + (n * 2),
    (ARRAY['pending', 'shipped', 'delivered', 'cancelled'])[1 + ((n - 1) % 4)]
FROM generate_series(1, 40) AS n;

-- order_items: 各注文に 1〜3 行の明細を付ける（order_id % 3 で行数が変わる）．
-- 商品名は 5 種類を巡回，数量・単価も注文 ID から決定的に計算する．
INSERT INTO order_items (order_id, product_name, quantity, unit_price)
SELECT
    o.order_id,
    (ARRAY['Widget A', 'Widget B', 'Gadget X', 'Gadget Y', 'Gizmo Z'])[1 + ((o.order_id + s) % 5)],
    1 + ((o.order_id + s) % 4),
    (9.99 + (((o.order_id * 3) + s) % 20) * 5.5)::NUMERIC(10, 2)
FROM orders o
CROSS JOIN generate_series(0, (o.order_id % 3)) AS s;
