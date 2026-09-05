#!/usr/bin/env bash
set -euo pipefail

# OpenMetadata スタックのログを追跡する．
# 使い方: openmetadata/scripts/logs.sh [service...]
#   引数省略時は全サービスのログを追う．
#   service: mysql / elasticsearch / execute-migrate-all / openmetadata-server / ingestion

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_podman
compose_cmd

om_compose_files

cd "${OM_DIR}"

"${COMPOSE_CMD[@]}" --env-file "${OM_ENV_FILE}" "${OM_COMPOSE_FILES[@]}" logs -f "$@"
