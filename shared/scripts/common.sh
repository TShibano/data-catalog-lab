#!/usr/bin/env bash
# 共通ユーティリティ関数群．
#
# set -euo pipefail が既に有効な呼び出し元スクリプトから source される前提．
# このファイル自体はシェルを終了させる副作用のあるトップレベル処理を持たない
# （関数定義のみ．呼び出されるまで何も実行しない）．
#
# 対応環境は macOS / Linux ネイティブ / WSL2（plans/003 の 3.1）．
# Windows ネイティブ（Git Bash・MSYS2・PowerShell）は対象外．

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

# --- 実行環境の判定 ---
# 重要: 挙動の分岐は OS 名ではなく「podman machine を経由するかどうか」で行う．
# OS 名で分けると，Windows + Podman Desktop（machine あり）と
# WSL2 内の podman（machine なし）を取り違える．
# host_os の戻り値は案内文の出し分けとログ表示にだけ使う．

# macos / linux / windows / unknown を返す．
host_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) printf 'unknown' ;;
  esac
}

# WSL2 上の Linux かどうか（案内文の出し分け用）．
is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null
}

# podman machine を経由する構成か（macOS，Windows + Podman Desktop）．
# machine が停止中でも一覧は返るため，起動状態に依存せず判定できる
# （podman info の Host.ServiceIsRemote は machine 停止時に取れないので使わない）．
# Linux ネイティブでは出力が空になり，非ゼロを返す．
uses_podman_machine() {
  podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .
}

# --- 依存コマンドとバージョン ---

# 必要な podman / compose provider のバージョン下限．
# podman 4.7: rootless で host.containers.internal が解決できるようになった版．
# podman-compose 1.6.0 / docker compose 2.24: compose ファイルの !override タグを
# 解釈できる版（openmetadata/compose.override.yml が使っている）．
PODMAN_MIN_VERSION="4.7"
PODMAN_COMPOSE_MIN_VERSION="1.6.0"
DOCKER_COMPOSE_MIN_VERSION="2.24.0"

# コマンドの入れ方を OS 別に案内する文字列を返す．
install_hint() {
  local cmd="$1"
  case "$(host_os)" in
    macos) printf 'brew install %s' "${cmd}" ;;
    linux)
      if is_wsl; then
        printf 'WSL2 のディストリ内で入れる（例: sudo apt install %s / sudo dnf install %s）' "${cmd}" "${cmd}"
      else
        printf 'ディストリのパッケージマネージャで入れる（例: sudo dnf install %s / sudo apt install %s）' "${cmd}" "${cmd}"
      fi
      ;;
    windows)
      printf 'Windows は WSL2 の中で実行する構成のみ対応．WSL2 のディストリ内で入れる（例: sudo apt install %s）' "${cmd}"
      ;;
    *) printf '%s を入れる' "${cmd}" ;;
  esac
}

# $1 >= $2 なら 0 を返す（バージョン文字列の比較）．
# sort -V は macOS の BSD sort（2.3-Apple）でも GNU sort でも使える（実測・2026-09-07）．
version_ge() {
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# コマンドの存在を確認する．無ければ用途と入れ方を添えて die する．
# 引数1: コマンド名，引数2: 用途（省略可）．
require_cmd() {
  local cmd="$1"
  local purpose="${2:-}"
  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${purpose}" ]; then
    die "${cmd} が見つからない（用途: ${purpose}）．$(install_hint "${cmd}")"
  fi
  die "${cmd} が見つからない．$(install_hint "${cmd}")"
}

# podman の存在とバージョン下限を確認する．
require_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    die "podman が見つからない．$(install_hint podman)（https://podman.io/docs/installation）"
  fi

  local ver
  ver="$(podman --version 2>/dev/null | awk '{print $3}')"
  if [ -z "${ver}" ]; then
    log_warn "podman のバージョンを判定できなかった．${PODMAN_MIN_VERSION} 以上を想定している．"
    return 0
  fi
  if ! version_ge "${ver}" "${PODMAN_MIN_VERSION}"; then
    die "podman ${ver} は古い（要求 ${PODMAN_MIN_VERSION} 以上）．
rootless で host.containers.internal を解決するのに ${PODMAN_MIN_VERSION} 以上が要る（インジェストがサンプル DB に到達できない）．
ディストリ同梱版が古い場合は公式手順で入れ直すこと: https://podman.io/docs/installation"
  fi
}

