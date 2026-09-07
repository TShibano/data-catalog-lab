#!/usr/bin/env bash
# openmetadata/scripts/ 配下の各スクリプトから source される内部ヘルパー．
# shared/scripts/common.sh はツール非依存の共通処理のみを置く方針のため，
# OpenMetadata 固有のパス解決と compose ファイル解決はこちらに置く．
#
# set -euo pipefail が有効な呼び出し元から source される前提．

OM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OM_DIR="$(cd "${OM_SCRIPT_DIR}/.." && pwd)"
OM_ENV_FILE="${OM_DIR}/configs/openmetadata.env"
OM_UPSTREAM_COMPOSE="${OM_DIR}/compose.upstream.yml"
OM_OVERRIDE_COMPOSE="${OM_DIR}/compose.override.yml"

# shellcheck source=../../shared/scripts/common.sh
source "${OM_SCRIPT_DIR}/../../shared/scripts/common.sh"
# shellcheck source=../../shared/scripts/versions.env
source "${OM_SCRIPT_DIR}/../../shared/scripts/versions.env"

# compose に渡す -f 引数を組み立て，グローバル配列 OM_COMPOSE_FILES に入れる．
# ポート割り当ては DataHub と同時起動しても衝突しない値で固定してあるため，
# 重ねる compose ファイルは upstream と override の 2 枚だけで，起動方法による分岐はない．
# 呼び出し側は "${COMPOSE_CMD[@]}" --env-file "${OM_ENV_FILE}" "${OM_COMPOSE_FILES[@]}" up -d
# のように使う．
om_compose_files() {
  OM_COMPOSE_FILES=(-f "${OM_UPSTREAM_COMPOSE}" -f "${OM_OVERRIDE_COMPOSE}")
}

# compose.upstream.yml が無ければ取得する．
ensure_upstream_compose() {
  if [ ! -f "${OM_UPSTREAM_COMPOSE}" ]; then
    log_info "compose.upstream.yml が無いので取得する．"
    "${OM_SCRIPT_DIR}/../../shared/scripts/fetch-compose.sh" openmetadata
  fi
}
