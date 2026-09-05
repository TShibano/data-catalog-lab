-- 検証用サンプルスキーマ．
-- OpenMetadata / DataHub の両方に同じ内容を取り込み，検索・リネージの見え方を
-- 比較するためのもの．題材は「顧客が注文し，注文に明細行が付く」という
-- ありふれた EC ドメイン．
--
-- 構成:
--   テーブル: customers / orders / order_items
--   ビュー  : order_details（3 テーブルを JOIN した行レベルのビュー）
--             customer_order_summary（顧客単位に集約したビュー）
-- どちらのビューも「テーブルを直接 JOIN / 集約」する定義にしてある．
-- 両ツールの postgres コネクタは view definition の SQL から
-- table -> view のリネージを取るのが基本のため，ビューが別のビューを
-- 参照する形（view -> view の多段）は避けている．

CREATE TABLE customers (
    customer_id   SERIAL PRIMARY KEY,
    customer_name TEXT NOT NULL,
    email         TEXT NOT NULL UNIQUE,
    country       TEXT NOT NULL,
    signup_date   DATE NOT NULL
);

COMMENT ON TABLE customers IS '顧客マスタ．EC サイトに登録した顧客の基本情報を保持する．';
COMMENT ON COLUMN customers.customer_id IS '顧客 ID（主キー）．';
COMMENT ON COLUMN customers.customer_name IS '顧客の表示名．';
COMMENT ON COLUMN customers.email IS '連絡先メールアドレス（一意）．';
COMMENT ON COLUMN customers.country IS '居住国（ISO のような厳密なコードではなく国名表記）．';
COMMENT ON COLUMN customers.signup_date IS 'サイトへの登録日．';

CREATE TABLE orders (
    order_id     SERIAL PRIMARY KEY,
    customer_id  INTEGER NOT NULL REFERENCES customers (customer_id),
    order_date   DATE NOT NULL,
    status       TEXT NOT NULL
);

COMMENT ON TABLE orders IS '注文ヘッダ．1 件の注文につき 1 行．明細は order_items が持つ．';
COMMENT ON COLUMN orders.order_id IS '注文 ID（主キー）．';
COMMENT ON COLUMN orders.customer_id IS '注文した顧客（customers への外部キー）．';
COMMENT ON COLUMN orders.order_date IS '注文日．';
COMMENT ON COLUMN orders.status IS '注文ステータス（pending / shipped / delivered / cancelled のいずれか）．';

CREATE TABLE order_items (
    order_item_id SERIAL PRIMARY KEY,
    order_id      INTEGER NOT NULL REFERENCES orders (order_id),
    product_name  TEXT NOT NULL,
    quantity      INTEGER NOT NULL,
    unit_price    NUMERIC(10, 2) NOT NULL
);

COMMENT ON TABLE order_items IS '注文明細．1 注文に複数の商品行が紐づく．';
COMMENT ON COLUMN order_items.order_item_id IS '注文明細 ID（主キー）．';
COMMENT ON COLUMN order_items.order_id IS '所属する注文（orders への外部キー）．';
COMMENT ON COLUMN order_items.product_name IS '商品名．';
COMMENT ON COLUMN order_items.quantity IS '数量．';
COMMENT ON COLUMN order_items.unit_price IS '単価（USD 想定）．';

-- 行レベルのビュー: customers / orders / order_items の 3 テーブルを JOIN する．
-- table -> view のリネージ確認に使う（3 テーブルすべてが上流に現れるはず）．
CREATE VIEW order_details AS
SELECT
    o.order_id,
    o.order_date,
    o.status,
    c.customer_id,
    c.customer_name,
    c.country,
    oi.order_item_id,
    oi.product_name,
    oi.quantity,
    oi.unit_price,
    (oi.quantity * oi.unit_price) AS line_total
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id;

COMMENT ON VIEW order_details IS
    '注文明細の行レベル一覧．orders / customers / order_items を JOIN し，
     1 明細行 = 1 レコードにしたもの．リネージ確認用のビュー．';

-- 集約ビュー: 顧客単位に注文実績を集計する．こちらも customers / orders /
-- order_items を直接 JOIN・集約しており，order_details は経由しない．
CREATE VIEW customer_order_summary AS
SELECT
    c.customer_id,
    c.customer_name,
    c.country,
    COUNT(DISTINCT o.order_id)              AS total_orders,
    COALESCE(SUM(oi.quantity * oi.unit_price), 0) AS total_spent,
    MAX(o.order_date)                       AS last_order_date
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id
LEFT JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY c.customer_id, c.customer_name, c.country;

COMMENT ON VIEW customer_order_summary IS
    '顧客単位の注文サマリ．総注文数・累計購入額・最終注文日を集計する．
     customers / orders / order_items を直接 JOIN・集約したビュー
     （order_details は経由しない）．リネージ確認用のビュー．';
