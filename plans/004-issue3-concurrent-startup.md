# 実装計画: OpenMetadata と DataHub の同時起動（Issue #3）

作成日: 2026-09-07
対象: Issue #3「feat: OpenMetaDataとDataHubの同時起動」
状態: **計画のみ**．実装は本計画のレビュー・マージ後に着手する．

## 1. 背景

Issue #3 の要求は次の 3 点．

- OpenMetadata と DataHub を**同時に**起動して比較できるようにする．
- ポート番号は重複しないように**事前に全て決めて**，README.md に記載する．
- 必要なディスクサイズ・メモリサイズ・ストレージサイズは増やしてよい．

現状は `plans/001-container-setup.md` の 5.4 / 5.5 で「**既定では同時起動しない**」
「両スタック合計 14GB 超のメモリを要求するため同時起動は現実的でない」と決めており，
README にも「同時には起動しない」と書いてある．
同時起動は `OM_ALT_PORTS=1` / `DATAHUB_ALT_PORTS=1` を渡したときだけ
`compose.altports.yml` を 3 枚目として重ねる**逃げ道**として用意されているだけで，
実機で通したことはない（`docs/comparison.md` 末尾の通り未検証）．

Issue #3 は，この「同時起動しない」という前提そのものを覆すもの．
逃げ道を**既定の構成に格上げする**のが本計画の主眼になる．

## 2. 現状の同時起動の阻害要因（実測・2026-09-07）

| # | 箇所 | 症状 | 影響 |
| --- | --- | --- | --- |
| 1 | ホスト公開ポートの衝突（3306 / 9200 / 8080） | 両スタックの mysql・検索エンジン・API が同じホストポートを取り合う | **致命**．2 つ目の `up.sh` が bind 失敗 |
| 2 | ポートずらしが環境変数まかせ（`OM_ALT_PORTS` / `DATAHUB_ALT_PORTS`） | 「事前に全て決めて README に記載」という要求を満たさない．片方だけ付け忘れると衝突する．`DH_GMS_PORT` の分岐と `REPLACE_WITH_GMS_PORT` プレースホルダという実装上の複雑さも抱える | 運用事故のもと |
| 3 | `podman machine` のメモリ 9536MiB（実測） | 両スタックの `mem_limit` 合計は OM 7g + DH 8g，さらにサンプル DB 512m で計 15.5g．machine に収まらない | **致命**．OOM |
| 4 | `preflight` の要求メモリがスタック単体分（OM 6144 / DH 8192） | 片方が起動済みでも「8192MiB あれば OK」と判定して通してしまう．一番落ちてほしい場面で落ちない | 検知漏れ |
| 5 | `datahub/scripts/status.sh` のコンテナ特定条件 | `--filter label=com.docker.compose.service=mysql` だけで引いており，**OpenMetadata 側の mysql コンテナも同じラベルを持つ**．同時起動時に他方のコンテナを掴んで誤判定しうる（`head -n1` で先に見つかった方を採用するため） | **同時起動時のみ顕在化**．要修正 |
| 6 | README / `docs/comparison.md` / 各 `configs/*.env` の記述 | 「同時には起動しない」「`ALT_PORTS` で逃げられる」という前提で書かれている | ドキュメント更新が必要 |

衝突しないことを確認済みの箇所も挙げておく．

- compose プロジェクト名はディレクトリ名から決まる（実測: `com.docker.compose.project=postgres`）．
  `openmetadata` / `datahub` / `postgres` の 3 プロジェクトに分かれるため，ネットワークとボリュームは衝突しない．
- `container_name` は OpenMetadata 側だけが明示（`openmetadata_mysql` 等）．DataHub 側は自動採番で
  `datahub_*` になるため名前の衝突はない．
- サンプル DB の 5432，OM の UI 8585/8586，DataHub の UI 9002・Kafka 9092・GMS 4319 は
  もともと衝突しない．

## 3. 方針

### 3.1 ポートは常に固定の割り当てとし，切り替えを廃止する（決定・2026-09-07）

`OM_ALT_PORTS` / `DATAHUB_ALT_PORTS` による切り替えをやめ，
**衝突しないポート割り当てを常時の既定にする**．`compose.altports.yml` は
`compose.override.yml` に統合して削除する．

| ツール | サービス | 用途 | ホスト公開ポート | upstream 既定 |
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

割り当ての規則は次の通り．

