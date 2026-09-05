# OpenMetadata と DataHub の比較（検証記録）

## 検証日・対象バージョン・検証環境

- 検証日: 2026-09-05．
- 対象バージョン: OpenMetadata **2.0.1** ／ DataHub **1.7.0**．本ドキュメントの内容はこの 1 回・このバージョンの組み合わせでの検証結果であり，将来のバージョンでは状況が変わりうる．
- 検証環境: podman 6.1.1／podman-compose 1.6.0（`podman compose` の external provider として利用）／podman machine: CPU 4・メモリ 9.3GiB（9536MiB）・ディスク 40GB／ホストは Apple Silicon（arm64）の macOS．
- 検証方法の限定（重要）: 両ツールとも**操作はすべて REST API（curl）経由**で行った．ブラウザで UI を開いての操作・目視確認は一切していない．そのため **UI の使い勝手についてはこのドキュメントでは評価しない**（両ツールとも「未評価」）．なお，後述の「システムスキーマの既定の扱い」の問題は，利用者が実際にブラウザで OpenMetadata の Explore を開き，情報スキーマ混入分も含めて 816 件が並びサンプルデータが見つけにくいと報告したことが発端である．これは取り込み件数の問題を UI 上で発見したという経緯であり，UI の使い勝手そのものを評価したわけではないため，UI の使い勝手は引き続き「未評価」のまま扱う．
- 起動時間・実メモリ使用量（`podman stats` 相当）は計測していない．**未計測**．理由: `podman compose up -d` 自体が `depends_on: condition: service_healthy` を待って返るため，スクリプト側の待機ループの経過時間はツール間で公平に比較できる形で記録できていない．

再現手順はこのドキュメントには書かない．各スクリプトを参照すること．

- サンプル DB: `examples/postgres/scripts/up.sh` / `down.sh`
- OpenMetadata: `openmetadata/scripts/up.sh` / `ingest.sh` / `down.sh` / `status.sh` / `logs.sh`
- DataHub: `datahub/scripts/up.sh` / `ingest.sh` / `down.sh` / `status.sh` / `logs.sh`

## 観点表

| 観点 | OpenMetadata 2.0.1 | DataHub 1.7.0 |
| --- | --- | --- |
| compose 上のサービス数 | 5（`mysql` / `elasticsearch` / `execute-migrate-all` / `openmetadata-server` / `ingestion`．うち `execute-migrate-all` は初回のみ実行されるマイグレーションジョブ） | 7（`mysql` / `opensearch` / `kafka-broker` / `system-update-quickstart` / `datahub-gms-quickstart` / `frontend-quickstart` / `datahub-actions-quickstart`．うち `system-update-quickstart` は初回のみ実行されるシステム更新ジョブ） |
| スタック本体のイメージ合計サイズ（実測，概算） | 約 7.8GB（db 520MB + server 669MB + elasticsearch 991MB + ingestion 5.58GB） | 約 7.25GB（gms 1.56GB + frontend 932MB + actions 1.4GB + upgrade 977MB + kafka 564MB + opensearch 1.16GB + mysql 654MB） |
| 本リポジトリで作った `Containerfile.ingestion` のイメージサイズ（実測） | 5.6GB（公式 ingestion イメージ自体が Airflow 込みで大きいため） | 456MB（`python:3.11-slim` + `acryl-datahub` の pip install のみ） |
| `up.sh` が podman machine に要求するメモリ | 6144MiB（6GB） | 8192MiB（8GB） |
| `compose.override.yml` の `mem_limit` 合計（常駐サービスのみ） | 7g（mysql 1g + elasticsearch 2g + server 2g + ingestion 2g） | 8g（mysql 1g + opensearch 2g + kafka-broker 1g + gms 2g + frontend 1g + actions 1g） |
| 配布形態 | GitHub Release の `docker-compose.yml`（リリースタグ固定） | GitHub 上の quickstart profile 版 `docker-compose.yml`（ブランチ/タグ参照） |
| `--profile` の要否 | 不要 | 必須．全 7 サービスに `profiles:` が付いており，`--profile quickstart` を指定しないと 1 つも起動しない |
| 既定値のない（＝実質必須の）環境変数の数 | 0 個（upstream compose は全て `${VAR:-default}` 形式） | 4 個（`DATAHUB_VERSION` / `DATAHUB_TOKEN_SERVICE_SALT` / `DATAHUB_TOKEN_SERVICE_SIGNING_KEY` / `UI_INGESTION_DEFAULT_CLI_VERSION`） |
| インジェストの認証 | JWT 必須（`ingestion-bot`） | quickstart 既定では認証なし |
| メタデータ／リネージの実行単位 | 別パイプライン（`source.type: postgres` と `postgres-lineage` を分けて 2 回 `metadata ingest` を実行） | 単一 recipe（`include_view_lineage: true`）で 1 回の `datahub ingest` に統合 |
| システムスキーマの既定の扱い | 既定で `information_schema` まで取り込む（未設定時は 816 エンティティ．`schemaFilterPattern.includes: ["^public$"]` を明示して `public` のみ 38 件に絞り込み済み） | 既定で `public` の 5 データセットのみを取り込み，システムスキーマは自動的に除外される |
| 今回のリネージ検証（`customer_order_summary`） | 上流 3 テーブル，列単位マッピング 7 件（API レスポンス実測） | 上流 3 データセット，`fineGrainedLineages` 6 件（API レスポンス実測） |
| ポート衝突（既定起動時） | 3306 / 9200,9300 / 8080 が DataHub と衝突 | 3306 / 9200 / 8080 が OpenMetadata と衝突 |
| 同時起動の回避策 | `OM_ALT_PORTS=1`（mysql→13306, es→19200/19300, ingestion→18080．server の 8585/8586 は据え置き） | `DATAHUB_ALT_PORTS=1`（mysql→23306, opensearch→29200, gms→28080．frontend の 9002 は据え置き） |
| UI の使い勝手 | 未評価（API 経由でのみ操作） | 未評価（API 経由でのみ操作） |
| 起動時間・実メモリ使用量 | 未計測 | 未計測 |

