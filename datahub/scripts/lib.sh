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
# ポート割り当ては OpenMetadata と同時起動しても衝突しない値で固定してあるため，
# 重ねる compose ファイルは upstream と override の 2 枚だけで，起動方法による分岐はない．
# ホスト側から到達する GMS のポートは versions.env の DATAHUB_GMS_PORT を参照する．
# 呼び出し側は
#   "${COMPOSE_CMD[@]}" --env-file "${DH_ENV_FILE}" "${DH_PROFILE_ARGS[@]}" "${DH_COMPOSE_FILES[@]}" up -d
# のように使う．
dh_compose_files() {
  DH_COMPOSE_FILES=(-f "${DH_UPSTREAM_COMPOSE}" -f "${DH_OVERRIDE_COMPOSE}")
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

  # SELinux enforcing のディストリでは，再ラベルしていない bind mount を
  # コンテナから読めない．upstream compose の bind mount に `:z` を付ける手段が
  # ないため（compose.override.yml のコメント参照），ホスト側のディレクトリを
  # 直接ラベル付けする．chcon は自分の所有ファイルに対してなら root 不要．
  if selinux_enforcing; then
    if command -v chcon >/dev/null 2>&1; then
      log_info "SELinux enforcing を検出．${HOME}/.datahub を container_file_t にラベル付けする．"
      if ! chcon -Rt container_file_t "${HOME}/.datahub" 2>/dev/null; then
        log_warn "${HOME}/.datahub の再ラベルに失敗した．コンテナが plugins/search を読めない場合は次を手で実行すること．
  chcon -Rt container_file_t ${HOME}/.datahub"
      fi
    else
      log_warn "SELinux enforcing だが chcon が見つからない．コンテナが ${HOME}/.datahub を読めない可能性がある．"
    fi
  fi

  if [ -d "${HOME}/.aws" ]; then
    mkdir -p "${HOME}/.aws/sso/cache"
  else
    log_warn "${HOME}/.aws が存在しないため作成しない（datahub-actions-quickstart 用の bind mount 対象だが，汎用ディレクトリを本リポジトリの都合で新規作成するのは避ける方針）．"
    log_warn "datahub-actions-quickstart の起動に失敗する場合は ./datahub/scripts/logs.sh datahub-actions-quickstart で確認すること．"
  fi
}
