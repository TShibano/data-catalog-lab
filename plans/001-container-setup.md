# 実装計画: OpenMetadata / DataHub の Podman 環境構築

作成日: 2026-09-05
最終更新: 2026-09-05（8 章: OpenMetadata のインジェスト範囲の修正計画を追記）
対象: Containerfile・Compose 定義・補助スクリプトの整備

## 1. 現状と調査結果

### リポジトリ
- `README.md` `CLAUDE.md` `plans/` のみ．実装用のディレクトリはいずれも未作成．

### ローカル環境（実測・2026-09-05 更新後）
| 項目 | 実測値 | 判定 |
| --- | --- | --- |
| podman | 6.1.1（darwin/arm64，provider: libkrun） | OK |
| podman machine | CPU 4 / Memory 9.312GiB / Disk 22GiB（うち空き 20GiB），起動中 | OK（ディスクのみ注意） |
| podman-compose | 1.6.0（Homebrew，`/opt/homebrew/bin/podman-compose`） | OK |
| `podman compose` | 上記 podman-compose を external provider として委譲 | OK |
| docker / docker-compose | 未インストール（`~/.docker/cli-plugins` は Docker Desktop 削除済みの壊れた symlink） | — |

### 各ツールの公式要件（2026-09 時点）
| | OpenMetadata | DataHub |
| --- | --- | --- |
| 最新版 | 2.0.1 | 1.7.0 |
| 配布形態 | GitHub Release の `docker-compose.yml` / `docker-compose-postgres.yml` | `datahub docker quickstart`（実体は `docker/quickstart/docker-compose.quickstart-profile.yml`） |
| 主要サービス | server / ingestion(Airflow) / MySQL(or PostgreSQL) / Elasticsearch | GMS / frontend-react / actions / MySQL / OpenSearch / Kafka broker ほか計 14 コンテナ |
| UI ポート | 8585 | 9002（初期ユーザ datahub / datahub） |
| 要求リソース | 6GiB / 4vCPU | 8GB RAM / 2CPU / 13GB disk |

- イメージの arm64 対応は確認済み（`openmetadata/server`，`openmetadata/ingestion`，`acryldata/datahub-gms`，`acryldata/datahub-frontend-react` すべて `linux/arm64` あり）．Apple Silicon でエミュレーションなしで動く見込み．

## 2. 方針

### 2.1 Containerfile と Compose の役割分担
両ツールとも「複数サービスから成るスタック」であり，公式イメージをゼロから作り直す意味はない．そこで役割を分ける．

- **Compose 定義**: 公式の compose ファイルをバージョン固定で取り込み，本リポジトリ向けの上書き（ボリューム名，ポート，メモリ制限）を別ファイルで重ねる．**スタックの起動はこちらが担う**．
- **Containerfile**: 公式イメージを `FROM` する薄い拡張レイヤとして，**インジェスト作業用のイメージ**を各ツール 1 つずつ用意する．検証用のレシピや追加コネクタを同梱したいので，ここは自前ビルドの価値がある．
  - `openmetadata/Containerfile.ingestion`: `FROM openmetadata/ingestion:2.0.1`．追加コネクタ（postgres / mysql / dbt など）と投入用定義を配置．
  - `datahub/Containerfile.ingestion`: `FROM python:3.11-slim` + `pip install 'acryl-datahub[…]'`．recipe を同梱して `datahub ingest -c` を実行する．

> 補足: 「Containerfile だけでスタック全体を立てる」構成は，DataHub の 14 コンテナ・OpenMetadata の 4 コンテナを手書きの `podman run` で繋ぐことになり保守できない．Compose 前提を維持し，Containerfile は拡張用途に限定する．これは他のツールのコンテナ実装でも一般的なやり方．

### 2.2 ディレクトリ構成の方針: 関心優先 → **ツール優先**

当初の `README.md` は関心優先（`compose/<tool>/`，`configs/<tool>/`，`scripts/<tool>/`）だったが，**ツール優先**（`<tool>/compose.yml`，`<tool>/configs/`，`<tool>/scripts/`）に変更する．

