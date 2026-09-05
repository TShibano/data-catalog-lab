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
  -v "${TMP_DIR}/postgres_metadata.yaml:/opt/ingestion/configs/ingestion/postgres_metadata.yaml:ro" \
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
  -v "${TMP_DIR}/postgres_lineage.yaml:/opt/ingestion/configs/ingestion/postgres_lineage.yaml:ro" \
  "${IMAGE_TAG}" ingest -c /opt/ingestion/configs/ingestion/postgres_lineage.yaml; then
  die "リネージインジェストに失敗した．"
fi

# --- 6. API で結果を検証する ---
# 検索インデックスへの反映がわずかに遅れることがあるため軽くリトライする．
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

echo "=== 検索 API: q=customers ==="
printf '%s\n' "${SEARCH_RESULT}" | python3 -m json.tool | head -60
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
if [ "${UPSTREAM_COUNT}" -lt 1 ]; then
  die "customer_order_summary の上流リネージが 1 件も取れなかった．"
fi
log_info "customer_order_summary の上流に ${UPSTREAM_COUNT} 件のエッジを確認した．"

log_info "インジェストと検証が完了した．"