以下，各観点の詳細と根拠．

## 構成の重さ

OpenMetadata は compose 上 5 サービス，DataHub は 7 サービスで，DataHub の方がコンポーネント数が多い（Kafka ブローカーとシステム更新ジョブが増える分）．ただしイメージの合計サイズで見ると OpenMetadata（約 7.8GB）と DataHub（約 7.25GB）はほぼ同水準で，「サービス数が多い＝重い」とは単純に言えなかった．内訳を見ると，OpenMetadata は `ingestion`（Airflow ベース）1 イメージだけで 5.58GB を占めており，これがサービス数の少なさを打ち消している．

対照的に，今回検証用に作った `Containerfile.ingestion` の拡張イメージは OpenMetadata 側が 5.6GB，DataHub 側が 456MB と 12 倍以上の差が出た．OpenMetadata の公式 ingestion イメージが Airflow 一式を含む重量級イメージであるのに対し，DataHub は `python:3.11-slim` に `acryl-datahub` を pip install するだけで済むためである．インジェスト専用の実行環境を素早く用意したい・CI 等で頻繁にビルドし直したい，という観点では DataHub 側が明確に有利だった．

podman machine への要求メモリは OpenMetadata 6GB，DataHub 8GB と `up.sh` にハードコードしており（本リポジトリの `ensure_machine` 呼び出し引数），`compose.override.yml` の `mem_limit` 合計（常駐サービスのみ）も OpenMetadata 7g／DataHub 8g で，これもDataHub がやや重い．

## セットアップの手間

DataHub の upstream compose は全サービスに `profiles:` が付与されており，`--profile quickstart` を明示しないと 1 つのコンテナも起動しない仕様だった．OpenMetadata の upstream compose にはこの制約はない．

環境変数については方向性が逆だった．OpenMetadata の upstream compose は環境変数がすべて `${VAR:-default}` 形式で，既定値を持たない変数は 1 つもない．一方 DataHub の upstream compose には既定値のない変数が 4 つ（`DATAHUB_VERSION` / `DATAHUB_TOKEN_SERVICE_SALT` / `DATAHUB_TOKEN_SERVICE_SIGNING_KEY` / `UI_INGESTION_DEFAULT_CLI_VERSION`）あり，`datahub/configs/datahub.env` で明示的に埋める必要があった．

もっとも，「既定値がある」ことが「そのまま使える」ことを意味しないのが OpenMetadata の厄介なところで，これは次節で詳しく書く．

## 詰まった点

各ツールの `configs/`・`compose.override.yml` 等に実装時のコメントとして残してあるが，比較材料として改めてまとめる．