#### 決め手: Containerfile のビルドコンテキスト
Containerfile は**ビルドコンテキストの外を `COPY` できない**．関心優先のままだと `compose/openmetadata/Containerfile.ingestion` から `configs/openmetadata/` を取り込むために，compose 側でこう書くしかない．

```yaml
build:
  context: ../..                                        # リポジトリルート全体
  containerfile: compose/openmetadata/Containerfile.ingestion
```

ビルドコンテキストがリポジトリ全体に膨らみ，`examples/` のサンプルデータも `docs/` も `.jj/` も毎回転送される．`.containerignore` での除外が必須になる．`env_file` も `../../configs/openmetadata/openmetadata.env` と 2 段上に登る．

ツール優先なら関連ファイルが同じ subtree に収まり，こう書ける．

```yaml
build:
  context: .                      # openmetadata/ 配下だけ
  containerfile: Containerfile.ingestion
env_file: ./configs/openmetadata.env
```

`COPY configs/ /opt/ingestion/configs/` がそのまま通り，コンテキストも小さい．

#### 副次的な理由: 変更の軸がツールだから
本リポジトリの論理的な作業単位は `CLAUDE.md` にある通り「OpenMetadata のスタックを追加」「DataHub のスタックを追加」．ツール優先なら **1 つの `jj` change が 1 つのディレクトリ subtree に収まる**．関心優先だと 1 つの change が `compose/` `configs/` `scripts/` の 3 箇所に散る．ツールを 1 つ増やす・捨てる操作もディレクトリ 1 つで済む．

#### 関心優先の利点をどう埋めるか
「2 つの compose を並べて比較したい」は関心優先の利点だが，`diff -r openmetadata/ datahub/` で足りる．ディレクトリ構造で担保する必要はない．

#### ツール配下に寄せないもの
`examples/` は**両ツールに同じデータを取り込んで比較する**のが目的なので共有に置く．`docs/` `plans/` も同様．スクリプトの共通部分は `shared/scripts/` に置く．

#### 見送った案
`tools/openmetadata/` のように 1 段挟む案もあるが，対象が 2 ツールならルート直下で十分．3 つ以上に増えてルートが騒がしくなったら再検討する．

### 2.3 スクリプトの方針
- podman machine の起動状態・メモリ・compose provider の有無を**起動前にチェックして落とす**（起動途中で OOM するのを防ぐ）．
- ツール固有のスクリプトは `<tool>/scripts/`，共通処理は `shared/scripts/common.sh` に寄せる．
- 公式 compose ファイルの取得はスクリプト化し，バージョンは `shared/scripts/versions.env` の 1 箇所で管理する．

## 3. 成果物のディレクトリ構成

```
data-catalog-lab/
├── openmetadata/
│   ├── compose.upstream.yml          # 公式 2.0.1 を取得してそのままコミット
│   ├── compose.override.yml          # ポート・ボリューム・メモリの上書き
│   ├── Containerfile.ingestion       # FROM openmetadata/ingestion:2.0.1
│   ├── configs/
│   │   ├── openmetadata.env          # DB / Elasticsearch / 認証まわりの環境変数
│   │   └── ingestion/*.yml           # インジェスト定義
│   └── scripts/{up,down,logs,status,ingest}.sh
├── datahub/
│   ├── compose.upstream.yml          # 公式 quickstart 1.7.0 を取得してそのままコミット
│   ├── compose.override.yml
│   ├── Containerfile.ingestion       # FROM python:3.11-slim + acryl-datahub
│   ├── configs/
│   │   ├── datahub.env
│   │   └── recipes/*.yml             # DataHub ingestion recipe
│   └── scripts/{up,down,logs,status,ingest}.sh
├── shared/
│   └── scripts/
│       ├── common.sh                 # 事前チェック・ログ出力・compose ラッパ
│       ├── versions.env              # OM_VERSION / DATAHUB_VERSION の一元管理
│       └── fetch-compose.sh          # 公式 compose を取得（両ツール対応）
├── examples/
│   ├── sample-data/                  # 検証用の CSV / DDL（両ツール共通）
│   └── postgres/                     # インジェスト対象のサンプル DB（compose 定義含む）
├── docs/
│   └── comparison.md
├── plans/
│   └── 001-container-setup.md        # 本ファイル
├── README.md
└── CLAUDE.md
```