- **UI と API のポートは upstream 既定を維持する**（8585 / 8586 / 9002 / 8080 / 4319 / 9092 / 5432）．
  公式ドキュメントや `datahub` CLI の既定（GMS = `localhost:8080`）と食い違わせないため．
- **衝突する裏方サービスは，どちらもずらす**．OpenMetadata は `1xxxx`，DataHub は `2xxxx` を接頭とする
  （13306 / 19200 / 19300 と 23306 / 29200）．
  片方だけ upstream 既定に残すと「どちらが既定側だったか」を都度思い出す必要が出るため，
  番号を見ればツールが分かる規則を優先する．
- OpenMetadata の Airflow UI 8080 は DataHub GMS の 8080 と衝突するため 18080 にずらす
  （上の規則と整合する）．

**副作用**: 単体起動でも upstream 既定とはポートがずれる．
`3306` / `9200` へ直接繋ぐ手順を書いた外部資料はそのままでは使えない．
README のポート表を唯一の参照先とし，この点を明記する．

### 3.2 ポート番号の単一の情報源をどこに置くか

`compose.override.yml` の `!override` タグの中では `${VAR}` が展開されない
（`plans/003` で実機確認済みの podman-compose 1.6.0 の不具合）．
そのため compose 側はリテラル値を書くしかなく，**完全な一元化はできない**．

- compose ファイル: リテラル値を書く．先頭コメントで「変更したら README のポート表と
  `shared/scripts/versions.env` も合わせること」と明記する．
- `shared/scripts/versions.env`: スクリプトがホスト側から到達するときに使うポートだけを持つ
  （`OM_UI_PORT` / `OM_ADMIN_PORT` / `DATAHUB_UI_PORT` / `DATAHUB_GMS_PORT`）．
  現状 `status.sh` に直書きされている 8586 もここへ移す．
- README のポート表: 人間向けの唯一の一覧（3.1 の表）．

`DH_GMS_PORT` を `dh_compose_files()` が動的に決める仕組みは不要になるので削除し，
`versions.env` の `DATAHUB_GMS_PORT` に置き換える．

### 3.3 メモリは podman machine を 18GiB へ拡張して確保する（決定・2026-09-07）

`mem_limit` の割り当ては現状を維持し，machine 側を広げて対応する．
`mem_limit` を同時起動時だけ絞る案は，OOM や起動失敗のリスクを上げるうえ，
両ツールに与える条件が変わって比較結果の公平性も損なうため採らない．

| 項目 | 現状 | 変更後 |
| --- | --- | --- |
| ホスト実機（Apple Silicon macOS） | 32GiB / 10 コア | 変更なし |
| podman machine メモリ | 9536MiB（9.312GiB） | **18432MiB（18GiB）** |
| podman machine ディスク | 60GB | 変更なし（十分） |
| podman machine CPU | 4 | 変更なし（3.6 参照） |

要求値の内訳（`mem_limit` の合計）．

| スタック | 内訳 | 合計 |
| --- | --- | --- |
| OpenMetadata | mysql 1g + elasticsearch 2g + openmetadata-server 2g + ingestion 2g | 7g |
| DataHub | opensearch 2g + kafka-broker 1g + gms 2g + frontend 1g + mysql 1g + actions 1g | 8g |
| サンプル DB | postgres 512m | 0.5g |
| **同時起動の合計** | | **15.5g** |

18GiB は 15.5g に対しておよそ 2.5GiB の余裕がある．
`mem_limit` を持たないサービス（OM の `execute-migrate-all`，DataHub の
`system-update-quickstart`）が起動時に一時的に消費する分と，machine 自身の
OS 分をここで吸収する．ホスト 32GiB のうち 14GiB は macOS 側に残る．

### 3.4 前提チェックは「他方のスタックが起動中か」を見て要求値を切り替える

`preflight` に渡す要求メモリを固定値のままにすると #4 を潰せない．
`shared/scripts/common.sh` に，指定した compose プロジェクトのコンテナが
起動中かを見るヘルパを足す．

```sh
# 実測で確認済みのラベル（podman-compose 1.6.0）を使う．
compose_project_running() {
  [ -n "$(podman ps --filter "label=com.docker.compose.project=$1" --format '{{.Names}}' 2>/dev/null)" ]
}
```

各 `up.sh` は，他方のスタックが起動中なら**同時起動時の合計要求値**で `preflight` を呼ぶ．
要求値は `shared/scripts/versions.env` に集約する．

