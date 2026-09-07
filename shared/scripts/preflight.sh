#!/usr/bin/env bash
# 起動前の前提チェック．
#
# 各 up.sh の冒頭から source して preflight を呼ぶ（COMPOSE_CMD を呼び出し元の
# シェルに残す必要があるため，実行ではなく source する）．
# 単体でも実行できる: ./shared/scripts/preflight.sh [要求メモリMiB] [要求ディスクGB]
#
# 独立したテストスイートは作らない方針のため，これは検証専用スクリプトではなく
# 通常の起動経路に常に走る前段チェックとして置く．

PREFLIGHT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${PREFLIGHT_SCRIPT_DIR}/common.sh"

# 前提を順に確認する．満たせないものがあれば die する．
# 引数1: 要求メモリ（MiB，省略時 6144），引数2: 要求ディスク（GB，省略時 13）．
preflight() {
  local required_mem_mib="${1:-6144}"
  local required_disk_gb="${2:-13}"

  local os
  os="$(host_os)"

  # Windows ネイティブ（Git Bash / MSYS2）は対象外．MSYS2 のパス変換で
  # podman run の -v やコンテナ内パスが壊れるため，分かりやすく落とす．
  if [ "${os}" = "windows" ]; then
    die "Windows ネイティブ（Git Bash / MSYS2 / PowerShell）は対象外．
WSL2 のディストリを入れ，その中で podman ごと動かすこと（plans/003 の 3.1）．"
  fi

  require_podman

  local os_label="${os}"
  if is_wsl; then
    os_label="${os_label} (WSL2)"
  fi
  if uses_podman_machine; then
    log_info "実行環境: ${os_label} / podman machine 経由"
  else
    log_info "実行環境: ${os_label} / ネイティブ"
  fi

  # 各スクリプトが前提にしている外部コマンド．
  # macOS には標準で入るが，最小構成の Linux では欠けていることがある．
  require_cmd curl "起動待機と API での検証"
  require_cmd python3 "インジェスト結果の JSON 解析"
  require_cmd base64 "OpenMetadata の admin ログイン"

  # COMPOSE_CMD を設定し，!override タグを解釈できる版かも確認する．
  compose_cmd

  ensure_resources "${required_mem_mib}" "${required_disk_gb}"
}

# 直接実行されたときだけ既定値で走る．source されたときは関数定義のみ．
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  preflight "${1:-6144}" "${2:-13}"
  log_info "前提チェックはすべて通った．"
fi
