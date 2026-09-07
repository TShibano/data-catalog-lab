# data-catalog-lab

データカタログツールを Podman コンテナ上に構築し，各ツールの機能や運用性を比較・検証するためのリポジトリ．


## 目的

- データカタログツールをそれぞれコンテナ環境で動かし，セットアップの手間や機能差を比較する．
- メタデータ収集（インジェスト），検索，リネージ表示など，データカタログとしての基本機能を実際に触って検証する．
- 検証結果を [docs/comparison.md](docs/comparison.md) にまとめる．

## データカタログツールの対象

- [OpenMetadata](https://open-metadata.org/)
- [DataHub](https://datahubproject.io/)）

## ディレクトリ構成

ツールごとにトップ階層を分け，compose 定義・設定・スクリプトをその配下にまとめる．
検証用のサンプルデータは両ツールで共有するためトップ階層に置く．

```
data-catalog-lab/
├── README.md
├── openmetadata/           # OpenMetadata 一式
│   ├── compose.upstream.yml    # 公式配布の compose（バージョン固定）
│   ├── compose.override.yml    # 本リポジトリ向けの上書き
│   ├── Containerfile.ingestion # インジェスト用の拡張イメージ
│   ├── configs/                # 設定ファイル・インジェスト定義
│   └── scripts/                # up / down / logs / status / ingest
├── datahub/                # DataHub 一式（構成は openmetadata/ と同じ）
├── shared/
│   └── scripts/            # 事前チェック・compose 取得などの共通スクリプト
├── examples/                # 検証用サンプルデータ（内容は examples/README.md 参照）
│   ├── sample-data/            # 検証用スキーマ・データ（DDL / INSERT，両ツール共通）
│   └── postgres/               # インジェスト対象のサンプル DB（compose 定義 + scripts）
├── docs/
│   └── comparison.md       # OpenMetadata と DataHub の比較結果
└── plans/                  # 実装計画
```

スタックの起動は compose が担い，Containerfile は公式イメージを `FROM` する拡張レイヤ（インジェスト用）に専念させる．

## 前提環境

- [Podman](https://podman.io/) **4.7 以上**
  （rootless で `host.containers.internal` を解決できる版．インジェストがサンプル DB へ到達するのに要る）
- [podman-compose](https://github.com/containers/podman-compose) **1.6.0 以上**，
  または `docker compose` **2.24 以上**（compose ファイルの `!override` タグを解釈できる版）
- `curl` / `python3` / `base64`（起動待機・インジェスト結果の検証に使う）

ディストリ同梱の podman / podman-compose は上記より古いことがある．
前提を満たしているかは次で確認できる（各 `up.sh` も起動前に同じ検査をする）．

```sh
./shared/scripts/preflight.sh
```

### リソース要件

両ツールは同時に起動できる．必要なメモリは各 `compose.override.yml` の `mem_limit` の合計から決めており，`up.sh` は起動前にこれを検査する（他方のスタックが起動中なら，自動的に同時起動用の要求値で検査する）．

| 起動する構成 | メモリ | ディスク（イメージ + ボリューム） |
| --- | --- | --- |
| OpenMetadata + サンプル DB | 6GB | 13GB |
| DataHub + サンプル DB | 8GB | 13GB |
| **両方 + サンプル DB（同時起動）** | **16GB** | **25GB** |

内訳（`mem_limit` の合計）は OpenMetadata 7g（mysql 1 + elasticsearch 2 + server 2 + ingestion 2），DataHub 8g（opensearch 2 + kafka 1 + gms 2 + frontend 1 + mysql 1 + actions 1），サンプル DB 0.5g で計 15.5g．残りは起動時のマイグレーションジョブ（`execute-migrate-all` / `system-update-quickstart`）の分．

macOS や Windows + Podman Desktop では，この要求を満たすように `podman machine` を広げておく（同時起動には **18GiB 以上**を推奨．要求 16GB に対して余裕を持たせた値）．

```sh
podman machine stop
podman machine set --memory 18432 --disk-size 60
podman machine start
```

不足したまま `up.sh` を実行すると，上と同じ手順を案内して停止する（スクリプトが machine を勝手に作り直すことはない）．Linux ネイティブ / WSL2 では物理メモリを増やせないため，不足していても警告のみで続行する．

### ポート割り当て

同時起動できるよう，ホスト側の公開ポートは衝突しない値で**固定**してある．起動方法による切り替えはない．

| ツール | サービス | 用途 | ポート | upstream 既定 |
| --- | --- | --- | --- | --- |
| OpenMetadata | openmetadata-server | UI / REST API | **8585** | 8585 |
| OpenMetadata | openmetadata-server | admin（healthcheck） | **8586** | 8586 |
| OpenMetadata | ingestion | Airflow UI | **18080** | 8080 |
| OpenMetadata | mysql | メタデータ DB | **13306** | 3306 |
| OpenMetadata | elasticsearch | 検索（HTTP） | **19200** | 9200 |
| OpenMetadata | elasticsearch | 検索（transport） | **19300** | 9300 |
| DataHub | frontend-quickstart | UI | **9002** | 9002 |
| DataHub | datahub-gms-quickstart | GMS API | **8080** | 8080 |
| DataHub | datahub-gms-quickstart | OpenTelemetry | **4319** | 4319 |
| DataHub | mysql | メタデータ DB | **23306** | 3306 |
| DataHub | opensearch | 検索（HTTP） | **29200** | 9200 |
| DataHub | kafka-broker | Kafka | **9092** | 9092 |
| 共通 | examples/postgres | サンプル DB | **5432** | 5432 |

割り当ての規則は次のとおり．

- UI と API のポートは upstream の既定を維持する（公式ドキュメントや `datahub` CLI の既定と食い違わせないため）．
- 衝突する裏方サービスは両方ともずらし，OpenMetadata は `1xxxx`，DataHub は `2xxxx` を接頭とする．番号を見ればどちらのツールか分かる．
- そのため **mysql や検索エンジンへホストから直接繋ぐときは upstream 既定のポートでは繋がらない**．この表を唯一の参照先とすること．

ポート番号は各 `compose.override.yml` にリテラルで書いてある（podman-compose 1.6.0 が `!override` タグ内で `${VAR}` を展開しない不具合があるため，変数に寄せられない）．スクリプトがホストから叩くポートだけは `shared/scripts/versions.env` にも定義しており，変更時はこの表と 2 箇所を手で揃える必要がある．

### 対応 OS

| 実行環境 | 対応 |
| --- | --- |
| macOS（`podman machine` 経由） | 対応．検証済み |
| Linux ネイティブ（rootless / rootful） | 対応 |
| Windows + WSL2（ディストリの中に Podman を入れる） | 対応．Linux ネイティブと同じ扱い |
| Windows + Podman Desktop（`podman machine`） | 対応．macOS と同じ扱い |
| Windows ネイティブ（Git Bash / MSYS2 / PowerShell） | **非対応** |

スクリプトは `podman machine` の有無で振る舞いを変える．OS 名では判定しない．

**Windows では WSL2 のディストリの中で実行すること．** Git Bash や MSYS2 から
直接動かすとパス変換で `podman run` のマウント指定が壊れるため対象外とし，
`preflight` が明示的にエラーで止める．

補足: rootless かつ cgroup v1 の環境では compose の `mem_limit` が無視される
（podman が警告を出して続行する）．メモリを取り合って OOM しやすくなるため，
cgroup v2 の環境を推奨する．

## 使い方

典型的な流れは「サンプル DB 起動 → 比較したいツールを起動 → インジェスト → （比較・確認） → 停止」．

### サンプル DB を起動する

インジェスト対象のサンプルデータ（`examples/sample-data/`）を投入した PostgreSQL を起動する．スキーマとデータの内容は [examples/README.md](examples/README.md) にまとめてある．OpenMetadata・DataHub のどちらのスタックとも別 compose プロジェクトなので，どちらを検証する場合でも先にこれを起動しておく．

```sh
./examples/postgres/scripts/up.sh
```

停止は次のとおり（`--purge` でボリュームごと削除）．

```sh
./examples/postgres/scripts/down.sh
```

### OpenMetadata を起動する

```sh
./openmetadata/scripts/up.sh
```

起動後 http://localhost:8585 を開く．

### DataHub を起動する

```sh
./datahub/scripts/up.sh
```

起動後 http://localhost:9002 を開く（初期ユーザ `datahub` / `datahub`）．

### 両方を同時に起動して比較する

ポートが衝突しないように固定してあるため，順に起動するだけで両方を同時に動かせる．先に「リソース要件」のメモリを満たしておくこと．

```sh
./examples/postgres/scripts/up.sh
./openmetadata/scripts/up.sh
./datahub/scripts/up.sh
```

起動後は http://localhost:8585 （OpenMetadata）と http://localhost:9002 （DataHub）を並べて開ける．インジェストも両方に対して実行できる．

```sh
./openmetadata/scripts/ingest.sh
./datahub/scripts/ingest.sh
```

2 つ目のスタックを起動するとき，`up.sh` は他方が起動中であることを検知して同時起動用の要求値（16GB / 25GB）で前提チェックを行う．

### インジェストする

サンプル DB を各ツールへ取り込み，検索・リネージ API で結果を検証する（内容は `docs/comparison.md` 参照）．サンプル DB とインジェスト対象のツールの両方が起動している必要がある．

```sh
./openmetadata/scripts/ingest.sh
./datahub/scripts/ingest.sh
```

### 状態確認・ログ

```sh
./openmetadata/scripts/status.sh
./openmetadata/scripts/logs.sh [service...]

./datahub/scripts/status.sh
./datahub/scripts/logs.sh [service...]
```

### 停止する

```sh
./openmetadata/scripts/down.sh
./datahub/scripts/down.sh
./examples/postgres/scripts/down.sh
```

ボリュームごと消す場合は `--purge` を付ける．

## 比較検証

各ツールの検証観点・結果は [docs/comparison.md](docs/comparison.md) を参照．
