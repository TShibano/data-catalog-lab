# 実装計画: OpenMetadata / DataHub の Podman 環境構築

作成日: 2026-09-05
対象: `README.md` のディレクトリ構成に沿った Containerfile・Compose 定義・補助スクリプトの整備

## 1. 現状と調査結果

### リポジトリ
- `README.md` と `CLAUDE.md` のみ．`compose/` `configs/` `scripts/` `examples/` `docs/` `plans/` はいずれも未作成．

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

- **Compose 定義**（`compose/<tool>/`）: 公式の compose ファイルをバージョン固定で取り込み，本リポジトリ向けに最小限の上書き（ボリューム名，ポート，メモリ制限）を行う．スタックの起動はこちらが担う．
- **Containerfile**: 公式イメージを `FROM` する薄い拡張レイヤとして，**インジェスト作業用のイメージ**を各ツール 1 つずつ用意する．検証用のレシピ・サンプルデータ・追加コネクタを同梱したいので，ここは自前ビルドの価値がある．
  - `compose/openmetadata/Containerfile.ingestion`: `FROM openmetadata/ingestion:2.0.1`．追加コネクタ（postgres / mysql / dbt など）と `examples/` の投入用定義を配置．
  - `compose/datahub/Containerfile.ingestion`: `FROM python:3.11-slim` + `pip install 'acryl-datahub[…]'`．`configs/datahub/recipes/*.yml` を同梱して `datahub ingest -c` を実行する．

> 補足: 「Containerfile だけでスタック全体を立てる」構成は，DataHub の 14 コンテナ・OpenMetadata の 4 コンテナを手書きの `podman run` で繋ぐことになり保守できない．README の Compose 前提を維持し，Containerfile は上記の用途に限定する．

### 2.2 スクリプトの方針
- `podman-compose` の有無・podman machine の起動状態・メモリ設定を**起動前にチェックして落とす**（起動途中で OOM するのを防ぐ）．
- ツール別のサブディレクトリに分け（`CLAUDE.md` の規約），共通処理は `scripts/lib/common.sh` に寄せる．
- 公式 compose ファイルの取得はスクリプト化してバージョンを 1 箇所（`scripts/lib/versions.env`）で管理する．

## 3. 成果物のディレクトリ構成

```
data-catalog-lab/
├── compose/
│   ├── openmetadata/
│   │   ├── docker-compose.yml            # 公式 2.0.1 を取得して配置
│   │   ├── docker-compose.override.yml   # ポート・ボリューム・メモリの上書き
│   │   └── Containerfile.ingestion
│   └── datahub/
│       ├── docker-compose.yml            # 公式 quickstart 1.7.0 を取得して配置
│       ├── docker-compose.override.yml
│       └── Containerfile.ingestion
├── configs/
│   ├── openmetadata/
│   │   ├── openmetadata.env              # DB / Elasticsearch / 認証まわりの環境変数
│   │   └── ingestion/*.yml               # インジェスト定義
│   └── datahub/
│       ├── datahub.env
│       └── recipes/*.yml                 # DataHub ingestion recipe
├── scripts/
│   ├── lib/
│   │   ├── common.sh                     # 事前チェック・ログ出力・compose ラッパ
│   │   └── versions.env                  # OM_VERSION / DATAHUB_VERSION の一元管理
│   ├── fetch-compose.sh                  # 公式 compose を取得（両ツール対応）
│   ├── openmetadata/{up,down,logs,status,ingest}.sh
│   └── datahub/{up,down,logs,status,ingest}.sh
├── examples/
│   ├── sample-data/                      # 検証用の CSV / DDL
│   └── postgres/                         # インジェスト対象のサンプル DB（compose 定義含む）
├── docs/
│   └── comparison.md
└── plans/
    └── 001-container-setup.md            # 本ファイル
```

## 4. 実装ステップ（jj の論理単位ごと）

各ステップを 1 つの `jj` change とし，開始前に `jj new` する．

| # | change | 内容 | 完了条件 |
| --- | --- | --- | --- |
| 0 | `docs: 実装計画を追加` | 本ファイル | — |
| 1 | `chore: 共通スクリプト基盤を追加` | `scripts/lib/common.sh`，`scripts/lib/versions.env`，`scripts/fetch-compose.sh`，`.gitignore` | `bash -n` が通る．`fetch-compose.sh` で両ツールの compose を取得できる |
| 2 | `feat: OpenMetadata の compose スタックを追加` | `compose/openmetadata/**`，`configs/openmetadata/**`，`scripts/openmetadata/*.sh` | `up.sh` 後に `http://localhost:8585` が 200 を返す |
| 3 | `feat: DataHub の compose スタックを追加` | `compose/datahub/**`，`configs/datahub/**`，`scripts/datahub/*.sh` | `up.sh` 後に `http://localhost:9002` が 200 を返す |
| 4 | `feat: 検証用サンプルデータを追加` | `examples/**`，両ツールの `ingest.sh` とインジェスト定義 | 同一のサンプル DB を両ツールに取り込み，UI で検索・リネージを確認できる |
| 5 | `docs: 比較結果をまとめる` | `docs/comparison.md`，`README.md` の追記 | 観点表が埋まっている |

