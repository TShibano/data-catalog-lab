#!/usr/bin/env bash
set -euo pipefail

# サンプル DB (examples/postgres) を OpenMetadata へインジェストする．
# 1. Containerfile.ingestion をビルド
# 2. ingestion-bot の JWT を API から動的に取得
# 3. メタデータインジェスト（テーブル・ビュー・コメント）を実行
# 4. リネージインジェスト（view -> table のリネージ）を実行
# 5. 検索 API とリネージ API で結果を検証
#
# 前提: ./openmetadata/scripts/up.sh と ./examples/postgres/scripts/up.sh が
# 事前に実行済みで両方とも起動していること．
#
# 使い方: openmetadata/scripts/ingest.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

IMAGE_TAG="om-ingestion:local"
OM_BASE_URL="http://localhost:${OM_UI_PORT}"

# Linux ネイティブ向けの補正．SELinux enforcing なら bind mount を再ラベルし，
# host.containers.internal が未定義な環境では --add-host で補う．
# machine モード（macOS 等）ではどちらも空になり，従来と同じ挙動になる．
MOUNT_SUFFIX="$(selinux_mount_suffix)"
container_host_args

# --- 期待値定数（examples/sample-data/01_schema.sql の内容に対応） ---
# public スキーマのテーブル総数．
# テーブル: customers / orders / order_items（3）
# ビュー  : order_details / customer_order_summary（2）
EXPECTED_PUBLIC_TABLES=5
# customer_order_summary は customers / orders / order_items の 3 テーブルを
# 直接 JOIN・集約したビュー（01_schema.sql 参照）．上流エッジは 3 件になるはず．
EXPECTED_UPSTREAM_EDGES=3

require_podman

# --- 0. 前提の到達確認 ---
log_info "OpenMetadata サーバへの到達を確認する．"
if ! curl -fsS -o /dev/null "${OM_BASE_URL}/api/v1/system/version"; then
  die "OpenMetadata サーバ (${OM_BASE_URL}) に到達できない．先に ./openmetadata/scripts/up.sh を実行すること．"
fi

log_info "サンプル DB (postgres) への到達を確認する．"
if ! podman exec sample_postgres psql -U sample_user -d sampledb -c 'SELECT 1;' >/dev/null 2>&1; then
  die "サンプル DB に到達できない．先に ./examples/postgres/scripts/up.sh を実行すること．"
fi

# --- 1. イメージビルド ---
log_info "Containerfile.ingestion をビルドする．"
cd "${OM_DIR}"
podman build -f Containerfile.ingestion -t "${IMAGE_TAG}" .

# --- 2. ingestion-bot の JWT を API から動的に取得する ---
# OpenMetadata は初期セットアップ時に ingestion-bot 用の JWT を自動生成して
# 保持しており，GET /users/token/{id} でいつでも取得し直せる（既定では
# 有効期限なし＝Unlimited）．この値は「公開されている既定値」ではなく，
# このデプロイ固有にサーバが生成した値なのでログに出力しない．
#
# 管理者ログインは admin/admin という OpenMetadata の既定クレデンシャルを使う
# （本リポジトリの検証環境専用．password は API 仕様上 base64 で渡す）．
log_info "admin でログインしてアクセストークンを取得する．"
ADMIN_PASSWORD_B64="$(printf '%s' 'admin' | base64)"
ADMIN_LOGIN_RESPONSE="$(curl -fsS -X POST "${OM_BASE_URL}/api/v1/users/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"admin@open-metadata.org\",\"password\":\"${ADMIN_PASSWORD_B64}\"}")"
ADMIN_TOKEN="$(printf '%s' "${ADMIN_LOGIN_RESPONSE}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')"

if [ -z "${ADMIN_TOKEN}" ]; then
  die "admin のアクセストークン取得に失敗した．"
fi

log_info "ingestion-bot のユーザ ID を取得する．"
BOT_ID="$(curl -fsS "${OM_BASE_URL}/api/v1/users/name/ingestion-bot" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

