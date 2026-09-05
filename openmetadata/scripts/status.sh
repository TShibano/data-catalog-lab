#!/usr/bin/env bash
set -euo pipefail

# OpenMetadata スタックの状態をまとめて表示する．
# 独立したテストスイートは作らない方針のため，検証はここに埋め込む．
# 使い方: openmetadata/scripts/status.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_podman
compose_cmd

om_compose_files

cd "${OM_DIR}"

echo "=== podman compose ps ==="
"${COMPOSE_CMD[@]}" --env-file "${OM_ENV_FILE}" "${OM_COMPOSE_FILES[@]}" ps
echo

# healthcheck が定義されているコンテナのヘルス状態を見る．
# container_name は upstream compose の値と一致させる．
echo "=== ヘルスチェック ==="
HEALTH_CONTAINERS=(openmetadata_mysql openmetadata_elasticsearch openmetadata_server)
ALL_HEALTHY=1
for c in "${HEALTH_CONTAINERS[@]}"; do
  if ! podman container exists "${c}" 2>/dev/null; then
    echo "  ${c}: コンテナが存在しない"
    ALL_HEALTHY=0
    continue
  fi
  health="$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}(healthcheck定義なし){{end}}' "${c}" 2>/dev/null || echo "(取得失敗)")"
  echo "  ${c}: ${health}"
  if [ "${health}" != "healthy" ] && [ "${health}" != "(healthcheck定義なし)" ]; then
    ALL_HEALTHY=0
  fi
done
echo

# UI と管理系エンドポイントへの到達確認．
# openmetadata-server の 8585/8586 は compose.altports.yml でも変更しない方針
# （DataHub と衝突しないため）なので固定値で良い．UI 側は versions.env の OM_UI_PORT を使う．
UI_URL="http://localhost:${OM_UI_PORT}"
ADMIN_HEALTHCHECK_URL="http://localhost:8586/healthcheck"

echo "=== 到達確認 ==="
UI_OK=0
UI_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${UI_URL}" 2>/dev/null || true)"
case "${UI_CODE}" in
  2??|3??) echo "  UI (${UI_URL}): OK (HTTP ${UI_CODE})"; UI_OK=1 ;;
  *) echo "  UI (${UI_URL}): NG (HTTP ${UI_CODE:-N/A})" ;;
esac

ADMIN_OK=0
ADMIN_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${ADMIN_HEALTHCHECK_URL}" 2>/dev/null || true)"
case "${ADMIN_CODE}" in
  2??|3??) echo "  admin healthcheck (${ADMIN_HEALTHCHECK_URL}): OK (HTTP ${ADMIN_CODE})"; ADMIN_OK=1 ;;
  *) echo "  admin healthcheck (${ADMIN_HEALTHCHECK_URL}): NG (HTTP ${ADMIN_CODE:-N/A})" ;;
esac
echo

echo "=== まとめ ==="
if [ "${ALL_HEALTHY}" -eq 1 ] && [ "${UI_OK}" -eq 1 ] && [ "${ADMIN_OK}" -eq 1 ]; then
  echo "  OpenMetadata は正常に稼働している．"
  exit 0
else
  echo "  異常あり．詳細は上記の各項目を確認すること．ログ: ./openmetadata/scripts/logs.sh"
  exit 1
fi
