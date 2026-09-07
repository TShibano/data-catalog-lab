# 検証用サンプルデータ

OpenMetadata と DataHub に**同じものを取り込んで比較する**ためのサンプル DB．
題材は「顧客が注文し，注文に明細行が付く」というありふれた EC ドメイン．

このディレクトリだけで完結しており，どちらのツールのスタックとも独立に起動できる．

```
examples/
├── README.md                   # 本ファイル
├── sample-data/
│   ├── 01_schema.sql           # DDL（テーブル・ビュー・COMMENT ON）
│   └── 02_data.sql             # INSERT
└── postgres/
    ├── compose.yml             # PostgreSQL 16 の compose 定義
    └── scripts/{up,down}.sh
```

`sample-data/` は PostgreSQL 公式イメージの `/docker-entrypoint-initdb.d/` に
read-only でマウントされ，**ファイル名順**（`01_` → `02_`）に実行される．

## なぜこの構成なのか

比較のために次の 3 つを同時に満たす必要があった．

1. **リネージが確認できること**．両ツールとも PostgreSQL コネクタのリネージは
   「ビュー定義の SQL を解析して table → view の関係を作る」のが基本なので，
   テーブルだけでは何も出ない．**ビューを置くのが必須**．
2. **カラムレベルのリネージまで確認できること**．そのため JOIN と集約の
   両方のパターンを用意した．
3. **description の取り込まれ方を比較できること**．全テーブル・全カラムに
   `COMMENT ON` を付けてある．日本語コメントがどう表示されるかも見られる．

ビューが別のビューを参照する多段構成（view → view）は**あえて避けている**．
`order_details` と `customer_order_summary` はどちらもテーブルを直接参照する．
多段にすると，リネージが取れなかったときに「コネクタが多段を辿れないのか」
「そもそもビューのリネージが取れていないのか」の切り分けが面倒になるため．

## スキーマ

### 全体像

```
  customers ──┐
              ├──> order_details            （3 テーブルを JOIN した行レベルのビュー）
  orders ─────┤
              ├──> customer_order_summary   （顧客単位に集約したビュー）
  order_items ┘
```

テーブル間の外部キーは `orders.customer_id → customers.customer_id`，
`order_items.order_id → orders.order_id`．

### テーブル

**`customers`** — 顧客マスタ．

| カラム | 型 | 説明 |
| --- | --- | --- |
| `customer_id` | `SERIAL PRIMARY KEY` | 顧客 ID |
| `customer_name` | `TEXT NOT NULL` | 顧客の表示名 |
| `email` | `TEXT NOT NULL UNIQUE` | 連絡先メールアドレス |
| `country` | `TEXT NOT NULL` | 居住国（国名表記．ISO コードではない） |
| `signup_date` | `DATE NOT NULL` | サイトへの登録日 |

**`orders`** — 注文ヘッダ．1 件の注文につき 1 行．

| カラム | 型 | 説明 |
| --- | --- | --- |
| `order_id` | `SERIAL PRIMARY KEY` | 注文 ID |
| `customer_id` | `INTEGER NOT NULL` | `customers` への外部キー |
| `order_date` | `DATE NOT NULL` | 注文日 |
| `status` | `TEXT NOT NULL` | `pending` / `shipped` / `delivered` / `cancelled` |

**`order_items`** — 注文明細．1 注文に複数の商品行が紐づく．

| カラム | 型 | 説明 |
| --- | --- | --- |
| `order_item_id` | `SERIAL PRIMARY KEY` | 注文明細 ID |
| `order_id` | `INTEGER NOT NULL` | `orders` への外部キー |
| `product_name` | `TEXT NOT NULL` | 商品名 |
| `quantity` | `INTEGER NOT NULL` | 数量 |
| `unit_price` | `NUMERIC(10,2) NOT NULL` | 単価（USD 想定） |

### ビュー

**`order_details`** — 3 テーブルを JOIN した行レベルの一覧．1 明細行 = 1 レコード．

`orders` を軸に `customers` と `order_items` を内部結合し，
`line_total`（`quantity * unit_price`）という**計算カラム**を持つ．
単純な JOIN のリネージと，式から生まれるカラムのリネージを見るためのもの．

**`customer_order_summary`** — 顧客単位の集約．1 顧客 = 1 レコード．

`customers` を軸に `orders` と `order_items` を外部結合し，
`GROUP BY` で `total_orders`（`COUNT(DISTINCT order_id)`）／
`total_spent`（`SUM(quantity * unit_price)`）／`last_order_date`（`MAX(order_date)`）を集計する．
**集約を挟んだ場合にカラムレベルのリネージがどう表現されるか**を見るためのもの．

