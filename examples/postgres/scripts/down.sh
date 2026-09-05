#!/usr/bin/env bash
set -euo pipefail

# サンプル DB（postgres）を停止する．
# 使い方: examples/postgres/scripts/down.sh [--purge]
#   --purge  down -v 相当．投入したデータのボリューム（sample-pg-data）も削除する．

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../../../shared/scripts/common.sh
source "${SCRIPT_DIR}/../../../shared/scripts/common.sh"

usage() {
  cat <<EOF
使い方: $(basename "$0") [--purge]

  --purge  down -v 相当．sample-pg-data ボリュームも削除する．
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

cd "${PG_DIR}"

DOWN_ARGS=(-f compose.yml down)
if [ "${PURGE}" -eq 1 ]; then
  log_warn "--purge: sample-pg-data ボリュームを削除する．"
  DOWN_ARGS+=(-v)
fi

"${COMPOSE_CMD[@]}" "${DOWN_ARGS[@]}"
log_info "サンプル DB (postgres) を停止した．"