**OpenMetadata**
- upstream compose の既定イメージ参照先が `docker.getcollate.io` ミラーで，匿名 pull の制限（`toomanyrequests`）に実機で当たった．同一イメージが公開されている `docker.io/openmetadata/*` へ切り替える必要があった（`openmetadata/configs/openmetadata.env` で対応）．
- リリースタグ（2.0.1）と，compose 内に書かれた既定イメージタグ（2.0.0）が食い違っていた．`docker.io/openmetadata/*:2.0.1` を明示指定することで解消した．
- インジェストの JWT 取得手順が公式ドキュメントだけでは分かりにくく，実機で API を叩いて調べる必要があった（詳細は次の「認証」節）．
- メタデータとリネージが別パイプラインで，しかも `source.type` を `postgres` と `postgres-lineage` で使い分けないと `metadata ingest` が例外（`AttributeError`）で落ちることが実機での試行錯誤で判明した．`metadata lineage` という別サブコマンドも存在するが，これは 1 本の生 SQL を手動でリネージ登録する ad-hoc 用途で，今回の用途には使えなかった．詳細は `openmetadata/configs/ingestion/postgres_lineage.yaml` のコメントを参照．
- `sourceConfig.config.schemaFilterPattern` を明示しないと `information_schema` などシステムスキーマまで取り込まれることが，ステップ 1〜5 完了後に UI で確認して判明した（実測 816 エンティティ，詳細は「取り込み結果」節）．`schemaFilterPattern.includes: ["^public$"]` を指定して解決したが，`DatabaseServiceMetadataPipeline`（`postgres_metadata.yaml`）と `DatabaseServiceQueryLineagePipeline`（`postgres_lineage.yaml`）の両方に別々に指定する必要があり，片方だけでは取り込み範囲が揃わない．

**DataHub**
- イメージタグに `v` 接頭辞が必要（`v1.7.0`）で，compose 取得 URL 用のバージョン表記（`1.7.0`，`v` なし）と食い違っていた．同じ「DataHub 1.7.0」でも参照する場所によって表記が違う点は，バージョンを上げる際の見落としリスクになる．
- `datahub ingest` が終了時に利用統計を `track.datahubproject.io` へ送ろうとし，このホストに到達できない環境では接続タイムアウトのリトライで数分ハングした．`DATAHUB_TELEMETRY_ENABLED=false` を渡すことで解消した．

**両者共通（ツールの差ではなく環境側の話）**
- podman-compose 1.6.0 は `!override` タグで包んだノードの中で `${VAR}` を展開しない不具合があり，両ツールの `compose.override.yml` / `compose.altports.yml` でポート番号を変数ではなくリテラル値で書く必要があった．これは OpenMetadata・DataHub どちらのツール自体の問題でもなく，本リポジトリが使っている podman-compose のバージョン固有の制約として位置づけている．

## インジェストの実行モデル

ここが両ツールで最も設計思想が異なった点だった．

OpenMetadata は「メタデータ取り込み」と「リネージ取り込み」が別パイプライン概念であり，`sourceConfig.config.type` を `DatabaseMetadata` にした recipe と `DatabaseLineage` にした recipe を別々に用意し，`metadata ingest` を 2 回実行する必要があった．しかもリネージ側は `source.type` を素の `postgres` ではなく `postgres-lineage` にしないと動かない（`postgres` のままだと `DatabaseServiceQueryLineagePipeline` に無いフィールドへアクセスして例外になる）．これは OpenMetadata の `service_spec.py` が `metadata_source_class` / `lineage_source_class` / `usage_source_class` をコネクタごとに別クラスとして持ち，`<connector>-lineage` という type サフィックスで切り替える仕組みになっているためで，ドキュメントよりコードを読んで確認する必要があった．

DataHub は単一の recipe に `include_view_lineage: true`（今回使ったバージョンでは既定値も true）を書くだけで，メタデータとリネージが同じ `datahub ingest` 1 回の実行で両方生成された．運用上の手間としては DataHub の方が明確に少ない．

## 認証

OpenMetadata はインジェストに JWT（`ingestion-bot` のトークン）が必須で，未設定だと書き込みが拒否される．今回は次の手順で API から動的に取得した．

1. `POST /api/v1/users/login`（管理者の既定クレデンシャル `admin@open-metadata.org` / `admin`，パスワードは base64 化して送信）で管理者のアクセストークンを取得．
2. `GET /api/v1/users/name/ingestion-bot` で `ingestion-bot` のユーザ ID を取得．
3. `GET /api/v1/users/token/{id}` で `ingestion-bot` の JWT を取得（サーバが初期セットアップ時に自動生成済みのものをそのまま読み出せた．新規生成する `PUT /api/v1/users/generateToken/{id}` も存在するが，今回は既存トークンの読み出しで足りた）．

