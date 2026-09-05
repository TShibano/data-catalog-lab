#!/usr/bin/env bash
# 共通ユーティリティ関数群．
#
# set -euo pipefail が既に有効な呼び出し元スクリプトから source される前提．
# このファイル自体はシェルを終了させる副作用のあるトップレベル処理を持たない
# （関数定義のみ．呼び出されるまで何も実行しない）．

# --- ログ出力 ---
# 端末（stderr）に接続されているときだけ色を付ける．

log_info() {
  if [[ -t 2 ]]; then
    printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2
  else
    printf '[INFO] %s\n' "$*" >&2
  fi
}

log_warn() {
  if [[ -t 2 ]]; then
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

log_error() {
  if [[ -t 2 ]]; then
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  else
    printf '[ERROR] %s\n' "$*" >&2
  fi
}

# エラーを出して終了する．
die() {
  log_error "$*"
  exit 1
}

# このファイル（shared/scripts/common.sh）の位置から，
# BASH_SOURCE を使ってリポジトリルート（2 階層上）を返す．
# どこから source / 実行されても正しく解決する．
repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "${script_dir}/../.." && pwd)
}

# podman コマンドの存在確認．
require_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    die "podman が見つからない．インストール: brew install podman （https://podman.io/docs/installation）"
  fi
}

# podman machine の情報を "name|mem_mib|disk_gb|state" 形式で取得するヘルパー．
# 引数を渡さないので既定（default）の machine を対象にする．
# メモリは MiB，ディスクは GB の整数で返る（変換不要）．
# machine が存在しなければ podman machine inspect が非ゼロで終了するので，
# 呼び出し側でその終了ステータスを見て判定する．
_machine_info() {
  podman machine inspect --format '{{.Name}}|{{.Resources.Memory}}|{{.Resources.DiskSize}}|{{.State}}' 2>/dev/null
}

# podman machine の状態を確認する．
# 引数1: 要求メモリ（MiB，省略時 6144）．
#
# - machine が存在しなければ作成コマンドを案内して die（勝手に作らない）．
# - 停止中なら podman machine start で起動し，起動後に状態を取り直す．
# - メモリが要求値未満ならエラーで停止し，再作成/変更コマンドを案内する．
#   podman machine rm は絶対に自動実行しない．
ensure_machine() {
  local required_mem_mib="${1:-6144}"

  require_podman

  local info name mem_mib disk_gb state
  if ! info="$(_machine_info)"; then
    die "podman machine が存在しない．次のコマンドで作成すること．
  podman machine init --cpus 4 --memory ${required_mem_mib} --disk-size 20"
  fi
  IFS='|' read -r name mem_mib disk_gb state <<< "${info}"

  if [ "${state}" != "running" ]; then
    log_info "podman machine '${name}' が停止中（状態: ${state}）．起動する．"
    podman machine start "${name}"
    if ! info="$(_machine_info)"; then
      die "podman machine '${name}' の起動後に状態取得へ失敗した．"
    fi
    IFS='|' read -r name mem_mib disk_gb state <<< "${info}"
  fi

  if [ "${mem_mib}" -lt "${required_mem_mib}" ]; then
    die "podman machine '${name}' のメモリが不足（現在 ${mem_mib}MiB，要求 ${required_mem_mib}MiB 以上）．
次の手順で変更してから再実行すること（podman machine rm は使わない）．
  podman machine stop
  podman machine set --memory ${required_mem_mib}
  podman machine start"
  fi

  log_info "podman machine '${name}' 確認済み（メモリ ${mem_mib}MiB）．"
}

# podman machine のディスク容量を確認する．不足していても停止はせず warn のみ．
# 引数1: 要求ディスク（GB，省略時 13．DataHub 想定）．
check_disk() {
  local required_gb="${1:-13}"

  local info name mem_mib disk_gb state
  if ! info="$(_machine_info)"; then
    log_warn "podman machine が見つからないためディスク容量チェックを省略する．"
    return 0
  fi
  IFS='|' read -r name mem_mib disk_gb state <<< "${info}"

  if [ "${disk_gb}" -lt "${required_gb}" ]; then
    log_warn "podman machine '${name}' のディスクが少ない可能性がある（現在 ${disk_gb}GB，目安 ${required_gb}GB 以上）．
必要なら次で拡張できる．
  podman machine stop && podman machine set --disk-size ${required_gb} && podman machine start"
  else
    log_info "podman machine '${name}' のディスク容量は十分（${disk_gb}GB）．"
  fi
}

# compose provider を解決し，グローバル配列 COMPOSE_CMD に格納する．
# podman compose -> podman-compose の順で解決する．
# 呼び出し側は "${COMPOSE_CMD[@]}" -f ... up -d のように使う．
compose_cmd() {
  if podman compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(podman compose)
  elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(podman-compose)
  else
    die "compose provider が見つからない．インストール: brew install podman-compose"
  fi
}

# URL が 2xx/3xx を返すまでリトライで待つ．
# 引数1: URL，引数2: タイムアウト秒（省略時 60），引数3: 間隔秒（省略時 3）．
# タイムアウトしたら 1 を返す（die はしない．呼び出し側に判断させる）．
wait_http() {
  local url="$1"
  local timeout="${2:-60}"
  local interval="${3:-3}"
  local elapsed=0
  local code

  log_info "起動待機: ${url}（タイムアウト ${timeout}秒）"

  while [ "${elapsed}" -lt "${timeout}" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
    case "${code}" in
      2??|3??)
        log_info "${url} が応答した（HTTP ${code}）．"
        return 0
        ;;
    esac
    log_info "待機中...（${elapsed}/${timeout}秒，直近のステータス: ${code:-N/A}）"
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
  done

  log_warn "${url} がタイムアウトまでに応答しなかった．"
  return 1
}
