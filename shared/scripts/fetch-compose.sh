#!/usr/bin/env bash
set -euo pipefail

# 公式の compose ファイルを取得して <tool>/compose.upstream.yml に保存する．
# 取得したファイルはバイト列を変えずにそのままコミットする方針のため，
# コメント等の追記は一切行わない．取得元 URL と取得日時はログにのみ出す．
#
# 使い方: fetch-compose.sh <openmetadata|datahub> [--force]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=./versions.env
source "${SCRIPT_DIR}/versions.env"

usage() {
  cat <<EOF
使い方: $(basename "$0") <openmetadata|datahub> [--force]

  openmetadata  OpenMetadata の公式 compose（${OM_VERSION}）を取得する
  datahub       DataHub の公式 compose（${DATAHUB_VERSION}）を取得する
  --force       既に compose.upstream.yml があっても再取得する
EOF
}

if [ "$#" -lt 1 ]; then
  log_error "ツール名を指定すること．"
  usage
  exit 1
fi

TOOL="$1"
FORCE=0

if [ "$#" -ge 2 ]; then
  if [ "$2" = "--force" ]; then
    FORCE=1
  else
    log_error "不明な引数: $2"
    usage
    exit 1
  fi
fi

ROOT_DIR="$(repo_root)"

case "${TOOL}" in
  openmetadata)
    URL="${OM_COMPOSE_URL}"
    DEST_DIR="${ROOT_DIR}/openmetadata"
    ;;
  datahub)
    URL="${DATAHUB_COMPOSE_URL}"
    DEST_DIR="${ROOT_DIR}/datahub"
    ;;
  *)
    log_error "不明なツール: ${TOOL}"
    usage
    exit 1
    ;;
esac

DEST_FILE="${DEST_DIR}/compose.upstream.yml"

mkdir -p "${DEST_DIR}"

if [ -f "${DEST_FILE}" ] && [ "${FORCE}" -ne 1 ]; then
  log_info "${DEST_FILE} は既に存在するのでスキップする（再取得するなら --force）．"
  exit 0
fi

log_info "取得元: ${URL}"
log_info "取得先: ${DEST_FILE}"

TMP_FILE="$(mktemp "${DEST_DIR}/.compose.upstream.XXXXXX")"
# 失敗時に中途半端な一時ファイルを残さない．
trap 'rm -f "${TMP_FILE}"' EXIT

if ! curl -fsSL "${URL}" -o "${TMP_FILE}"; then
  die "ダウンロードに失敗した: ${URL}"
fi

mv "${TMP_FILE}" "${DEST_FILE}"
# mktemp が作るファイルは 0600 なので，通常のリポジトリ内ファイルと同じ権限に直す．
chmod 644 "${DEST_FILE}"
trap - EXIT

log_info "取得完了: ${DEST_FILE}（$(wc -c < "${DEST_FILE}" | tr -d ' ') bytes）"
log_info "取得日時: $(date '+%Y-%m-%d %H:%M:%S %Z')"