| 変数 | 値 | 用途 |
| --- | --- | --- |
| `OM_REQUIRED_MEM_MIB` | 6144 | OpenMetadata 単体 |
| `DATAHUB_REQUIRED_MEM_MIB` | 8192 | DataHub 単体 |
| `BOTH_REQUIRED_MEM_MIB` | 16384 | 同時起動（15.5g + 予備） |
| `OM_REQUIRED_DISK_GB` | 13 | OpenMetadata 単体 |
| `DATAHUB_REQUIRED_DISK_GB` | 13 | DataHub 単体 |
| `BOTH_REQUIRED_DISK_GB` | 25 | 同時起動（4.2 の実測イメージサイズから） |

machine モードでは要求メモリ未満なら `_ensure_machine_memory` が既に
`podman machine set --memory` の手順を案内して die する（`plans/003` の 3.4）ため，
**18GiB への拡張は「案内に従って手で実行する」導線に自然に乗る**．
スクリプトが勝手に machine を作り直さない方針は維持する．
ネイティブモード（Linux / WSL2）では従来どおり warn で続行する．

### 3.5 同時起動時のコンテナ特定を厳密にする（#5）

`datahub/scripts/status.sh` は `com.docker.compose.service` だけでコンテナを引いており，
OpenMetadata 側の `mysql` を掴みうる．`com.docker.compose.project=datahub` を
フィルタに追加して，プロジェクトで絞る．

```sh
cname="$(podman ps -a \
  --filter "label=com.docker.compose.project=datahub" \
  --filter "label=com.docker.compose.service=${svc}" \
  --format '{{.Names}}' | head -n1)"
```

OpenMetadata 側は `container_name` 固定で引いているため変更不要．

### 3.6 起動用のラッパースクリプトは作らない．CPU も当面は 4 のまま

- **ラッパー（`up-all.sh` 等）は作らない**．`up.sh` を 2 回叩くだけで済み，
  片方だけ起動する使い方も引き続き必要なため，README に手順を書けば足りる．
  ラッパーを足すと down / logs / status も対で用意することになり，
  「ツールごとにディレクトリが閉じる」という本リポジトリの構成方針もぼやける．
- **CPU は 4 のまま様子を見る**．同時起動では 13 サービスが動くため起動は遅くなるが，
  遅いだけなら比較の妨げにはならない．実装時に起動時間を計測し，
  実用にならないほど遅ければ `podman machine set --cpus 6` を README に追記する
  （ホストは 10 コアなので余地はある）．

## 4. 実装ステップ（`jj` の論理単位）

1 ステップ = 1 `jj` change とする．

| # | change | 内容 | 触るファイル |
| --- | --- | --- | --- |
| 1 | `feat: ポート割り当てを固定して同時起動できるようにする` | 3.1 / 3.2．`compose.altports.yml` の値を各 `compose.override.yml` へ統合して削除．`OM_ALT_PORTS` / `DATAHUB_ALT_PORTS` の分岐と `DH_GMS_PORT` の動的決定を削除．`versions.env` にポートを集約．DataHub recipe の `REPLACE_WITH_GMS_PORT` を 8080 直書きに戻し，`ingest.sh` の `sed` 置換を `cp` に変える（リポジトリ内のファイルを直接マウントすると SELinux の `,Z` で再ラベルしてしまうため，一時コピー自体は残す） | `openmetadata/compose.override.yml`，`openmetadata/compose.altports.yml`（削除），`openmetadata/scripts/lib.sh`，`openmetadata/scripts/up.sh`，`datahub/compose.override.yml`，`datahub/compose.altports.yml`（削除），`datahub/scripts/lib.sh`，`datahub/scripts/up.sh`，`datahub/scripts/ingest.sh`，`datahub/configs/recipes/postgres_to_datahub.yml`，`shared/scripts/versions.env` |
| 2 | `feat: 同時起動時のリソース要求を前提チェックに反映する` | 3.4 の `compose_project_running`，要求値の `versions.env` への集約と `up.sh` からの切り替え．3.5 の `status.sh` のフィルタ修正 | `shared/scripts/common.sh`，`shared/scripts/versions.env`，`openmetadata/scripts/up.sh`，`datahub/scripts/up.sh`，`datahub/scripts/status.sh` |
| 3 | `docs: 同時起動の手順とポート・リソース要件を記載する` | 3.1 のポート表，3.3 のリソース要件表と machine 拡張手順，同時起動の手順．「同時には起動しない」という既存記述の撤回．`configs/*.env` の `ALT_PORTS` に関するコメント削除 | `README.md`，`docs/comparison.md`，`openmetadata/configs/openmetadata.env`，`datahub/configs/datahub.env`，`plans/001-container-setup.md`（5.4 / 5.5 の決定を本計画で更新した旨の追記） |

