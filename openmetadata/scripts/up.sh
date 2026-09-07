#!/usr/bin/env bash
set -euo pipefail

# OpenMetadata スタックを起動する．
# 使い方: openmetadata/scripts/up.sh
#
# ポートは DataHub と衝突しない値で固定してあるため，DataHub と同時に起動できる
# （割り当ては README.md の「ポート割り当て」を参照）．

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../../shared/scripts/preflight.sh
source "${SCRIPT_DIR}/../../shared/scripts/preflight.sh"

# 前提チェック（podman / compose provider / 依存コマンド / メモリ・ディスク）．
# machine の有無は preflight 側で判定するため，ここは OS を意識しない．
# DataHub が起動済みなら同時起動になるため，両スタック分の要求値で確認する
# （単体分で通してしまうと，一番落ちてほしい場面で落ちない）．
if compose_project_running "${DATAHUB_COMPOSE_PROJECT}"; then
  log_info "DataHub のスタックが起動中．同時起動として両スタック分のリソースを確認する．"
  preflight "${BOTH_REQUIRED_MEM_MIB}" "${BOTH_REQUIRED_DISK_GB}"
else
  preflight "${OM_REQUIRED_MEM_MIB}" "${OM_REQUIRED_DISK_GB}"
fi

ensure_upstream_compose
om_compose_files

log_info "OpenMetadata スタックを起動する（初回はイメージ pull とマイグレーションで数分かかる）．"

cd "${OM_DIR}"
if ! "${COMPOSE_CMD[@]}" --env-file "${OM_ENV_FILE}" "${OM_COMPOSE_FILES[@]}" up -d; then
  log_error "compose up に失敗した．"
  log_error "ログを確認すること: ./openmetadata/scripts/logs.sh"
  exit 1
fi

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
