# 実装計画: データレイク（メダリオン + parquet）のサンプルデータセット

作成日: 2026-09-05
対象: Issue #1「examples: S3互換オブジェクトストレージ上のparquetファイルをモチーフにしたサンプルデータセットの作成」
状態: **検討中**．3.1（ストレージ = MinIO）は決定．
3.2（リネージの取り方・変換エンジン）は推奨案あり，未確定．
更新: 2026-09-08

## 1. 背景

Issue #1 の要求は次の通り．

- オブジェクトストレージ上にメダリオンアーキテクチャ（bronze / silver / gold）を採用した
  データレイクを模したサンプルデータセットを作る．
- OpenMetadata と DataHub が**データレイクに対しても十分に使えるか**を検討する材料にする．
- オブジェクトストレージ: MinIO（配布終了のため Garage や SeaweedFS でも可）．
- ファイルフォーマット: parquet．

既存の `examples/postgres`（RDB のサンプル）に対して，**もう一つ別系統の例を足す**という位置づけ．

## 2. 調査結果

各項の見出しに，実測かドキュメント調査かと日付を明記する（4 章と対応）．

### 2.1 オブジェクトストレージのイメージ（実測・2026-09-05）

| 候補 | 実測 | arm64 |
| --- | --- | --- |
| `minio/minio`（Docker Hub） | 最新タグは `RELEASE.2025-09-07T16-13-09Z`．以降更新なし | あり |
| `quay.io/minio/minio` | `RELEASE.2025-09-07T16-13-09Z.hotfix.7aa24e772`（2026-04 更新）等の hotfix ビルドあり | 未確認 |
| `dxflrs/garage` | `v2.3.0` / `v1.3.1` など版数タグあり．現役で配布中 | あり |
| `chrislusf/seaweedfs` | タグは多数あるが，最近のものは署名（`.sig`）が上位に並ぶ．版数タグの確認は未実施 | 未確認 |

**「MinIO の Docker イメージ配布が終了した」という Issue の認識は概ね正しいが，
既存イメージが消えたわけではない．** 新規リリースの Docker Hub への配布が
2025-09-07 で止まっている，というのが実態．タグを固定すれば今も pull できる．

### 2.2 両ツールの S3 / データレイク対応（実測・2026-09-05）

どちらも **Spark 不要**で，pandas / pyarrow ベースだった．既存の
`Containerfile.ingestion` を拡張する方式にそのまま載る．

| | extra | 主な依存 |
| --- | --- | --- |
| OpenMetadata | `openmetadata-ingestion[datalake-s3]` | pandas / numpy / pyarrow / s3fs / boto3 / fastavro |
| DataHub | `acryl-datahub[s3]`（`s3-slim` もある） | boto3 / pyarrow / smart-open / tableschema / wcmatch |

DataHub 側に `pyspark` や `pydeequ` は**含まれていない**．
ドキュメントで裏が取れた（2026-09-07）: `s3` ソースのプロファイリングは
pyarrow + Apache DataSketches の純 Python 実装になっており，
Spark / Hadoop / PyDeequ / JVM のいずれも不要．

### 2.3 S3 互換エンドポイントの指定（実測・2026-09-05）

OpenMetadata の `AWSCredentials` に `endPointURL` フィールドが存在することを
実機で確認した（`awsAccessKeyId` / `awsSecretAccessKey` / `awsRegion` /
`endPointURL` など）．MinIO や Garage を向けられる．

DataHub 側も `s3` ソースの `aws_config.aws_endpoint_url` で同じことができる
（ドキュメント・2026-09-07 に追記）．`iceberg` ソースの場合は
`catalog.<name>.s3.endpoint`．実機での疎通は未確認．

### 2.4 リネージが保持する情報（ドキュメント調査・2026-09-06）

「Bronze → Silver の前処理（型変換・名寄せ）の内容は残るのか」という問いへの回答．
**リネージが持つのは 3 層で，3 層目に「何をしたか」を書く箱はあるが，
自動では埋まらない．**

