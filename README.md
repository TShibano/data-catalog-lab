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

```
data-catalog-lab/
├── README.md
├── compose/
│   ├── openmetadata/   # OpenMetadata 用の Podman Compose 定義
│   └── datahub/        # DataHub 用の Podman Compose 定義
├── configs/            # 各ツールの設定ファイル
├── scripts/            # 起動・停止・データ投入などの補助スクリプト
├── examples/           # 検証用のサンプルデータ・メタデータ定義
└── docs/
    └── comparison.md   # OpenMetadata と DataHub の比較結果
```

## 前提環境

- [Podman](https://podman.io/)
- [podman-compose](https://github.com/containers/podman-compose)（または Podman の compose 互換コマンド）

## 使い方

### OpenMetadata を起動する

```sh
cd compose/openmetadata
podman-compose up -d
```

### DataHub を起動する

```sh
cd compose/datahub
podman-compose up -d
```

停止する場合は各ディレクトリで `podman-compose down` を実行する．

## 比較検証

各ツールの検証観点・結果は [docs/comparison.md](docs/comparison.md) を参照．
