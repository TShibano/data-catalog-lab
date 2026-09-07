#!/usr/bin/env bash
set -euo pipefail

# DataHub スタックの状態をまとめて表示する．
# 独立したテストスイートは作らない方針のため，検証はここに埋め込む．
# 使い方: datahub/scripts/status.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_podman
compose_cmd

dh_compose_files

cd "${DH_DIR}"

echo "=== podman compose ps ==="
"${COMPOSE_CMD[@]}" --env-file "${DH_ENV_FILE}" "${DH_PROFILE_ARGS[@]}" "${DH_COMPOSE_FILES[@]}" ps
echo

# upstream compose は container_name を明示していないため，
# podman-compose が自動採番したコンテナ名（<project>_<service>_1 等）を
# 決め打ちにせず，compose が付与するラベルで実際のコンテナ名を引く．
# 該当コンテナが無ければヘルスチェック対象から外す．
#
# service だけで絞ると，OpenMetadata 側の mysql コンテナも
# com.docker.compose.service=mysql を持つため，同時起動時に他方のコンテナを
# 掴みうる．project ラベルと併せて絞ること．
echo "=== ヘルスチェック ==="
# healthcheck が定義されているのは upstream 上で
# datahub-gms-quickstart / kafka-broker / mysql / opensearch の 4 つ．
HEALTH_SERVICES=(datahub-gms-quickstart kafka-broker mysql opensearch)
ALL_HEALTHY=1
for svc in "${HEALTH_SERVICES[@]}"; do
  cname="$(podman ps -a \
    --filter "label=com.docker.compose.project=${DATAHUB_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${svc}" \
    --format '{{.Names}}' | head -n1)"
  if [ -z "${cname}" ]; then
    echo "  ${svc}: コンテナが見つからない"
    ALL_HEALTHY=0
    continue
  fi
  health="$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}(healthcheck定義なし){{end}}' "${cname}" 2>/dev/null || echo "(取得失敗)")"
  echo "  ${svc} (${cname}): ${health}"
  if [ "${health}" != "healthy" ] && [ "${health}" != "(healthcheck定義なし)" ]; then
    ALL_HEALTHY=0
  fi
done
echo

# UI と GMS への到達確認．ポートは versions.env を参照する．
# GMS のヘルスエンドポイントは upstream の healthcheck 定義
# （curl http://datahub-gms:8080/health）に合わせて /health を使う．
UI_URL="http://localhost:${DATAHUB_UI_PORT}"
GMS_HEALTH_URL="http://localhost:${DATAHUB_GMS_PORT}/health"

echo "=== 到達確認 ==="
UI_OK=0
UI_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${UI_URL}" 2>/dev/null || true)"
case "${UI_CODE}" in
  2??|3??) echo "  UI (${UI_URL}): OK (HTTP ${UI_CODE})"; UI_OK=1 ;;
  *) echo "  UI (${UI_URL}): NG (HTTP ${UI_CODE:-N/A})" ;;
esac

GMS_OK=0
GMS_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${GMS_HEALTH_URL}" 2>/dev/null || true)"
case "${GMS_CODE}" in
  2??|3??) echo "  GMS health (${GMS_HEALTH_URL}): OK (HTTP ${GMS_CODE})"; GMS_OK=1 ;;
  *) echo "  GMS health (${GMS_HEALTH_URL}): NG (HTTP ${GMS_CODE:-N/A})" ;;
esac
echo

echo "=== まとめ ==="
if [ "${ALL_HEALTHY}" -eq 1 ] && [ "${UI_OK}" -eq 1 ] && [ "${GMS_OK}" -eq 1 ]; then
  echo "  DataHub は正常に稼働している．"
  exit 0
else
  echo "  異常あり．詳細は上記の各項目を確認すること．ログ: ./datahub/scripts/logs.sh"
  exit 1
fi
