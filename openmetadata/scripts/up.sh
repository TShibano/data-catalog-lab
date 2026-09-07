#!/usr/bin/env bash
set -euo pipefail

# OpenMetadata スタックを起動する．
# 使い方: openmetadata/scripts/up.sh
#   OM_ALT_PORTS=1 ./openmetadata/scripts/up.sh
#     DataHub と同時起動したい場合，mysql/elasticsearch/ingestion のポートをずらす．
#     openmetadata-server (8585/8586) は DataHub と衝突しないので変わらない．

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../../shared/scripts/preflight.sh
source "${SCRIPT_DIR}/../../shared/scripts/preflight.sh"

# 前提チェック（podman / compose provider / 依存コマンド / メモリ・ディスク）．
# machine の有無は preflight 側で判定するため，ここは OS を意識しない．
preflight 6144 13

ensure_upstream_compose
om_compose_files

log_info "OpenMetadata スタックを起動する（初回はイメージ pull とマイグレーションで数分かかる）．"

cd "${OM_DIR}"
if ! "${COMPOSE_CMD[@]}" --env-file "${OM_ENV_FILE}" "${OM_COMPOSE_FILES[@]}" up -d; then
  log_error "compose up に失敗した．"
  log_error "ログを確認すること: ./openmetadata/scripts/logs.sh"
  exit 1
fi

# openmetadata-server の UI ポートは compose.altports.yml でも変えない方針のため，
# 常に versions.env の OM_UI_PORT を使う．
UI_URL="http://localhost:${OM_UI_PORT}"

if wait_http "${UI_URL}" 600 5; then
  log_info "OpenMetadata が起動した: ${UI_URL}"
  log_info "初期ログイン: admin@open-metadata.org / admin"
else
  log_error "${UI_URL} がタイムアウトまでに応答しなかった．"
  log_error "状態確認: ./openmetadata/scripts/status.sh"
  log_error "ログ確認: ./openmetadata/scripts/logs.sh [service]"
  exit 1
fi