`compose.upstream.yml` は公式配布物をそのまま置き，本リポジトリの都合は `compose.override.yml` にだけ書く．こうすると公式のバージョンアップ時に upstream 側を差し替えるだけで済み，差分も追いやすい．

## 4. 実装ステップ（jj の論理単位ごと）

各ステップを 1 つの `jj` change とし，開始前に `jj new` する．

| # | change | 内容 | 完了条件 |
| --- | --- | --- | --- |
| 0 | `docs: 実装計画を追加` | 本ファイル | — |
| 1 | `chore: 共通スクリプト基盤を追加` | `shared/scripts/**`，`.gitignore` | `bash -n` が通る．`fetch-compose.sh` で両ツールの compose を取得できる |
| 2 | `feat: OpenMetadata のスタックを追加` | `openmetadata/**` | `up.sh` 後に `http://localhost:8585` が 200 を返す |
| 3 | `feat: DataHub のスタックを追加` | `datahub/**` | `up.sh` 後に `http://localhost:9002` が 200 を返す |
| 4 | `feat: 検証用サンプルデータを追加` | `examples/**`，両ツールの `ingest.sh` とインジェスト定義 | 同一のサンプル DB を両ツールに取り込み，UI で検索・リネージを確認できる |
| 5 | `docs: 比較結果をまとめる` | `docs/comparison.md`，`README.md` の追記 | 観点表が埋まっている |

## 5. 主要ファイルの設計

### `shared/scripts/common.sh`
- `set -euo pipefail` 前提のユーティリティ．
- `require_podman()`: `podman` の存在確認．
- `ensure_machine()`: `podman machine list` を見て停止中なら起動，メモリが要求値未満なら**エラーで停止**し，再作成コマンドを案内する（自動で `podman machine rm` はしない）．
- `compose_cmd()`: `podman compose` → `podman-compose` の順に解決．どちらも無ければインストール手順を出して終了．
- `log_info` / `log_error`．

### `<tool>/scripts/up.sh`
1. `shared/scripts/common.sh` を読み込み事前チェック．
2. `compose.upstream.yml` が未取得なら `fetch-compose.sh` を呼ぶ．
3. `compose_cmd -f compose.upstream.yml -f compose.override.yml up -d`．
4. ヘルスチェック（UI ポートへの `curl` をリトライ）して URL を表示．

### `<tool>/scripts/down.sh`
- `down` のみ実行．`-v`（ボリューム削除）は `--purge` フラグを明示したときだけ有効にする．

### `<tool>/compose.override.yml`

compose の複数ファイル指定は「マージ」であって「後勝ち」ではない．公式仕様では次のように振る舞う．

| 属性 | マージ規則 |
| --- | --- |
| スカラー（`image` など） | 後のファイルで置換 |
| マッピング（`environment` など） | キー単位でマージ |
| シーケンス（一般） | **追記**（後のファイルの値を末尾に足す） |
| `ports` | `{ip, target, published, protocol}` の複合キーで一意判定．キーが違えば**追記** |
| `command` | 例外的に全体を置換 |
| `volumes` | target パスをキーに一意判定 |

つまり `ports` は，ホスト側ポートを変えると複合キーが変わるため**別エントリとして追記され，upstream 側の bind も残ってしまう**．
明示的に置き換えるには `!override` タグを使う．

```yaml
services:
  openmetadata-server:
    ports: !override
      - "18585:8585"
```

**検証結果（2026-09-05，podman-compose 1.6.0）**: `podman compose -f base.yml -f over.yml config` で確認した．