# compose provider のバージョン行（例: "podman-compose version 1.6.0"）を取り出す．
# podman compose は外部 provider へ委譲する際に stderr へバナーを出すため 2>&1 で受ける．
_compose_version_line() {
  "${COMPOSE_CMD[@]}" version 2>&1 | grep -i 'compose version' | head -n1 || true
}

# compose provider のバージョン下限を確認する．
# compose.override.yml の !override タグを解釈できない版だと，ポート定義が
# upstream と二重になるなど分かりにくい形で壊れるため die する．
_check_compose_version() {
  local line ver
  line="$(_compose_version_line)"
  if [ -z "${line}" ]; then
    log_warn "compose provider のバージョンを判定できなかった．podman-compose ${PODMAN_COMPOSE_MIN_VERSION} 以上，または docker compose ${DOCKER_COMPOSE_MIN_VERSION} 以上を想定している．"
    return 0
  fi

  ver="$(printf '%s' "${line}" | sed -E 's/.*[Vv]ersion[[:space:]]+v?([0-9]+(\.[0-9]+)*).*/\1/')"

  case "${line}" in
    *podman-compose*)
      if ! version_ge "${ver}" "${PODMAN_COMPOSE_MIN_VERSION}"; then
        die "podman-compose ${ver} は古い（要求 ${PODMAN_COMPOSE_MIN_VERSION} 以上）．
compose ファイルの !override タグを解釈できず，ポート定義が upstream と二重になる．
ディストリ同梱版が古い場合は pip 等で入れ直すこと: pip install --user 'podman-compose>=${PODMAN_COMPOSE_MIN_VERSION}'"
      fi
      log_info "compose provider: podman-compose ${ver}"
      ;;
    *[Dd]ocker*)
      if ! version_ge "${ver}" "${DOCKER_COMPOSE_MIN_VERSION}"; then
        die "docker compose ${ver} は古い（要求 ${DOCKER_COMPOSE_MIN_VERSION} 以上）．
compose ファイルの !override タグを解釈できない．"
      fi
      log_info "compose provider: docker compose ${ver}"
      ;;
    *)
      log_warn "compose provider を判定できなかった（${line}）．!override タグを解釈できる版か確認すること．"
      ;;
  esac
}

# compose provider を解決し，グローバル配列 COMPOSE_CMD に格納する．
# podman compose -> podman-compose の順で解決し，バージョン下限も確認する．
# 呼び出し側は "${COMPOSE_CMD[@]}" -f ... up -d のように使う．
compose_cmd() {
  if podman compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(podman compose)
  elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(podman-compose)
  else
    die "compose provider が見つからない．$(install_hint podman-compose)
（pip なら: pip install --user 'podman-compose>=${PODMAN_COMPOSE_MIN_VERSION}'）"
  fi
  _check_compose_version
}

# --- リソースチェック（machine モード / ネイティブモード） ---

# podman machine の情報を "name|mem_mib|disk_gb|state" 形式で取得するヘルパー．
# 引数を渡さないので既定（default）の machine を対象にする．
# メモリは MiB，ディスクは GB の整数で返る（変換不要）．
# machine が存在しなければ podman machine inspect が非ゼロで終了するので，
# 呼び出し側でその終了ステータスを見て判定する．
_machine_info() {
  podman machine inspect --format '{{.Name}}|{{.Resources.Memory}}|{{.Resources.DiskSize}}|{{.State}}' 2>/dev/null
}

