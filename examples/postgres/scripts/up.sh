#!/usr/bin/env bash
set -euo pipefail

# サンプル DB（インジェスト対象の postgres）を起動する．
# OpenMetadata / DataHub のどちらのスタックとも別 compose プロジェクトの
# ため，起動順序に依存関係はない．
# 使い方: examples/postgres/scripts/up.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../../../shared/scripts/common.sh
source "${SCRIPT_DIR}/../../../shared/scripts/common.sh"
# shellcheck source=../../../shared/scripts/preflight.sh
source "${SCRIPT_DIR}/../../../shared/scripts/preflight.sh"

CONTAINER_NAME="sample_postgres"
DB_USER="sample_user"
DB_NAME="sampledb"

# 前提チェック（podman / compose provider / 依存コマンド / メモリ・ディスク）．
preflight 2048 2

cd "${PG_DIR}"

log_info "サンプル DB (postgres) を起動する．"
if ! "${COMPOSE_CMD[@]}" -f compose.yml up -d; then
  log_error "compose up に失敗した．"
  exit 1
fi

# --- 初期化 SQL の完了を待つ ---
# postgres の公式イメージは /docker-entrypoint-initdb.d/ 配下の .sql を
# ファイル名順に実行してから接続を受け付ける．pg_isready が通っても
# 初期化 SQL の実行中は接続を拒否するため，実際に SELECT が通るまでを
# もって完了とみなす．
TIMEOUT=120
INTERVAL=3
ELAPSED=0
DB_READY=0

log_info "初期化 SQL の完了を待機する（タイムアウト ${TIMEOUT}秒）．"
while [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
  if podman exec "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -c 'SELECT 1;' >/dev/null 2>&1; then
    DB_READY=1
    break
  fi
  log_info "待機中...（${ELAPSED}/${TIMEOUT}秒）"
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ "${DB_READY}" -ne 1 ]; then
  log_error "タイムアウトまでに SELECT が通らなかった．"
  log_error "ログを確認すること: podman logs ${CONTAINER_NAME}"
  exit 1
fi

log_info "SELECT 1 が通った．初期化 SQL 完了を確認．"

# --- スキーマの確認（table / view 一覧） ---
echo "=== テーブル / ビュー一覧 ==="
podman exec "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -c '\dt+' -c '\dv+'
echo

# --- 集約ビューに実データが入っているかの確認 ---
SUMMARY_COUNT="$(podman exec "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -tAc 'SELECT count(*) FROM customer_order_summary;')"
DETAILS_COUNT="$(podman exec "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -tAc 'SELECT count(*) FROM order_details;')"

echo "=== 投入データ件数 ==="
echo "  customer_order_summary: ${SUMMARY_COUNT} 行"
echo "  order_details:          ${DETAILS_COUNT} 行"
echo

if [ "${SUMMARY_COUNT}" -lt 1 ] || [ "${DETAILS_COUNT}" -lt 1 ]; then
  log_error "ビューに想定したデータが入っていない．初期化 SQL を確認すること．"
  exit 1
fi

log_info "サンプル DB が起動し，SELECT で検証済み．接続情報: postgresql://${DB_USER}:sample_password@localhost:5432/${DB_NAME}"
log_info "コンテナからは host.containers.internal:5432 で到達できる想定．"