| 層 | 中身 | 例 |
| --- | --- | --- |
| テーブル間の辺 | 「繋がっている」だけ | `bronze/orders` → `silver/orders` |
| カラム間の辺 | どの入力カラムから出来たかの対応 | `first_name`,`last_name` → `full_name` |
| 辺に付く自由記述 | **ここが「何をしたか」** | `"CONCAT(first_name,' ',last_name)"` |

3 層目の箱は両ツールとも持つ．

- OpenMetadata: `lineageDetails.columnsLineage[].function`（`"CAST(customer_id AS BIGINT)"`
  のような文字列）．辺全体に `sqlQuery` と `pipeline` 参照も付く．
- DataHub: `FineGrainedLineage.transformOperation`
  （SDK v2 の `add_dataset_transform_lineage(transformation_text=...)`）．
  変換処理を DataJob エンティティとして立てることもできる．

**自動で埋まるのは SQL があるときだけ．** `function` / `transformOperation` を
埋めるのは両ツールとも SQL パーサであり，`examples/postgres` でビュー定義から
リネージが取れたのはこれ．parquet には SQL がないため，Datalake / S3 コネクタが
吸うのはスキーマだけで，**リネージは辺すら生成されない**（3.2 の前提）．

**名寄せは表現しきれない．** 型変換は `function` に式を書けば意味が通るが，
名寄せ（entity resolution）は行レベルの統合なので，カラムのマッピングでは
原理的に表現できない．`n:1` の辺に `"fuzzy match on name+address"` と自由文を
添える程度が限界で，そこから先は description / ドキュメントの領域．
カタログツールの守備範囲外と割り切る．

### 2.5 スキーマ変更履歴（リネージとは別機能・ドキュメント調査・2026-09-06）

「新しいカラムが追加された」はリネージではなくスキーマ変更履歴の担当で，
**両ツールとも専用機能を持つ**．

| | 機能 | 粒度 |
| --- | --- | --- |
| DataHub | Timeline API（`/openapi/v2/timeline/v1/{urn}?categories=TECHNICAL_SCHEMA`）と，その上の Schema History タブ | 列の追加・削除・型変更・リネームを追い，**後方/前方互換かどうかまで判定する**（`ADD ... A forwards & backwards compatible change`） |
| OpenMetadata | エンティティのバージョン履歴（Versions タブ） | スキーマ差分を版として保持 |

DataHub の互換性判定は一歩踏み込んでおり，**ここは良い比較材料になる**．
3.5 の「スキーマ進化をシナリオに含めるか」はこれに直結する．

### 2.6 自動リネージが成立する経路（ドキュメント調査・2026-09-06）

2.4 の「自動で埋まるのは SQL があるときだけ」をより正確に言うと，
**「カタログが読める場所に SQL があるときだけ」**．経路は 3 つしかない．

| 経路 | 仕組み | 備考 |
| --- | --- | --- |
| コネクタが接続先の query history / view 定義を読む | Snowflake・BigQuery・Postgres など**稼働中のサービス**に接続してログを舐める | `examples/postgres` のリネージはこれ |
| dbt の `manifest.json` を読む | 両ツールとも dbt コネクタあり．OpenMetadata は `dbt compile` で `compiled_code` を埋めた manifest を要求する | 変換を SQL モデルとして書く必要がある |
| オーケストレータのプラグインが実行時に emit する | Dagster: `acryl_datahub_dagster_plugin` / `openmetadata-ingestion[dagster]`．Airflow も両ツール対応 | 変換の実装言語を問わない |

**DuckDB は 1 番目に該当しない．** 埋め込みプロセスなので，スクリプトが終われば
SQL はどこにも残らず，コネクタが読みに来る先がない．
つまり **polars から DuckDB に替えてもリネージは自動にならない**（3.2 参照）．

**Airflow 経路には公平性の落とし穴がある（本リポジトリの compose で確認）．**
`openmetadata/compose.upstream.yml` は `ingestion` サービスとして Airflow を
同梱している（`AirflowRESTClient`，`AIRFLOW_*` env，DAG 用ボリューム）が，
`datahub/compose.upstream.yml` に Airflow は含まれない．
Airflow を使うと OpenMetadata だけ「既にあるものに DAG を置くだけ」になり，
**連携能力の差ではなくスタック構成の差**が結果に混ざる．