# machine モードのメモリ確認．
#
# - machine が存在しなければ作成コマンドを案内して die（勝手に作らない）．
# - 停止中なら podman machine start で起動し，起動後に状態を取り直す．
# - メモリが要求値未満ならエラーで停止し，再作成/変更コマンドを案内する．
#   podman machine rm は絶対に自動実行しない．
_ensure_machine_memory() {
  local required_mem_mib="$1"

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

# machine モードのディスク確認．不足していても停止はせず warn のみ．
_check_machine_disk() {
  local required_gb="$1"

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

# ネイティブモード（Linux / WSL2）のメモリ確認．
# machine と違いホストの物理メモリは増やせないため，不足していても warn に留めて続行する
# （plans/003 の 3.4）．
_ensure_native_memory() {
  local required_mem_mib="$1"

  if [ ! -r /proc/meminfo ]; then
    log_warn "/proc/meminfo を読めないためメモリチェックを省略する．"
    return 0
  fi

  local mem_mib
  mem_mib="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024; exit}' /proc/meminfo)"
  if [ -z "${mem_mib}" ]; then
    log_warn "メモリ搭載量を判定できなかったためチェックを省略する．"
    return 0
  fi

  if [ "${mem_mib}" -lt "${required_mem_mib}" ]; then
    log_warn "ホストのメモリが要求を下回る（搭載 ${mem_mib}MiB，要求 ${required_mem_mib}MiB 以上）．
コンテナが OOM で落ちる可能性が高い．続行するが，失敗したら他のスタックを停止してから再実行すること．"
  else
    log_info "ホストのメモリ確認済み（搭載 ${mem_mib}MiB）．"
  fi
}

# ネイティブモードのディスク確認．machine モードと同じく warn のみ．
# podman のストレージ領域（Store.GraphRoot）がある filesystem の空き容量を見る．
_check_native_disk() {
  local required_gb="$1"

  local root
  root="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
  if [ -z "${root}" ]; then
    root="${HOME}/.local/share/containers"
  fi
  # 未作成でも親を辿れば同じ filesystem の空きが分かる．
  while [ -n "${root}" ] && [ "${root}" != "/" ] && [ ! -d "${root}" ]; do
    root="$(dirname "${root}")"
  done

  local avail_gb
  avail_gb="$(df -Pk "${root}" 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1024 / 1024}')"
  if [ -z "${avail_gb}" ]; then
    log_warn "${root} の空き容量を判定できなかったためチェックを省略する．"
    return 0
  fi

  if [ "${avail_gb}" -lt "${required_gb}" ]; then
    log_warn "podman のストレージ領域（${root}）の空きが少ない（空き ${avail_gb}GB，目安 ${required_gb}GB 以上）．"
  else
    log_info "podman のストレージ領域（${root}）の空き容量は十分（${avail_gb}GB）．"
  fi
}

# メモリを確認する．machine モードとネイティブモードで手段が変わる．
# 引数1: 要求メモリ（MiB，省略時 6144）．
ensure_memory() {
  local required_mem_mib="${1:-6144}"

  require_podman

  if uses_podman_machine; then
    _ensure_machine_memory "${required_mem_mib}"
  else
    _ensure_native_memory "${required_mem_mib}"
  fi
}

# ディスク容量を確認する．不足していても停止はせず warn のみ．
# 引数1: 要求ディスク（GB，省略時 13．DataHub 想定）．
check_disk() {
  local required_gb="${1:-13}"

  if uses_podman_machine; then
    _check_machine_disk "${required_gb}"
  else
    _check_native_disk "${required_gb}"
  fi
}

# メモリとディスクをまとめて確認する．呼び出し側はこれだけ使えばよい．
# 引数1: 要求メモリ（MiB），引数2: 要求ディスク（GB）．
ensure_resources() {
  ensure_memory "${1:-6144}"
  check_disk "${2:-13}"
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
