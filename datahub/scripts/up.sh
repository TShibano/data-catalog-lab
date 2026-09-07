#!/usr/bin/env bash
set -euo pipefail

# DataHub スタックを起動する．
# 使い方: datahub/scripts/up.sh
#   DATAHUB_ALT_PORTS=1 ./datahub/scripts/up.sh
#     OpenMetadata と同時起動したい場合，mysql/opensearch/gms のポートをずらす．
#     frontend-quickstart (9002) は OpenMetadata と衝突しないので変わらない．

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../../shared/scripts/preflight.sh
source "${SCRIPT_DIR}/../../shared/scripts/preflight.sh"

# 前提チェック（podman / compose provider / 依存コマンド / メモリ・ディスク）．
# DataHub は 7 サービス構成で OpenMetadata より要求メモリが大きいため 8GB を要求する．
preflight 8192 13

ensure_upstream_compose
ensure_host_dirs
dh_compose_files

log_info "DataHub スタックを起動する（初回はイメージ pull とシステム更新ジョブで数分かかる．OpenMetadata より起動が遅い）．"

cd "${DH_DIR}"
if ! "${COMPOSE_CMD[@]}" --env-file "${DH_ENV_FILE}" "${DH_PROFILE_ARGS[@]}" "${DH_COMPOSE_FILES[@]}" up -d; then
  log_error "compose up に失敗した．"
  log_error "ログを確認すること: ./datahub/scripts/logs.sh"
  exit 1
fi

# frontend-quickstart の UI ポートは compose.altports.yml でも変えない方針のため，
# 常に versions.env の DATAHUB_UI_PORT を使う．
UI_URL="http://localhost:${DATAHUB_UI_PORT}"

# DataHub は system-update-quickstart の完了待ちなどがあり OpenMetadata より
# 起動が遅いため，タイムアウトを長めに取る．
if wait_http "${UI_URL}" 900 5; then
  log_info "DataHub が起動した: ${UI_URL}"
  log_info "初期ログイン: datahub / datahub"
else
  log_error "${UI_URL} がタイムアウトまでに応答しなかった．"
  log_error "状態確認: ./datahub/scripts/status.sh"
  log_error "ログ確認: ./datahub/scripts/logs.sh [service]"
  exit 1
fi
