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
├── examples/               # 検証用のサンプルデータ・メタデータ定義（両ツール共通）
├── docs/
│   └── comparison.md       # OpenMetadata と DataHub の比較結果
└── plans/                  # 実装計画
```

スタックの起動は compose が担い，Containerfile は公式イメージを `FROM` する拡張レイヤ（インジェスト用）に専念させる．

## 前提環境

- [Podman](https://podman.io/)
- [podman-compose](https://github.com/containers/podman-compose)（または Podman の compose 互換コマンド）

## 使い方

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

### 停止する

```sh
./openmetadata/scripts/down.sh
./datahub/scripts/down.sh
```

ボリュームごと消す場合は `--purge` を付ける．

> 両ツールはポート（8080 / 9200 / 3306）とメモリを取り合うため，同時には起動しない．

## 比較検証

各ツールの検証観点・結果は [docs/comparison.md](docs/comparison.md) を参照．