- タグなし → `8080:80` と `9090:80` の**両方**が出力される（仕様どおり追記）
- `ports: !override` → `9090:80` **のみ**が出力される

**podman-compose 1.6.0 は `!override` タグに対応している**ため，この方針で問題ない．
なお `!reset` タグは未検証．必要になった時点で同じ手順で確認する．

### `<tool>/Containerfile.ingestion`
- 公式イメージ／`python:3.11-slim` を土台にした薄い拡張．ビルドコンテキストは `<tool>/` なので `COPY configs/ …` がそのまま書ける．`ENTRYPOINT` はインジェストコマンドに寄せる．

## 6. リスクと未決事項

1. ~~podman machine のメモリ不足~~ **解消済み**（3.725GiB → 9.312GiB，podman も 6.1.1 へ更新）．
   ただし **disk 22GiB（空き 20GiB）** は，DataHub 単体で 13GB を要求するため両ツールのイメージを同居させると逼迫する．
   対応: ツールを切り替える際に `podman image prune` を挟む．足りなければ `podman machine set --disk-size` で拡張．
2. ~~podman-compose 未インストール~~ **解消済み**（Homebrew で 1.6.0）．
   `podman compose` は external provider としてこれを呼ぶ構成になった．
3. **DataHub quickstart compose と podman-compose の互換性**
   `--profile` オプション自体は podman-compose 1.6.0 に存在する（`--help` で確認済み）．
   残る懸念は `depends_on` の `condition: service_healthy` など Compose Spec の細部で，podman-compose は Docker Compose の別実装のため差異が出やすい．ステップ 3 の冒頭で検証し，詰まった場合の代替は次の順で試す．
   (a) `brew install docker-compose` して `podman compose` の provider を本家 Compose v2 に切り替える（互換性が最も高い）
   (b) profile を展開した compose を本リポジトリに固定する
   (c) 旧形式の quickstart ファイルを使う
4. **ポート衝突**
   OpenMetadata（8080 Airflow / 9200 ES / 3306 MySQL）と DataHub（8080 GMS / 9200 OpenSearch / 3306 MySQL）が重複する．
   方針: **既定では同時起動しない**．同時比較したい場合に備え，`compose.override.yml` でホスト側ポートをずらせるようにしておく．
   実装上の注意は 5.3 を参照（`ports` は素直に上書きできない）．
   → **この方針は Issue #3 で撤回した（2026-09-07）**．衝突しないポート割り当てを常時の既定にし，
   同時起動を正式に対応した．`plans/004-issue3-concurrent-startup.md` を参照．
5. **リソース同時消費**
   両スタック合計で 14GB 超のメモリを要求するため，同時起動は現実的でない．比較は「片方ずつ起動 → 観点を記録」の手順とする．
   → **これも Issue #3 で撤回した（2026-09-07）**．`podman machine` を 18GiB へ拡張することで
   同時起動できるようにした（実測の実メモリ使用量は約 10.4GB）．
6. **バージョン固定**
   OpenMetadata 2.0.1 / DataHub 1.7.0 を `versions.env` に固定．`latest` は使わない．

## 7. 補足: 環境まわりの小ネタ

- `podman compose` は実行のたびに `>>>> Executing external compose provider ... <<<<` を出す．
  `~/.config/containers/containers.conf` に次を書けば黙る．
  ```toml
  [engine]
  compose_warning_logs = false
  ```
- `~/.docker/cli-plugins/` に Docker Desktop 削除後の壊れた symlink が残っている．実害はないが掃除してよい．

## 8. 追加計画: OpenMetadata のインジェスト範囲をサンプルスキーマに限定する

追記日: 2026-09-05（ステップ 1〜5 完了後，UI で確認して判明）

### 8.1 問題

ステップ 4 で作った `openmetadata/configs/ingestion/postgres_metadata.yaml` は
スキーマの絞り込みを一切していないため，サンプル DB の `public` だけでなく
PostgreSQL の `information_schema` まで丸ごと取り込んでいた．
UI の Explore で `sample_postgres` サービスを開くと 816 件が並び，
検証対象のサンプルデータが埋もれてしまう．