if [ -z "${BOT_ID}" ]; then
  die "ingestion-bot のユーザ ID 取得に失敗した．"
fi

log_info "ingestion-bot の JWT を取得する（GET /users/token/{id}）．"
BOT_JWT="$(curl -fsS "${OM_BASE_URL}/api/v1/users/token/${BOT_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["JWTToken"])')"

if [ -z "${BOT_JWT}" ]; then
  die "ingestion-bot の JWT 取得に失敗した．"
fi
log_info "JWT 取得完了（値はログに出さない）．"

# --- 3. recipe の一時コピーにトークンを埋め込む ---
# configs/ingestion/*.yaml のプレースホルダはリポジトリにコミットする値であり
# 秘密ではない．実際のトークンはここで一時ファイルに書き出し，
# podman run 実行後に削除する．
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

sed "s#REPLACE_WITH_INGESTION_BOT_JWT#${BOT_JWT}#" \
  "${OM_DIR}/configs/ingestion/postgres_metadata.yaml" > "${TMP_DIR}/postgres_metadata.yaml"
sed "s#REPLACE_WITH_INGESTION_BOT_JWT#${BOT_JWT}#" \
  "${OM_DIR}/configs/ingestion/postgres_lineage.yaml" > "${TMP_DIR}/postgres_lineage.yaml"