### 2.7 複数 parquet を 1 テーブルとして束ねられるか（ソース調査・2026-09-07）

「`silver/orders/dt=2024-01-01/part-0.parquet` のような Hive 形式のファイル群を，
1 つのテーブルとして認識できるか」への回答．
**両方できるが，やり方が非対称で，OpenMetadata はコネクタの選択を誤ると破綻する．**

#### DataHub: `path_specs` の `{table}` で束ねる

`{table}` が「データセットになるフォルダ」を指し，その配下は何ファイルあっても 1 データセット．

```yaml
source:
  type: s3
  config:
    path_specs:
      - include: "s3://lake/silver/{table}/**"   # ** で Hive パーティションを自動検出
    aws_config:
      aws_endpoint_url: "http://minio:9000"      # S3 互換エンドポイント指定．存在を確認した
      aws_access_key_id: ...
      aws_region: us-east-1
```

`path_spec.py` で確認した既定値が挙動を決めている．

| 項目 | 既定 | 意味 |
| --- | --- | --- |
| `autodetect_partitions` | `true` | `dt=2024-01-01` 形式をパーティションキー/値として自動認識 |
| `traversal_method` | `MAX` | **最大値のパーティションフォルダしか辿らない**（`ALL` / `MIN_MAX` も選べる） |
| `sample_files` | `true` | 全列挙せずサンプルからスキーマ推論．ファイル数・サイズ集計は無効化される |

パーティションは `{partition_key[0]}={partition_value[0]}/` の形で明示指定もできる．

#### OpenMetadata: コネクタ選択で挙動が割れる

**Datalake コネクタ（Database service）では束ねられない．**
`datalake/metadata.py` の `get_tables_name_and_type` は `list_objects_v2` で
**オブジェクトキーを 1 件ずつ列挙し，各キーをそのまま 1 テーブルとして yield** している．
パーティションが増えるほどテーブルが増える．バケット内の `openmetadata.json` も
参照はするが，用途は拡張子のないファイルのフォーマット判定だけ．

**S3 Storage コネクタ（Storage service）なら束ねられる．**
`openmetadata.json` マニフェストの 1 エントリ = 1 Container で，prefix 配下をまとめて扱う．

```json
{"entries": [
  {"dataPath": "silver/*", "depth": 1, "structureFormat": "parquet",
   "isPartitioned": true, "autoPartitionDetection": true}
]}
```

`containerMetadataConfig.json`（main）で確認した仕様は次の通り．

- `dataPath` はグロブ（`*` / `**` / `?`）可．`depth` と併せて 1 エントリを複数コンテナに展開できる．
- `autoPartitionDetection` で Hive 形式を自動検出，`partitionColumns` で明示定義（自動検出を上書き）．
- `excludePaths` の既定で `_delta_log` / `_temporary` / `_spark_metadata` / `.tmp` / `_SUCCESS` を除外．
- スキーマは prefix 配下の**サンプル 1 ファイル**から取る（`list_objects_v2` の先頭 1000 件から選ぶ）．
- マニフェストはバケット直下のほか，ローカル / HTTP / 別 S3 からのグローバルマニフェストも指定できる．

#### この差が比較材料になる

1. **束ねるコストが非対称．** DataHub は ingestion 側の設定 1 行，OpenMetadata は
   **データレイク側にマニフェストファイルを置く**（＝レイクの書き手に手を入れる）．
   実運用での受け入れやすさに直結する．
2. **エンティティ型が違う．** DataHub は Dataset，OpenMetadata は Table ではなく **Container**．
   リネージやプロファイリングが Container でどこまで効くかは未確認で，
   3.2（案 A のリネージ手動登録）の前提に直接響く．