実測した内訳（`/api/v1/search/query` の `entityType` / `databaseSchema.name` 集計）．

| 区分 | 件数 |
| --- | --- |
| `tableColumn` | 728 |
| `table` | 74（`public` 5 + `information_schema` 69） |
| `storedProcedure` | 11 |
| `databaseSchema` / `database` | 3 |
| 合計 | 816 |

スキーマ別では **`information_schema` 777 / `public` 36** で，
9 割以上がシステムスキーマのノイズだった．

### 8.2 これは比較の公平性も損なっている

DataHub 側は同じサンプル DB から **5 データセット（Table 3 / View 2）しか作っていない**．
DataHub の postgres source はシステムスキーマを既定で除外するが，
OpenMetadata は既定では除外しない，という**ツール間の挙動差**が原因．

現状は両ツールで取り込み範囲が揃っておらず，
`docs/comparison.md` の「取り込み結果」節は前提が非対称なまま比較している．
この観点自体が比較材料として価値があるので，
**挙動差を記録した上で，取り込み範囲を揃える**．

### 8.3 方針

`sourceConfig.config.schemaFilterPattern` で `public` のみを対象にする．
`DatabaseServiceMetadataPipeline` と `DatabaseServiceQueryLineagePipeline` の
どちらも `schemaFilterPattern` フィールドを持つことを実機で確認済み
（`model_fields` を直接確認．`databaseFilterPattern` / `tableFilterPattern` /
`storedProcedureFilterPattern` も同様に存在する）．

```yaml
sourceConfig:
  config:
    type: DatabaseMetadata
    schemaFilterPattern:
      includes:
        - "^public$"
```

`excludes` で `information_schema` を弾く書き方もあるが，**`includes` で
`public` だけを明示する**方を採る．検証用ラボとして対象が固定されており，
将来 upstream 側が別のシステムスキーマを返すようになっても影響を受けないため．

### 8.4 再インジェストの手順

`markDeletedTables` / `markDeletedSchemas` による論理削除に頼らず，
**ボリュームごと作り直して素の状態から入れ直す**．
既存エンティティが残ったままだと，フィルタが効いているのか
論理削除されただけなのかが検証時に切り分けられないため．

```sh
./openmetadata/scripts/down.sh --purge
./openmetadata/scripts/up.sh
./openmetadata/scripts/ingest.sh
```

### 8.5 検証を `ingest.sh` に埋める

独立したテストスイートは作らない方針なので，
`ingest.sh` の検証部分を「1 件以上ヒットすれば OK」から
**期待する件数の一致確認**に強くする．これで同種の取りこぼしを次から検出できる．

- `public` スキーマのテーブル総数が **5**（テーブル 3 + ビュー 2）であること．
- `sample_postgres` サービス配下に `information_schema` のスキーマが**存在しない**こと．
- `customer_order_summary` の上流が **3 件**であること（現状は 1 件以上で通してしまう）．

### 8.6 作業ステップ（jj の論理単位ごと）

| # | change | 内容 | 完了条件 |
| --- | --- | --- | --- |
| 6 | `docs: インジェスト範囲の修正計画を追記` | 本節 | — |
| 7 | `fix: OpenMetadata のインジェスト対象を public スキーマに限定` | `openmetadata/configs/ingestion/*.yaml`，`openmetadata/scripts/ingest.sh` | 再インジェスト後，`public` の 5 件のみが取り込まれ，`information_schema` が存在しない |
| 8 | `docs: システムスキーマの扱いの差を比較結果に追記` | `docs/comparison.md` | 8.2 の挙動差と，修正後の取り込み件数が反映されている |

### 8.7 DataHub 側について

DataHub の recipe は既定で `public` の 5 データセットのみを取り込めており，
**現時点で修正は不要**．ただし「既定で除外される」ことに依存している状態なので，
将来 `include_view_lineage` 以外の設定を触る際は取り込み範囲を再確認すること．
