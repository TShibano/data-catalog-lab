#!/usr/bin/env bash
set -euo pipefail

# DataHub スタックのログを追跡する．
# 使い方: datahub/scripts/logs.sh [service...]
#   引数省略時は全サービスのログを追う．
#   service: mysql / opensearch / kafka-broker / system-update-quickstart /
#            datahub-gms-quickstart / frontend-quickstart / datahub-actions-quickstart

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_podman
compose_cmd

dh_compose_files

cd "${DH_DIR}"

"${COMPOSE_CMD[@]}" --env-file "${DH_ENV_FILE}" "${DH_PROFILE_ARGS[@]}" "${DH_COMPOSE_FILES[@]}" logs -f "$@"