## 5. 主要ファイルの設計

### `scripts/lib/common.sh`
- `set -euo pipefail` 前提のユーティリティ．
- `require_podman()`: `podman` の存在確認．
- `ensure_machine()`: `podman machine list` を見て停止中なら起動，メモリが要求値未満なら**エラーで停止**し，再作成コマンドを案内する（自動で `podman machine rm` はしない）．
- `compose_cmd()`: `podman-compose` → `podman compose` の順に解決．どちらも無ければインストール手順を出して終了．
- `log_info` / `log_error`．

### `scripts/<tool>/up.sh`
1. `common.sh` を読み込み事前チェック．
2. compose ファイルが未取得なら `fetch-compose.sh` を呼ぶ．
3. `compose_cmd -f docker-compose.yml -f docker-compose.override.yml up -d`．
4. ヘルスチェック（UI ポートへの `curl` をリトライ）して URL を表示．

### `scripts/<tool>/down.sh`
- `down` のみ実行．`-v`（ボリューム削除）は `--purge` フラグを明示したときだけ有効にする．

### `compose/<tool>/Containerfile.ingestion`
- 前述のとおり公式イメージ／`python:3.11-slim` を土台にした薄い拡張．`configs/<tool>/` 配下をコピーし，`ENTRYPOINT` はインジェストコマンドに寄せる．

## 6. リスクと未決事項

1. ~~podman machine のメモリ不足~~ **解消済み**（3.725GiB → 9.312GiB，podman も 6.1.1 へ更新）．
   ただし **disk 22GiB（空き 20GiB）** は，DataHub 単体で 13GB を要求するため両ツールのイメージを同居させると逼迫する．
   対応: ツールを切り替える際に `podman image prune` を挟む．足りなければ `podman machine set --disk-size` で拡張．
2. ~~podman-compose 未インストール~~ **解消済み**（Homebrew で 1.6.0）．
   `podman compose` は external provider としてこれを呼ぶ構成になった．スクリプトの `compose_cmd()` は `podman compose` を第一候補とする．
3. **DataHub quickstart compose と podman-compose の互換性**
   `--profile` オプション自体は podman-compose 1.6.0 に存在する（`--help` で確認済み）．
   残る懸念は `depends_on` の `condition: service_healthy` など Compose Spec の細部で，podman-compose は Docker Compose の別実装のため差異が出やすい．ステップ 3 の冒頭で検証し，詰まった場合の代替は次の順で試す．
   (a) `brew install docker-compose` して `podman compose` の provider を本家 Compose v2 に切り替える（互換性が最も高い）
   (b) profile を展開した compose を本リポジトリに固定する
   (c) 旧形式の quickstart ファイルを使う
4. **ポート衝突**
   OpenMetadata（8080 Airflow / 9200 ES / 3306 MySQL）と DataHub（8080 GMS / 9200 OpenSearch / 3306 MySQL）が重複する．
   方針: **既定では同時起動しない**．同時比較したい場合に備え，`docker-compose.override.yml` でホスト側ポートをずらせるようにしておく．
5. **リソース同時消費**
   両スタック合計で 14GB 超のメモリを要求するため，同時起動は現実的でない．比較は「片方ずつ起動 → 観点を記録」の手順とする．
6. **バージョン固定**
   OpenMetadata 2.0.1 / DataHub 1.7.0 を `versions.env` に固定．`latest` は使わない．

## 7. 未確認事項

- Containerfile の位置づけを「インジェスト用の薄い拡張イメージ」とする方針（2.1）でよいか．

## 8. 補足: 環境まわりの小ネタ

- `podman compose` は実行のたびに `>>>> Executing external compose provider ... <<<<` を出す．
  `~/.config/containers/containers.conf` に次を書けば黙る．
  ```toml
  [engine]
  compose_warning_logs = false
  ```
- `~/.docker/cli-plugins/` に Docker Desktop 削除後の壊れた symlink が残っている．実害はないが掃除してよい．
