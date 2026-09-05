#!/usr/bin/env bash
# datahub/scripts/ 配下の各スクリプトから source される内部ヘルパー．
# shared/scripts/common.sh はツール非依存の共通処理のみを置く方針のため，
# DataHub 固有のパス解決と compose ファイル解決はこちらに置く．
#
# set -euo pipefail が有効な呼び出し元から source される前提．

DH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DH_DIR="$(cd "${DH_SCRIPT_DIR}/.." && pwd)"
DH_ENV_FILE="${DH_DIR}/configs/datahub.env"
DH_UPSTREAM_COMPOSE="${DH_DIR}/compose.upstream.yml"
DH_OVERRIDE_COMPOSE="${DH_DIR}/compose.override.yml"
DH_ALTPORTS_COMPOSE="${DH_DIR}/compose.altports.yml"

# shellcheck source=../../shared/scripts/common.sh
source "${DH_SCRIPT_DIR}/../../shared/scripts/common.sh"
# shellcheck source=../../shared/scripts/versions.env
source "${DH_SCRIPT_DIR}/../../shared/scripts/versions.env"

# DataHub の upstream compose は全サービスに profiles: が付いており，
# --profile を指定しないとサービスが 1 つも起動しない．
# quickstart プロファイルで 7 サービスすべてが対象になる．
# （podman-compose 1.6.0 で --profile は -f より前でも後でも動作することを確認済み．
#  ここでは compose ファイルの指定と対にして分かりやすいよう別配列にしておく．）
DH_PROFILE_ARGS=(--profile quickstart)

# compose に渡す -f 引数を組み立て，グローバル配列 DH_COMPOSE_FILES に入れる．
# DATAHUB_ALT_PORTS=1 のときだけ compose.altports.yml（OpenMetadata と同時起動する
# 際のポートずらし）を 3 枚目として重ねる．
# 呼び出し側は
#   "${COMPOSE_CMD[@]}" --env-file "${DH_ENV_FILE}" "${DH_PROFILE_ARGS[@]}" "${DH_COMPOSE_FILES[@]}" up -d
# のように使う．
#
# 同時に，ホスト側から到達するときの GMS ポート（DH_GMS_PORT）もここで決める．
# compose.altports.yml が gms を 8080 -> 28080 にずらすため，DATAHUB_ALT_PORTS の値と
# ポート番号の対応関係をこの関数 1 箇所にまとめておく（status.sh 等，GMS の URL を
# 組み立てる側は直接ポート番号を書かずここを参照する）．
# compose.altports.yml 側でポート番号を変えたら，ここも合わせて変えること．
dh_compose_files() {
  DH_COMPOSE_FILES=(-f "${DH_UPSTREAM_COMPOSE}" -f "${DH_OVERRIDE_COMPOSE}")
  DH_GMS_PORT=8080
  if [ "${DATAHUB_ALT_PORTS:-0}" = "1" ]; then
    log_info "DATAHUB_ALT_PORTS=1: compose.altports.yml を重ねる（mysql/opensearch/gms のポートをずらす）．"
    DH_COMPOSE_FILES+=(-f "${DH_ALTPORTS_COMPOSE}")
    DH_GMS_PORT=28080
  fi
}

# compose.upstream.yml が無ければ取得する．
ensure_upstream_compose() {
  if [ ! -f "${DH_UPSTREAM_COMPOSE}" ]; then
    log_info "compose.upstream.yml が無いので取得する．"
    "${DH_SCRIPT_DIR}/../../shared/scripts/fetch-compose.sh" datahub
  fi
}

# upstream compose の bind mount 先ディレクトリを作る．
# podman-compose 1.6.0 は bind mount の create_host_path を尊重するとは限らないため，
# 事前に mkdir -p しておくのが安全．
#
# ${HOME}/.datahub/plugins と ${HOME}/.datahub/search は DataHub 専用のディレクトリ
# なので無条件に作成する（公式の `datahub docker quickstart` も同様に作成する）．
#
# 一方 ${HOME}/.aws は DataHub 専用ではなく AWS CLI 等が使う汎用ディレクトリのため，
# 存在しない環境で本リポジトリが勝手に作るのは避ける．
# 既に ${HOME}/.aws があるときだけ ${HOME}/.aws/sso/cache を補って作る．
# ${HOME}/.aws が無い場合は作らずに warn だけ出す
# （datahub-actions-quickstart コンテナの起動に失敗する可能性があるが，
#  他サービスには影響しない見込み．失敗した場合は必要に応じて
#  手動で `mkdir -p ~/.aws/sso/cache` するか，datahub-actions-quickstart を
#  対象から外して調査すること）．
ensure_host_dirs() {
  mkdir -p "${HOME}/.datahub/plugins"
  mkdir -p "${HOME}/.datahub/search"

  if [ -d "${HOME}/.aws" ]; then
    mkdir -p "${HOME}/.aws/sso/cache"
  else
    log_warn "${HOME}/.aws が存在しないため作成しない（datahub-actions-quickstart 用の bind mount 対象だが，汎用ディレクトリを本リポジトリの都合で新規作成するのは避ける方針）．"
    log_warn "datahub-actions-quickstart の起動に失敗する場合は ./datahub/scripts/logs.sh datahub-actions-quickstart で確認すること．"
  fi
}