ステップ 1 → 2 は順序依存（2 は 1 でポートが固定された前提）．3 は最後．

## 5. 検証方法

macOS 実機（32GiB / 10 コア）で実際に同時起動まで通す．
独立したテストスイートは作らない方針のため，検証は `up.sh` / `status.sh` / `ingest.sh` に埋める．

1. **machine 拡張**．`podman machine stop && podman machine set --memory 18432 && podman machine start`．
   拡張前に `up.sh` が要求値不足で die し，案内どおりの手順で直せることも確認する（3.4 の導線）．
2. **単体起動の回帰**．ポートを変えた影響で単体起動が壊れていないことを，
   両ツールで `up.sh` → `status.sh` → `ingest.sh` → `down.sh` の通しで確認する．
3. **同時起動**．`examples/postgres` → OpenMetadata → DataHub の順に起動し，
   - 13 サービスすべてが up になること（`status.sh` が両方とも「正常に稼働している」を返すこと）．
   - `status.sh` が他方のコンテナを誤検出していないこと（3.5）．
   - 両方の UI（8585 / 9002）と API（8586 / 8080）に同時に到達できること．
   - `ingest.sh` を両方実行し，どちらも検証まで通ること．
   - 起動時間を記録する（3.6 の CPU 判断材料）．
4. **後始末**．`down.sh` を両方（と postgres）で実行し，
   ボリュームとネットワークが互いを巻き込まずに落ちることを確認する．
5. **shellcheck**．変更した全スクリプトに掛ける．

## 6. 確認済みのこと / 未確認のこと

**確認済み（このリポジトリと手元環境で実測した）**

- 2 章の阻害要因すべて（該当ファイルと行を読んで特定）．
- ホスト実機は 32GiB / 10 コア，machine は 9536MiB / 60GB / CPU 4，ホストのディスク空きは 53GiB．
- compose プロジェクト名がディレクトリ名になること，付与されるラベルが
  `com.docker.compose.project` / `com.docker.compose.service` であること
  （稼働中の `sample_postgres` のラベルで確認）．
- OpenMetadata の `PIPELINE_SERVICE_CLIENT_ENDPOINT` は `http://ingestion:8080` という
  **コンテナ間の参照**であり，ホスト公開ポートを 18080 に変えても影響しないこと．
- upstream compose のうちホスト公開されているポートの全量（3.1 の表の「upstream 既定」列）．
- 両スタックのイメージ合計サイズ（OM 約 7.8GB / DataHub 約 7.25GB，`docs/comparison.md` の実測）．

**未確認（推測で実装しない）**

- 18GiB へ拡張した machine で 13 サービスが実際に安定して同時稼働するか
  （`mem_limit` の合計は収まるが，ピーク時の実使用量は未計測）．
- 同時起動時の起動時間．DataHub の `system-update-quickstart` と OpenMetadata の
  `execute-migrate-all` が同時に走る局面が最も重い見込み．
- `datahub/scripts/status.sh` の `service` ラベルが本当に OpenMetadata 側の
  mysql コンテナと衝突するか（`container_name` を明示していても
  compose のラベルは付く，という前提の確認）．
- ポートを固定値に変えた後，podman-compose 1.6.0 の `!override` が
  altports 統合後の `compose.override.yml` でも期待どおりマージされるか
  （`podman compose config` の出力で確認する）．
- ホスト側で 13306 / 19200 / 19300 / 23306 / 29200 が他プロセスに使われていないか
  （実装時に `lsof -i` で確認する）．

## 7. 次のアクション

1. ~~ポート割り当ての方式を確定する~~ → 常に固定．`ALT_PORTS` は廃止（2026-09-07）．
2. ~~メモリの確保方法を確定する~~ → machine を 18GiB へ拡張．`mem_limit` は現状維持（2026-09-07）．
3. 本計画のレビューとマージ．
4. 4 章のステップ 1 から着手する．
