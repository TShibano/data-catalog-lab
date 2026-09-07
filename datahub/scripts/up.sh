#!/usr/bin/env bash
set -euo pipefail

# DataHub スタックを起動する．
# 使い方: datahub/scripts/up.sh
#
# ポートは OpenMetadata と衝突しない値で固定してあるため，OpenMetadata と同時に
# 起動できる（割り当ては README.md の「ポート割り当て」を参照）．

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../../shared/scripts/preflight.sh
source "${SCRIPT_DIR}/../../shared/scripts/preflight.sh"

# 前提チェック（podman / compose provider / 依存コマンド / メモリ・ディスク）．
# DataHub は 7 サービス構成で OpenMetadata より要求メモリが大きい（8GB）．
# OpenMetadata が起動済みなら同時起動になるため，両スタック分の要求値で確認する
# （単体分で通してしまうと，一番落ちてほしい場面で落ちない）．
if compose_project_running "${OM_COMPOSE_PROJECT}"; then
  log_info "OpenMetadata のスタックが起動中．同時起動として両スタック分のリソースを確認する．"
  preflight "${BOTH_REQUIRED_MEM_MIB}" "${BOTH_REQUIRED_DISK_GB}"
else
  preflight "${DATAHUB_REQUIRED_MEM_MIB}" "${DATAHUB_REQUIRED_DISK_GB}"
fi

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