3. **どちらも全ファイルのスキーマをマージしない．** 代表 1 ファイル（DataHub はサンプル数ファイル）
   からの推論なので，ファイル間でスキーマが違っても片方しか見えない．
   DataHub の `traversal_method: MAX` は最新パーティションだけを見るため，
   2.5 のスキーマ進化シナリオとは相性が良い反面，古い列の消失は拾わない可能性がある．

### 2.8 テーブルフォーマット（Iceberg / Delta Lake）に逃げられるか（ソース調査・2026-09-08）

2.7 の「束ね方が人手の指示頼み」を Iceberg で構造的に解決できないか，という検討．
**結論: DataHub には効くが，OpenMetadata が Iceberg コネクタを削除したため比較が成立しない．**

**OpenMetadata は Iceberg 対応をやめた．**
PR [#26365 "Chore: Remove iceberg standalone connector"](https://github.com/open-metadata/OpenMetadata/pull/26365)
が 2026-04-02 にマージ済み．`pyiceberg` 依存ごと削除され，既存の Iceberg サービスは
マイグレーションで `CustomDatabase` に移送される．タグで確認したところ
`1.12.14-release` には `ingestion/.../database/iceberg/` があり，
`1.13.0-release` / `2.0.1-release` には無い．PR に入った代替は
「他の対応 DB 上の Iceberg テーブルの型判定改善」であり，方針は
**「Iceberg は REST カタログを直接読まず，Snowflake / Databricks / Glue / Trino
などエンジン経由でカタログする」**に変わったと読める．

**DataHub の `iceberg` ソースは現役**で，parquet 直置きの弱点を潰している．

| | Hive 形式 parquet（`s3` ソース） | Iceberg（`iceberg` ソース） |
| --- | --- | --- |
| テーブルの束ね方 | `path_specs` の `{table}` で人間が指示 | テーブルメタデータが定義．指示不要 |
| スキーマ | サンプルファイルから推論 | テーブルメタデータから取得．推論なし |
| パーティション | パスから自動検出（既定 `MAX`） | partition-spec をそのまま custom property に |
| プロファイル | pyarrow でデータを読む | **manifest の統計を集計．データを読まない**（行数・null 数・min/max） |
| リネージ | 無し | **無し** |

カタログは rest / hive / glue / sql に対応し，MinIO は `s3.endpoint` で向けられる．

```yaml
source:
  type: iceberg
  config:
    catalog:
      demo:
        type: rest
        uri: "http://iceberg-rest:8181"
        s3.endpoint: "http://minio:9000"
```

**判断: 本線は Hive 形式 parquet を維持する．** 理由は 3 つ．

1. 両ツールが同じ土俵に乗る唯一の形式．一方が対応をやめた形式で比べても
   「OpenMetadata は 0 点」以上の情報が出ず，知りたいこと（レイク対応力の差）が測れない．
   OpenMetadata を土俵に乗せるには Trino 等のエンジンを 1 台足すことになり，
   2.6 の「連携能力の差ではなくスタック構成の差が混ざる」問題が逆向きに再発する．
2. **リネージ（3.2）は Iceberg でも解決しない．** Iceberg にも SQL は無いので，
   手動登録か dbt / Dagster という選択肢の構図は変わらない．
3. 2.7 の「束ね方の非対称性」自体が良い比較材料であり，これを消してしまうのは惜しい．

Iceberg は次のどちらかの扱いとする．

- **DataHub 単独の追加シナリオ**として小さく足す．「テーブルフォーマットを入れると
  DataHub 側はここまで楽になる」という材料になり，基盤側の技術選定への示唆にもなる．
- 基盤で Iceberg 採用が現実味を帯びた時点で，**カタログの選定より先に
  OpenMetadata の対応状況（Trino 経由になるか）を確認する**．採用可否そのものを左右する．

なお Delta Lake は OpenMetadata にも `deltalake` コネクタが残っているが，
対応は Metadata と dbt のみで Profiler / Lineage / Owners / Tags は非対応のため，
比較材料としては薄い．

## 3. 決定事項と未決事項

### 3.1 オブジェクトストレージ: MinIO（決定・2026-09-06）

**MinIO をタグ固定で使う．**

理由は「**現在 MinIO を運用中で慣れており，新しいツールによるノイズを受けない**」．
本検証の目的はデータカタログツールの評価であって，ストレージ側の S3 方言の差は
ノイズでしかない．Garage / SeaweedFS を持ち込むと，不具合を踏んだときに
「ツールの問題か，ストレージの問題か」の切り分けコストが乗る．

- タグ: `quay.io/minio/minio` の hotfix ビルド（2.1 参照）を第一候補，
  `minio/minio:RELEASE.2025-09-07T16-13-09Z` を代替とする．
  quay.io 側の arm64 対応は着手時に確認する．
- **エンドポイントと認証情報は env に外出しする．** 将来 MinIO が pull できなく
  なったときに Garage へ振り替えられる余地を残しておく．

### 3.2 メダリオン層間のリネージをどう扱うか

**これが最大の論点．** 2.4 の通り，parquet には SQL がないため
`examples/postgres` の「ビュー定義 SQL からリネージを自動生成」が使えず，
bronze → silver → gold のリネージは**何もしなければ両ツールとも取れない**．

| 案 | 何が検証できるか | 何が検証できないか / 懸念 |
| --- | --- | --- |
| A. DuckDB で変換し，リネージは各ツールの API で明示登録 | リネージ API の使い勝手の差（辺・カラム対応・`function` / `transformOperation` の書き味と，それが UI にどう出るか）．実際のパイプラインがやることに近い | ツールの自動検出能力は測れない．登録作業そのものが実装コストになる |
| B. dbt-duckdb で変換し，両ツールの dbt コネクタで manifest からリネージを取る | 自動でリネージが取れる可能性が高い．実務でよくある構成 | 検証対象が「レイク対応力」から「dbt 連携」にずれる．dbt 自体の依存と学習コストが増える |
| C. スキーマ取得だけ先に検証し，リネージは後回し | parquet がテーブルとして認識されるか，パーティションやスキーマ推論がどう見えるかを小さく確認できる | Issue の「十分に使えるか」への答えが半分になる |

**推奨は案 A + スキーマ進化シナリオ（2.5）．** 2.4 を踏まえると，案 A の
「登録作業が実装コスト」という欠点は見方が変わる．どのみち実運用でも自前で
入れることになる以上，**リネージ API の使い勝手の差そのものがこの検証で
一番知りたいこと**になりうる．案 B は自動化と引き換えに比較対象が
「dbt コネクタの出来」にずれ，3.1 で MinIO を選んだ理由（新しいツールの
ノイズを避ける）とも一貫しない．

案 A を採るなら，検証の観点は次の 3 つになる．

1. **登録の手間** — テーブル辺 / カラム辺 / 変換の自由記述を入れるまでの API 呼び出し数と型定義の重さ．
2. **UI への出方** — API に入れた `function` / `transformOperation` が実際に画面で読めるか．**入れても表示されないケースがありうるので，ここは実機で見ないと分からない．**
3. **スキーマ進化** — bronze に列を足したとき，DataHub の Schema History と OpenMetadata の Versions タブでどう見えるか．DataHub の互換性判定が効くかどうか．

#### 3.2.1 変換エンジンの選択: polars を継続（推奨）

変換は **Python + polars のまま**でよい．DuckDB / dbt / Dagster / Airflow への
乗り換えは，このラボの目的に対して割に合わない．

| 案 | リネージ | 追加で背負うもの |
| --- | --- | --- |
| **polars + API 手動登録** | 手動 | なし |
| DuckDB + API 手動登録 | 手動（2.6 より自動にならない） | 書き慣れた polars を捨てる．**得るものがない** |
| dbt-duckdb | 自動（manifest） | 変換を SQL に書き直す．dbt の依存と学習コスト |
| Dagster | 自動（プラグイン）．polars のまま使える | Dagster プロセス．両ツール分のプラグイン設定 |
| Airflow | 自動 | Airflow 一式．重い．加えて 2.6 の公平性の問題 |

判断の根拠は「**ラボが基盤の技術選定を先に固定してはいけない**」．
このリポジトリの目的はカタログツールの比較であって，データ基盤の設計ではない．
データレイクの詳細が未確定で polars でスモールスタートしている現状では，
ラボもその現実を写した方が，比較結果がそのまま実際の判断材料になる．

Dagster は「polars のまま自動リネージが取れる」点で筋は悪くないので，
**基盤側で Dagster を採用したときに再検討する**．道は塞がない（下記）．

#### 3.2.2 案 A を採る場合の構成

**ツール中立なリネージ記述を自前で 1 枚持つ．**

```
examples/datalake/
├── transform/        # polars の変換．bronze -> silver -> gold
├── lineage.yml       # 中立な記述: どの列がどの列から，どう作られたか
└── register/
    ├── openmetadata.py   # lineage.yml -> OM の lineageDetails
    └── datahub.py        # lineage.yml -> DataHub の FineGrainedLineage
```

利点は 3 つ．

1. **比較が綺麗になる** — 同じ入力・2 つのアダプタなので，差分がそのまま
   リネージ API の手間の差になる（3.2 の観点 1）．
2. **変換コードにツールの API が混ざらない** — どちらかのツールを捨てても
   他方が壊れない．
3. **将来の移行で捨てずに済む** — dbt や Dagster に移っても `lineage.yml` の
   供給元が変わるだけ．さらに，自動で取れたリネージと手書きの `lineage.yml` を
   突き合わせれば「**自動検出の取りこぼし**」を測れる．今やる話ではないが，
   将来の比較材料として道を残せる．

### 3.3 `examples/` のディレクトリ構成

現状は `examples/sample-data/`（DDL・INSERT）と `examples/postgres/`（compose）に
分かれているが，`sample-data` という名前は PostgreSQL 例の一部でしかない．
データレイク例を足すなら次のどちらかに整理する必要がある．

- 案 1: `examples/postgres/` 配下に `sample-data/` を移し，
  `examples/datalake/` を並べる．例ごとに subtree が閉じる．
- 案 2: `examples/sample-data/` は「共通の元データ」として残し，
  そこから RDB とレイクの両方を作る．

**案 2 には副次的な利点がある**（3.4 を参照）が，
既存の `examples/README.md` と `openmetadata` / `datahub` 側のパス参照に
影響するので，どちらにするかは決めてから着手したい．

### 3.4 既存の PostgreSQL 例と繋げるか

bronze 層を「`examples/postgres` の RDB から吸い出した生データ」という設定にすると，
**RDB → データレイクをまたぐリネージ**という比較観点が増える．
実務のデータ基盤に近く，カタログツールの評価としては価値が高い．

一方で，2 つの例が密結合になり「レイクだけ試したい」ができなくなる．
`examples/postgres` を止めるとレイク例も再現できない，という依存も生まれる．

独立させるか繋げるかは，Issue の目的に照らして決めたい．

### 3.5 データセットの設計（決めることの一覧）

以下は 3.1〜3.4 が決まってから詰める．

- bucket と prefix の切り方（`bronze/` `silver/` `gold/` を prefix にするか bucket ごと分けるか）
- パーティションを入れるか（Hive 形式の `dt=2024-01-01/` など）．
  2.7 の通り両ツールとも自動検出の仕組みを持つ．**UI にどう出るかは未確認**だが，
  仕組みの差（DataHub は既定で最新パーティションのみ走査）は既に比較材料になる．
- 「1 ファイル = 1 テーブル」か「prefix 配下の複数ファイル = 1 テーブル」か．
  → 2.7 で解決．束ねるなら OpenMetadata は **Storage コネクタ + マニフェスト**が必須で，
  Datalake コネクタでは 1 ファイル = 1 テーブルにしかならない．
  **どちらのコネクタで比較するかを決める必要がある**（両方試すのが理想）．
- スキーマ進化（bronze に列が増える）をシナリオに含めるか．

## 4. 確認済みのこと / 未確認のこと

意思決定の前提を取り違えないよう明示的に分ける．

**確認済み（実機・API で確認した）**
- MinIO / Garage のイメージ存在と arm64 対応．MinIO の更新停止時期．
- `openmetadata-ingestion[datalake-s3]` と `acryl-datahub[s3]` の依存内容．Spark 非依存であること．
- OpenMetadata の `AWSCredentials` に `endPointURL` があること．
- `openmetadata/compose.upstream.yml` が Airflow を同梱し，
  `datahub/compose.upstream.yml` は同梱しないこと（2.6 の公平性の論点）．

**ドキュメントで確認した（実機未検証）**
- 両ツールのリネージのデータモデルと，変換内容を書く箱の有無（2.4）．
  OpenMetadata `lineageDetails.columnsLineage[].function` / `sqlQuery`，
  DataHub `FineGrainedLineage.transformOperation` / DataJob．
- 変換内容の自動抽出は SQL パーサ由来であり，parquet では働かないこと（2.4）．
- 両ツールのスキーマ変更履歴機能（2.5）．DataHub Timeline API の互換性判定．
- 自動リネージが成立する 3 経路（2.6）．両ツールに dbt / Dagster / Airflow の
  連携が存在すること．
- 複数 parquet の束ね方とパーティション認識の仕組み（2.7）．
  DataHub の `aws_endpoint_url`，`path_specs` の既定値，OpenMetadata の
  Datalake / S3 Storage 両コネクタの挙動差．いずれもコネクタのソースと
  JSON スキーマで確認した．
- OpenMetadata が Iceberg コネクタを 1.13.0 で削除したこと（2.8）．
  PR とリリースタグのファイル有無で確認した．

**未確認（推測で計画を進めない）**
- 2.7 の挙動が実機でその通りか（スキーマ推論の結果，パーティションの UI での見え方）．
- OpenMetadata の **Container エンティティ**でリネージ / プロファイリングが
  どこまで効くか（2.7）．Table 前提の 3.2 の計画に直接響く．
- OpenMetadata のドキュメントサイトに Iceberg のページが残って見えること（2.8）．
  コードは 1.13.0 以降に無いため，ドキュメントが古いのか別扱いなのかは未確認．
- SeaweedFS の版数タグ・arm64 対応・S3 互換性．
- ディスクとメモリの追加消費量（MinIO 自体は軽いが，parquet 生成と
  インジェスト時の pandas のメモリ使用量は未測定）．
- **API で登録した `function` / `transformOperation` が UI に表示されるか**
  （3.2 の観点 2）．データモデルに入ることと画面で読めることは別．
- Datalake / S3 コネクタで取り込んだ parquet に対し，スキーマ変更履歴
  （2.5）が実際に記録されるか．再インジェスト時に差分として拾うか．
- `quay.io/minio/minio` hotfix ビルドの arm64 対応．
- 両ツールに DuckDB コネクタが存在しないこと（ドキュメント検索では
  見つからなかったが，「無い」ことの確認はしていない）．
  ただし 2.6 の通り，仮にあっても埋め込み DB の query history は
  読めないため結論は変わらない．

## 5. 次のアクション

1. ~~3.1（ストレージ）の方針を決める~~ → MinIO で決定（2026-09-06）．
2. 3.2 の推奨案（案 A + スキーマ進化）を採るか決める．**ここが決まらないと
   データセットの設計（3.5）が決まらない．**
   変換エンジンは polars 継続を推奨（3.2.1），構成は 3.2.2 の形を推奨．
3. 決まったら 3.3 / 3.4 を確定させ，本ファイルに実装ステップ表（`jj` の
   論理単位ごと）を追記する．
4. 着手前に，未確認項目のうち次の 3 つは小さく実機検証しておくと手戻りが減る．
   - 2.7 の束ね方が実機で再現するか（DataHub の `path_specs`，
     OpenMetadata の S3 Storage コネクタ + マニフェスト）
   - OpenMetadata の Container でリネージが張れるか（案 A の前提）
   - リネージ API に入れた変換記述が UI に出るか（案 A を採る場合，
     ここが出ないと検証の観点 2 が成立しない）
