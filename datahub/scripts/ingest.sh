#!/usr/bin/env bash
set -euo pipefail

# サンプル DB (examples/postgres) を DataHub へインジェストする．
# 1. Containerfile.ingestion をビルド
# 2. recipe (configs/recipes/postgres_to_datahub.yml) でインジェストを実行
# 3. GMS の API で結果（検索・リネージ）を検証
#
# 前提: ./datahub/scripts/up.sh と ./examples/postgres/scripts/up.sh が
# 事前に実行済みで両方とも起動していること．
#
# OpenMetadata と異なり，DataHub の quickstart GMS は既定で認証を要求しない
# （ローカル検証環境のため未認証で到達できる）．そのため JWT 等のトークン
# 取得は不要．
#
# 使い方: datahub/scripts/ingest.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

IMAGE_TAG="dh-ingestion:local"
RECIPE_NAME="postgres_to_datahub.yml"

require_podman

# DATAHUB_ALT_PORTS=1（OpenMetadata と同時起動する場合）では GMS のホスト公開
# ポートが 8080 -> 28080 にずれる．status.sh と同様に dh_compose_files() で
# 決めた DH_GMS_PORT を使い，ホスト側の到達確認とコンテナ内から見る
# host.containers.internal 経由の接続先の両方をこれに合わせる．
dh_compose_files
GMS_URL="http://localhost:${DH_GMS_PORT}"

# --- 0. 前提の到達確認 ---
log_info "DataHub GMS への到達を確認する．"
if ! curl -fsS -o /dev/null "${GMS_URL}/health"; then
  die "DataHub GMS (${GMS_URL}) に到達できない．先に ./datahub/scripts/up.sh を実行すること．"
fi

log_info "サンプル DB (postgres) への到達を確認する．"
if ! podman exec sample_postgres psql -U sample_user -d sampledb -c 'SELECT 1;' >/dev/null 2>&1; then
  die "サンプル DB に到達できない．先に ./examples/postgres/scripts/up.sh を実行すること．"
fi

# --- 1. イメージビルド ---
log_info "Containerfile.ingestion をビルドする．"
cd "${DH_DIR}"
podman build -f Containerfile.ingestion -t "${IMAGE_TAG}" .

# --- 2. recipe の一時コピーに GMS ポートを埋め込む ---
# configs/recipes/${RECIPE_NAME} はどのポートでも動くよう REPLACE_WITH_GMS_PORT
# というプレースホルダのままコミットしている．実際のポート（既定 8080 /
# DATAHUB_ALT_PORTS=1 なら 28080）は起動時にしか決まらないため，ここで
# 一時ファイルへ sed 置換してからマウントする
# （OpenMetadata 側で jwtToken を埋め込むのと同じ方式）．
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

sed "s#REPLACE_WITH_GMS_PORT#${DH_GMS_PORT}#" \
  "${DH_DIR}/configs/recipes/${RECIPE_NAME}" > "${TMP_DIR}/${RECIPE_NAME}"
chmod 600 "${TMP_DIR}/${RECIPE_NAME}"

# --- 3. インジェスト実行 ---
# DATAHUB_TELEMETRY_ENABLED=false: acryl-datahub は既定で終了時に利用統計を
# track.datahubproject.io へ送ろうとし，このホストがサンドボックスから
# 到達できないため接続タイムアウトのリトライで無駄に待たされる
# （実機で確認済み）．検証環境として外部送信も避けたいので無効化する．
log_info "recipe (${RECIPE_NAME}, GMS ポート ${DH_GMS_PORT}) でインジェストを実行する．"
if ! podman run --rm \
  -e DATAHUB_TELEMETRY_ENABLED=false \
  -v "${TMP_DIR}/${RECIPE_NAME}:/opt/ingestion/configs/recipes/${RECIPE_NAME}:ro" \
  "${IMAGE_TAG}" ingest -c "/opt/ingestion/configs/recipes/${RECIPE_NAME}"; then
  die "インジェストに失敗した．"
fi

# --- 4. API で結果を検証する ---
log_info "検索 API で customers データセットがヒットするか確認する．"
SEARCH_OK=0
for _ in 1 2 3 4 5; do
  SEARCH_RESULT="$(curl -fsS -X POST "${GMS_URL}/entities?action=search" \
    -H 'Content-Type: application/json' \
    -d '{"input":"customers","entity":"dataset","start":0,"count":10}')"
  HIT_COUNT="$(printf '%s' "${SEARCH_RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("value",{}).get("numEntities",0))')"
  if [ "${HIT_COUNT}" -gt 0 ]; then
    SEARCH_OK=1
    break
  fi
  sleep 3
done

echo "=== 検索 API: q=customers ==="
printf '%s\n' "${SEARCH_RESULT}" | python3 -m json.tool | head -40
echo

if [ "${SEARCH_OK}" -ne 1 ]; then
  die "検索 API で customers がヒットしなかった．"
fi
log_info "検索 API で customers がヒットした（${HIT_COUNT} 件）．"

log_info "リネージ API で customer_order_summary の上流を確認する（upstreamLineage aspect）．"
VIEW_URN="urn:li:dataset:(urn:li:dataPlatform:postgres,sampledb.public.customer_order_summary,PROD)"
VIEW_URN_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${VIEW_URN}")"

LINEAGE_RESULT="$(curl -fsS "${GMS_URL}/aspects/${VIEW_URN_ENC}?aspect=upstreamLineage&version=0")"

echo "=== リネージ API: ${VIEW_URN} ==="
printf '%s\n' "${LINEAGE_RESULT}" | python3 -m json.tool
echo

UPSTREAM_COUNT="$(printf '%s' "${LINEAGE_RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("aspect",{}).get("com.linkedin.dataset.UpstreamLineage",{}).get("upstreams",[])))')"
if [ "${UPSTREAM_COUNT}" -lt 1 ]; then
  die "customer_order_summary の上流リネージが 1 件も取れなかった．"
fi
log_info "customer_order_summary の上流に ${UPSTREAM_COUNT} 件のデータセットを確認した．"

log_info "インジェストと検証が完了した．"