この一連の流れは `openmetadata/scripts/ingest.sh` に実装し，取得したトークンはログに出さず，`mktemp` した一時ファイル（`chmod 600`）に埋め込んで実行後に削除する形にした．

一方 DataHub の quickstart 構成は既定で認証を要求しない．`datahub ingest`（`datahub-rest` sink）はもちろん，検索 API（`/entities?action=search`）やリネージ確認用の `/aspects` エンドポイントも，Authorization ヘッダなしでそのまま書き込み・読み出しができた．

これは「セットアップが楽」という利点であると同時に，「既定状態でネットワーク到達できる相手なら誰でもメタデータを読み書きできる」という裏返しでもある．今回の検証は隔離されたローカル環境で行っており，本番相当の運用でこの既定構成のまま外部に公開すべきではない点は明記しておく．なお，これはあくまで **quickstart 構成（検証・評価用の既定値）についての観察**であり，DataHub が常に無認証運用しか提供しないという意味ではない．認証を有効化する構成については未検証．

## 取り込み結果（API レスポンス実測）

両ツールとも `examples/sample-data/` の 3 テーブル（`customers` / `orders` / `order_items`）と 2 ビュー（`order_details` / `customer_order_summary`）を取り込めた．ただし，取り込み**範囲**の既定挙動には大きな差があった．

### システムスキーマの既定の扱い（挙動差）

- OpenMetadata の postgres コネクタは `schemaFilterPattern` を指定しない既定状態では `information_schema` まで丸ごと取り込む．実機で確認したところ，サンプル DB の 5 テーブル／ビューに対して **816 エンティティ**（内訳: `tableColumn` 728 / `table` 74〔`public` 5 + `information_schema` 69〕/ `storedProcedure` 11 / `databaseSchema`・`database` 3）が生成され，スキーマ別では `information_schema` 777 / `public` 36 とノイズが 9 割以上を占めた．UI の Explore で `sample_postgres` サービスを開くとこの 816 件に埋もれてサンプルデータが見つけにくいという問題が実際に見つかった（検証方法の節を参照）．
  - `openmetadata/configs/ingestion/postgres_metadata.yaml` と `postgres_lineage.yaml` の両方の `sourceConfig.config` に `schemaFilterPattern.includes: ["^public$"]` を追加して解消した．修正後，`GET /api/v1/databaseSchemas?database=sample_postgres.sampledb&limit=100` は `public` の 1 件のみを返し，`information_schema` は含まれない．`GET /api/v1/tables?databaseSchema=sample_postgres.sampledb.public&limit=100` の `paging.total` は 5 件で，内訳は `customers` / `orders` / `order_items`（Regular）と `order_details` / `customer_order_summary`（View）．
  - `sample_postgres` サービス配下の総エンティティは修正前 816 → 修正後 **38**（検索 API の `service.displayName.keyword` 集計）に減った．集計軸を `entityType` 側で足し上げると `table` 5 + `tableColumn` 31 + `database` 1 + `databaseSchema` 1 = 38 で，これに `databaseService` 自身の 1 件を加えると 39 になる．**38 と 39 のどちらが「正しい」件数というより，集計軸（`service.displayName` 配下か，`databaseService` 自身も含めるか）で 1 件ずれる**という点に注意．
- DataHub の postgres source は設定なしでも `public` の 5 データセット（Table 3 / View 2）のみを取り込み，`information_schema` 等のシステムスキーマは既定で除外された．
- 評価としては，追加設定なしでシステムスキーマのノイズが混入しない DataHub の既定挙動の方が，このラボのような「まず動かして中身を見る」用途では親切だった．ただし一方向に優劣を決めつけるべきではない．OpenMetadata は既定で何も隠さないため，取り込み対象がフィルタなしでそのまま見え，本来取り込みたいものが漏れているという種類の取りこぼしには気づきやすい．DataHub は既定で除外する分セットアップは楽だが，「何が除外されているか」を利用者側が意識しにくいという裏返しの側面がある．今回はシステムスキーマの除外が「望ましい既定」だったが，逆に除外してほしくない対象まで既定で弾かれるケースもありうるため，DataHub 側でも `schema_pattern` 等のフィルタ設定を都度確認する必要がある点は変わらない．