chmod 600 "${TMP_DIR}"/*.yaml

# --- 4. メタデータインジェスト ---
log_info "メタデータインジェストを実行する（テーブル・ビュー・コメント）．"
if ! podman run --rm \
  ${CONTAINER_HOST_ARGS[@]+"${CONTAINER_HOST_ARGS[@]}"} \
  -v "${TMP_DIR}/postgres_metadata.yaml:/opt/ingestion/configs/ingestion/postgres_metadata.yaml:ro${MOUNT_SUFFIX}" \
  "${IMAGE_TAG}" ingest -c /opt/ingestion/configs/ingestion/postgres_metadata.yaml; then
  die "メタデータインジェストに失敗した．"
fi

# --- 5. リネージインジェスト ---
# postgres_lineage.yaml は source.type: postgres-lineage を使っており，
# これも `metadata ingest`（MetadataWorkflow）で実行する．
# `metadata lineage` サブコマンドは別物（1 本の生 SQL を指定サービスに対して
# 手動でリネージ登録する ad-hoc コマンド）で，今回のような
# DatabaseServiceQueryLineagePipeline recipe の実行には使わない
# （実機で試して WorkflowInitErrorHandler のエラーになることを確認済み）．
log_info "リネージインジェストを実行する（view -> table のリネージ）．"
if ! podman run --rm \
  ${CONTAINER_HOST_ARGS[@]+"${CONTAINER_HOST_ARGS[@]}"} \
  -v "${TMP_DIR}/postgres_lineage.yaml:/opt/ingestion/configs/ingestion/postgres_lineage.yaml:ro${MOUNT_SUFFIX}" \
  "${IMAGE_TAG}" ingest -c /opt/ingestion/configs/ingestion/postgres_lineage.yaml; then
  die "リネージインジェストに失敗した．"
fi

# --- 6. API で結果を検証する ---

# schemaFilterPattern（public 限定）が効いているかを件数一致で確認する．
# 以前は「1 件以上ヒットすれば OK」という緩い判定だったため，
# information_schema まで丸ごと取り込まれていても検知できなかった．
log_info "public スキーマのテーブル総数を確認する．"
PUBLIC_TABLES_RESULT="$(curl -fsS "${OM_BASE_URL}/api/v1/tables?databaseSchema=sample_postgres.sampledb.public&limit=100" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")"
PUBLIC_TABLES_TOTAL="$(printf '%s' "${PUBLIC_TABLES_RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["paging"]["total"])')"
PUBLIC_TABLE_NAMES="$(printf '%s' "${PUBLIC_TABLES_RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(", ".join(sorted(t["name"] for t in d["data"])))')"

if [ "${PUBLIC_TABLES_TOTAL}" -ne "${EXPECTED_PUBLIC_TABLES}" ]; then
  die "public スキーマのテーブル総数が期待値と一致しない（期待: ${EXPECTED_PUBLIC_TABLES}，実測: ${PUBLIC_TABLES_TOTAL}）．schemaFilterPattern の設定を確認すること．"
fi
log_info "public スキーマのテーブル総数は期待どおり ${PUBLIC_TABLES_TOTAL} 件（${PUBLIC_TABLE_NAMES}）．"

# sample_postgres サービス（sample_postgres.sampledb データベース）配下に
# information_schema のスキーマが取り込まれていないことを確認する．
log_info "sample_postgres 配下に information_schema が存在しないことを確認する．"
DATABASE_SCHEMAS_RESULT="$(curl -fsS "${OM_BASE_URL}/api/v1/databaseSchemas?database=sample_postgres.sampledb&limit=100" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")"
if printf '%s' "${DATABASE_SCHEMAS_RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(s["name"] == "information_schema" for s in d["data"]) else 1)'; then
  die "sample_postgres 配下に information_schema が残っている．schemaFilterPattern の設定を確認すること．"
fi
log_info "sample_postgres 配下に information_schema は存在しない．"

# 検索インデックスへの反映がわずかに遅れることがあるため軽くリトライする．
# ここは「customers がヒットするか」という存在確認のみで，件数自体は
# トークナイズやスコアリングの都合で環境依存に揺れうるため厳密一致はさせない．
log_info "検索 API で customers テーブルがヒットするか確認する．"
SEARCH_OK=0
for _ in 1 2 3 4 5; do
  SEARCH_RESULT="$(curl -fsS "${OM_BASE_URL}/api/v1/search/query?q=customers&index=table_search_index" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")"
  HIT_COUNT="$(printf '%s' "${SEARCH_RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hits",{}).get("total",{}).get("value",0))')"
  if [ "${HIT_COUNT}" -gt 0 ]; then
    SEARCH_OK=1
    break
  fi
  sleep 3
done

# json.tool の出力を先に変数へ確定してから head で切り詰める．
# python3 -m json.tool を head に直結すると，head が先に読み終えてパイプを
# 閉じた際に python3 が SIGPIPE を受けて非 0 終了し，pipefail 経由で
# スクリプト全体が異常終了することがある（実機で確認済み）．
SEARCH_RESULT_PRETTY="$(printf '%s' "${SEARCH_RESULT}" | python3 -m json.tool)"
echo "=== 検索 API: q=customers ==="
printf '%s\n' "${SEARCH_RESULT_PRETTY}" | head -60 || true
echo

if [ "${SEARCH_OK}" -ne 1 ]; then
  die "検索 API で customers がヒットしなかった．"
fi
log_info "検索 API で customers がヒットした（${HIT_COUNT} 件）．"

log_info "リネージ API で customer_order_summary の上流を確認する．"
VIEW_FQN="sample_postgres.sampledb.public.customer_order_summary"
LINEAGE_RESULT="$(curl -fsS "${OM_BASE_URL}/api/v1/lineage/table/name/${VIEW_FQN}?upstreamDepth=2&downstreamDepth=1" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")"

echo "=== リネージ API: ${VIEW_FQN} ==="
printf '%s\n' "${LINEAGE_RESULT}" | python3 -m json.tool
echo

UPSTREAM_COUNT="$(printf '%s' "${LINEAGE_RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("upstreamEdges", [])))')"
if [ "${UPSTREAM_COUNT}" -ne "${EXPECTED_UPSTREAM_EDGES}" ]; then
  die "customer_order_summary の上流エッジ数が期待値と一致しない（期待: ${EXPECTED_UPSTREAM_EDGES}，実測: ${UPSTREAM_COUNT}）．"
fi
log_info "customer_order_summary の上流に期待どおり ${UPSTREAM_COUNT} 件のエッジを確認した．"

log_info "インジェストと検証が完了した．"
