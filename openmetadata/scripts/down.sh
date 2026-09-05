#!/usr/bin/env bash
set -euo pipefail

# OpenMetadata スタックを停止する．
# 使い方: openmetadata/scripts/down.sh [--purge]
#   --purge  ボリューム（DB・ES のデータ）も削除する

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
使い方: $(basename "$0") [--purge]

  --purge  down -v 相当．DB (mysql) と Elasticsearch のデータボリュームも削除する．
EOF
}

PURGE=0
if [ "$#" -gt 0 ]; then
  case "$1" in
    --purge)
      PURGE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "不明な引数: $1"
      usage
      exit 1
      ;;
  esac
  shift
fi
if [ "$#" -gt 0 ]; then
  log_error "不明な引数: $*"
  usage
  exit 1
fi

require_podman
compose_cmd

om_compose_files

cd "${OM_DIR}"

DOWN_ARGS=("${OM_COMPOSE_FILES[@]}" down)
if [ "${PURGE}" -eq 1 ]; then
  log_warn "--purge: mysql (openmetadata_db / airflow_db) と elasticsearch のデータボリュームを削除する．"
  DOWN_ARGS+=(-v)
fi

"${COMPOSE_CMD[@]}" --env-file "${OM_ENV_FILE}" "${DOWN_ARGS[@]}"
log_info "OpenMetadata スタックを停止した．"