`total_spent` は `quantity` と `unit_price` の 2 カラムから作られるため，
「1 つの出力カラムに複数の上流カラムがぶら下がる」ケースの確認にも使える．

## データ

| オブジェクト | 行数 |
| --- | --- |
| `customers` | 20 |
| `orders` | 40 |
| `order_items` | 80 |
| `order_details` | 80 |
| `customer_order_summary` | 20 |

**`random()` は使っていない．** `up.sh` を何度実行しても中身は同じになる．
再現性がないと「取り込み結果が変わったのはツールのせいかデータのせいか」が
分からなくなるため．

- `customers` の 20 件は手書き．15 か国にばらしてある（Japan と USA が 3 件ずつ，
  Korea が 2 件，残りは 1 件ずつ）．登録日は 2023-01-10 〜 2023-10-30．
- `orders` は `generate_series(1, 40)` で生成．`customer_id` を 1..20 で巡回させ，
  **全顧客に必ず注文が付く**ようにしてある．`status` は 4 種類を順に巡回するので
  各 10 件ずつ．注文日は 2023-11-03 〜 2024-01-20．
- `order_items` は各注文に **1〜3 行**（`order_id % 3` で決まる）．
  商品名は 5 種類の巡回，数量は 1〜4，単価は 9.99 〜 114.49 で，
  いずれも `order_id` から決定的に計算される．

## 起動と停止

```sh
./examples/postgres/scripts/up.sh     # 起動．初期化 SQL の完了まで待つ
./examples/postgres/scripts/down.sh   # 停止．--purge でボリュームも削除
```

`up.sh` は起動後に実際に `SELECT` が通るところまで確認してから返る．

接続情報（**検証用の固定値であり秘密ではない**．ローカル専用で外部に公開しない前提）．

| 項目 | 値 |
| --- | --- |
| ホスト（ホスト側から） | `localhost:5432` |
| ホスト（コンテナ内から） | `host.containers.internal:5432` |
| データベース | `sampledb` |
| ユーザ / パスワード | `sample_user` / `sample_password` |
| スキーマ | `public` |

### 初期化 SQL は初回しか流れない

PostgreSQL 公式イメージの `/docker-entrypoint-initdb.d/` は
**データディレクトリが空のときだけ**実行される．
`sample-data/*.sql` を書き換えたら，ボリュームごと作り直さないと反映されない．

```sh
./examples/postgres/scripts/down.sh --purge
./examples/postgres/scripts/up.sh
```

## ツール側からの参照

サンプル DB は各ツールのスタックとは**別の compose プロジェクト**として動くため，
ネットワークも別になる．ネットワークを繋ぐ小細工はせず，
ホストの公開ポート（5432）を `host.containers.internal` 経由で参照させている．

この名前は macOS（`podman machine` 経由）では podman が自動で定義するが，
Linux ネイティブでは版やネットワーク実装によって未定義になりうる．
そのため各 `ingest.sh` は machine を経由しないときだけ
`--add-host=host.containers.internal:host-gateway` を付けて起動する．
インジェスト定義（recipe / ingestion yaml）側は OS によらず同じ内容のまま．

取り込みは各ツールの `ingest.sh` が行う．インジェスト定義の実体はこちら．

- OpenMetadata: `openmetadata/configs/ingestion/postgres_metadata.yaml` および
  `postgres_lineage.yaml`（メタデータとリネージで**パイプラインが分かれている**）
- DataHub: `datahub/configs/recipes/postgres_to_datahub.yml`（1 本で両方やる）

どちらも取り込み対象を `public` スキーマに限定してある．
限定しないと OpenMetadata 側が `information_schema` まで取り込んでしまい，
サンプルデータがノイズに埋もれる（経緯は `docs/comparison.md` を参照）．

## 取り込み後に見るところ

このサンプル DB を取り込んだあと，両ツールで確認したいのは次の 4 点．

1. **検索**: `customers` で検索してテーブルが見つかるか．
2. **description**: `COMMENT ON` で付けた日本語の説明が表示されるか．
3. **リネージ**: `customer_order_summary` の上流に 3 テーブルが並ぶか．
4. **カラムリネージ**: `total_spent` の上流に `quantity` と `unit_price` が並ぶか．

実際に確認した結果は `docs/comparison.md` にまとめてある．