**OpenMetadata**
- 検索 API（`/api/v1/search/query?q=customers&index=table_search_index`）で 4 件ヒット．
- 検索結果のレスポンス中，`customer_id` カラムの `description` に `COMMENT ON COLUMN` で書いた日本語コメント（「顧客 ID（主キー）．」）がそのまま入っていることを確認した．
- リネージ API（`/api/v1/lineage/table/name/{fqn}?upstreamDepth=2&downstreamDepth=1`）で `customer_order_summary` の上流に `customers` / `orders` / `order_items` の 3 テーブルを確認．各エッジの `lineageDetails.columnsLineage` を数えると，カラム単位の対応は合計 7 件（`customers` から 3 件，`orders` から 2 件，`order_items` から 2 件）．

**DataHub**
- 検索 API（`POST /entities?action=search`，`entity: dataset`）で `customers` 4 件ヒット（内訳 Table 2 / View 2）．
- インジェスト実行時のログに出る Aspect 集計表で，Table 3 件・View 2 件・Database container 1 件・Schema container 1 件・query（ビュー定義から生成された SQL クエリエンティティ）2 件を確認．sink（`datahub-rest`）の report では合計 45 イベントを書き込んだと報告された．
- `GET /aspects/{urn}?aspect=upstreamLineage&version=0` で `customer_order_summary` の上流に `customers` / `orders` / `order_items` の 3 データセットを確認．`fineGrainedLineages` は 6 件（`customer_id` / `customer_name` / `country` / `total_orders` / `total_spent` / `last_order_date` の各出力カラムに 1 件ずつ．`total_spent` は `quantity` と `unit_price` の 2 カラムを 1 件の `fineGrainedLineages` エントリにまとめて持つ）．

両ツールとも列単位のリネージまで取れていたが，**API レスポンスでの表現形式が違う**点は実際に叩いて初めて分かった実測ベースの発見だった．OpenMetadata は「上流テーブルごとのエッジ」に列マッピングをぶら下げる形（同じ出力カラムでも上流テーブルが違えば別エントリになりうる）で，今回の 7 件という数字はこの数え方によるもの．DataHub は「出力カラムごと」に 1 エントリを持ち，複数の上流カラムをまとめて 1 エントリの `upstreams` 配列に入れる形（6 件という数字はこの数え方）．同じ実データ・同じビュー定義から生成されているのに，件数の数え方が違う点は，両ツールのリネージ結果を機械的に突き合わせる場合の注意点になる．

**検証していないこと**: `order_details`（もう一方のビュー）についてはリネージ API を個別に叩いていない．OpenMetadata 側はメタデータ取り込みログでテーブル・ビューとして処理されたことのみ確認し，DataHub 側は Aspect 集計表で View 2 件・query 2 件が処理されたことから両ビューにリネージが生成された可能性は高いが，`order_details` を対象にした API 呼び出しでの個別確認はしていない．また DataHub 側の `datasetProperties`（description に相当）についても，書き込まれた件数（Table 3 / View 2）は Aspect 集計表で確認したが，**中身の文字列を API で取得して `COMMENT ON` の内容と突き合わせる確認はしていない**．OpenMetadata 側は前述の通り `description` の文字列そのものを確認済みであり，この点は両ツールで確認の深さが揃っていない．

## ポート衝突とリソース

OpenMetadata と DataHub は既定設定のまま同時に起動すると 3306（mysql），9200（Elasticsearch／OpenSearch），8080（OpenMetadata の ingestion＝Airflow webserver／DataHub の gms）の 3 ポートが衝突する．本リポジトリでは `OM_ALT_PORTS=1` / `DATAHUB_ALT_PORTS=1` でホスト側ポートをずらせるようにしてあり，UI ポート（OpenMetadata 8585 / DataHub 9002）はどちらの回避策でも変更しない．

今回の検証では両スタックを**同時に起動して動かす実機確認はしていない**（メモリの制約もあり，方針としても行わない）．`DATAHUB_ALT_PORTS=1` 時のポート組み替え（GMS が 8080→28080 になり，インジェスト recipe の接続先もそれに追従すること）は，`datahub/scripts/lib.sh` の `dh_compose_files()` の出力を実行して機械的に確認した．OpenMetadata 側の `OM_ALT_PORTS=1` および両スタック同時起動そのものについては，このドキュメント作成時点で改めての実機検証はしていない．
