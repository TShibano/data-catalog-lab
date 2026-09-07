# 実装計画: Linux / Windows 対応（Issue #2）

作成日: 2026-09-07
対象: Issue #2「feat: Linux/Windows対応」
状態: **未着手**．2 章の棚卸しは実測ベース．3.1（対応範囲）・3.4（リソース不足時の扱い）は決定済み．
更新: 2026-09-07

## 1. 背景

Issue #2 の要求は次の通り．

- 現状のシェルスクリプトは macOS 限定になっており，Linux で実行するとスクリプト由来のエラーが出る．
- 原因は，macOS では podman の実行に Linux VM（`podman machine`）が必要で，
  その確認コードがスクリプトに埋め込まれているため．
- Linux / Windows でも動くように変更する．

本リポジトリのスクリプトは `plans/001-container-setup.md` の通り
macOS（Apple Silicon）の実機 1 台だけで書かれており，他 OS では未実行．
そのため本計画は「machine チェックを外す」ではなく，
**OS 依存箇所を洗い出して分岐させる**という範囲で立てる．

## 2. 現状の macOS 依存箇所（実測・2026-09-07）

リポジトリ全体を読んで洗い出した．**「podman machine」だけが問題ではない**．

| # | 箇所 | 症状 | 影響 |
| --- | --- | --- | --- |
| 1 | `shared/scripts/common.sh` の `_machine_info` / `ensure_machine` | Linux ネイティブでは machine が存在しないため `podman machine inspect` が非ゼロ．`die "podman machine が存在しない"` で必ず落ちる | **Linux で致命**．Issue が指しているのはここ |
| 2 | 同 `check_disk` | 同上．machine が無いので warn を出して常にスキップ．ディスクチェックが機能しない | Linux で機能欠落 |
| 3 | 同 `require_podman` の案内文（`brew install podman`） | Linux / Windows で無意味な案内 | 文言のみ |
| 4 | 同 `compose_cmd` の案内文（`brew install podman-compose`） | 同上 | 文言のみ |
| 5 | `openmetadata/compose.override.yml` の `ports: !override` | `!override` タグは podman-compose 1.6.0 / Compose v2.24 以降でしか解釈されない．ディストリ同梱の古い podman-compose（例: Ubuntu 22.04 の 1.0.6）では解釈されず，ポート定義が upstream と二重になるか，パースエラーになる | **Linux で致命になりうる**．バージョン下限の明示が要る |
| 6 | `*/scripts/ingest.sh` の `podman run -v ...:ro` | SELinux enforcing のディストリ（Fedora / RHEL 系）では relabel なしの bind mount がコンテナから読めず Permission denied | **Linux で致命**（該当ディストリのみ） |
| 7 | `examples/postgres/compose.yml` の `../sample-data:/docker-entrypoint-initdb.d:ro`，`datahub/compose.upstream.yml` の `${HOME}/.datahub/plugins` 等 | 同上 | 同上 |
| 8 | `*/configs/**` と `ingest.sh` の `host.containers.internal` | podman 4.7 未満の rootless Linux ではこの名前が解決できず，インジェストがサンプル DB / GMS に到達できない | Linux で podman が古い場合に致命 |
| 9 | `curl` / `python3` / `base64` の存在を確認していない | macOS には標準で入るが，最小構成の Linux では未インストールがありうる．エラーが分かりにくい形で出る | Linux で UX 劣化 |
| 10 | `mem_limit`（両ツールの `compose.override.yml`，`examples/postgres/compose.yml`） | cgroup v1 の rootless Linux ではメモリ制限が無視される（podman が warn を出して継続） | 警告のみ．致命ではない |
| 11 | スクリプト全体（`mktemp` / `-v` のパス / `${HOME}`） | Windows の Git Bash（MSYS2）ではパスが Windows 形式へ自動変換され，`-v /tmp/xxx:/opt/...` が壊れる | **Windows ネイティブで致命**（3.1 参照） |

補足として，OS 非依存であることを確認済みの箇所も挙げておく．

- 公開ポートはすべて 1024 超（5432 / 8585 / 9002 / 8080 / 9200 / 3306）なので，rootless Linux でも bind できる．
- `sort -V` は macOS の BSD sort（2.3-Apple）でも GNU sort でも使える（実測）．バージョン比較に使える．
- `sed -i` は使っていない（BSD / GNU の差を踏まないで済む）．
- `mktemp -d` / `mktemp <template>` の使い方は BSD / GNU 両対応の書き方になっている．

## 3. 方針

### 3.1 対応範囲: Linux ネイティブと WSL2．Windows ネイティブは対象外（決定・2026-09-07）

| 実行環境 | 対応 | 理由 |
| --- | --- | --- |
| macOS + `podman machine` | 継続（現状維持） | 既存の検証環境 |
| Linux ネイティブ（rootless / rootful） | **対応する** | Issue の主目的 |
| Windows + WSL2 の中に podman を入れる | **対応する**（Linux ネイティブと同一経路） | 追加コストがほぼゼロ |
| Windows + `podman machine`（Podman Desktop，WSL バックエンド） | **対応する**（macOS と同一経路） | machine 判定を OS ではなく実体で行えば自動的に通る |
| Windows ネイティブの Git Bash / MSYS2 から `podman.exe` | **対象外**とする | #11 の通り，MSYS2 のパス変換（`MSYS2_ARG_CONV_EXCL` / `cygpath -w`）を全 `podman run` と `-v` に入れる必要があり，検証手段も無い |
| PowerShell / cmd | 対象外 | bash スクリプトのため |

**「Windows 対応 = WSL2 で動かす」と定義する．**
Podman 自体が Windows では WSL2 上の Linux で動く以上，
bash スクリプトを MSYS2 経由で動かす層を足しても得るものが少ない．
README にその旨を明記する．

この線引きは Issue の文面（「Linux/Windows に対応する」）より狭いが，
**Windows は WSL2 のみで良い**と確認が取れた（2026-09-07）．
Git Bash / MSYS2 経路は実装も検証もしない．

### 3.2 分岐は OS 名ではなく「podman machine を使うか」で行う

`uname` で macOS / Linux を見て分岐すると，Windows + Podman Desktop（machine あり）と
WSL2 内 podman（machine なし）を取り違える．**判定すべきは OS ではなく実行形態**．

```sh
# machine が 1 つでも定義されていれば machine モード．
# Linux ネイティブでは空行が返る（サブコマンド自体が失敗する場合もネイティブ扱い）．
uses_podman_machine() {
  podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .
}
```

- `podman machine list` は machine が停止中でも一覧を返すので，
  「起動していないと判定できない」問題が起きない（`podman info` の
  `Host.ServiceIsRemote` は machine 停止時に取れないため採らない）．
- OS 名（`uname -s` → `Darwin` / `Linux` / `MINGW*`）は，
  **案内文の出し分けとログ表示だけ**に使う．挙動の分岐には使わない．

### 3.3 リソースチェックを `ensure_resources` に一本化する

現状の `ensure_machine` / `check_disk` を，呼び出し側から見て 1 つの関数にまとめ，
内部で machine モード / ネイティブモードに分ける．

```
ensure_resources <required_mem_mib> <required_disk_gb>
├─ machine モード  : 既存の ensure_machine + check_disk をそのまま流用
│                    （machine 未作成なら init コマンドを案内して die．勝手に作らない方針は維持）
└─ ネイティブモード: /proc/meminfo の MemTotal と，
                     podman のストレージ領域（podman info の Store.GraphRoot，
                     取れなければ ${HOME}/.local/share/containers）に対する df -Pk を見る
```

呼び出し側（`openmetadata/scripts/up.sh` / `datahub/scripts/up.sh` /
`examples/postgres/scripts/up.sh`）は 2 行が 1 行になるだけで，要求値は変えない．

### 3.4 ネイティブモードでのリソース不足は warn に留める（決定・2026-09-07）

machine モードでは `podman machine set --memory` という**明確な直し方がある**ため die が妥当だった．
ネイティブでは物理メモリを増やせないので，同じ扱いにすると
「8GB 機では DataHub を起動する手段が無い」ことになる．

- メモリ: 不足していても **warn + 続行**．「OOM で落ちる可能性が高い」と明示する．
- ディスク: 現状の `check_disk` と同じく warn のみ（machine モードでも warn）．

「ネイティブでもメモリ不足なら die すべき」という選択肢もあったが，
**warn で続行**とする（2026-09-07 決定）．物理メモリは直せない以上，
起動を試す判断はユーザに委ねる方が良い．

### 3.5 SELinux とホスト解決名への対応

#### SELinux（#6 / #7）

`/sys/fs/selinux/enforce` が `1` のときだけ bind mount に `,Z` を付ける．
無条件に付けると macOS（machine 内の virtiofs マウント）で
relabel が失敗するリスクがあるため，**条件付きにする**．

```sh
# 例: podman run ... -v "${TMP_DIR}/x.yaml:/opt/.../x.yaml:ro$(selinux_mount_suffix)"
selinux_mount_suffix() {
  if [ -r /sys/fs/selinux/enforce ] && [ "$(cat /sys/fs/selinux/enforce)" = "1" ]; then
    printf ',Z'
  fi
}
```

compose 側（`examples/postgres/compose.yml` と DataHub upstream の
`${HOME}/.datahub/plugins`）は，シェルの関数では手が出せない．

- `examples/postgres/compose.yml` は自前のファイルなので `:ro,z` を直接書ける．
  `z`（共有ラベル）は非 SELinux 環境の podman では無視されるため，無条件に付けてよい．
- DataHub の upstream compose は**バイト列を変えない方針**なので触らない．
  `datahub/compose.override.yml` で同じ target を短縮構文＋`:z` で書き，
  マウント定義を置換する（volumes は target キーでマージされる仕様を利用．
  既存の override が `mem_limit` で使っているのと同じ手口）．

#### `host.containers.internal`（#8）

`podman run` する側（両ツールの `ingest.sh`）は，ネイティブモードのときだけ
`--add-host=host.containers.internal:host-gateway` を付けて，
podman のバージョンに関わらず名前が引けるようにする．
machine モードでは podman が既に定義しているので付けない（二重定義を避ける）．

これで `configs/**` の recipe / ingestion 定義は**現状のまま変更不要**になる．
（設定ファイルを OS ごとに分岐させない，というのがここでの狙い．）

### 3.6 依存コマンドとバージョン下限を先に検査する

`shared/scripts/preflight.sh` を新設し，`up.sh` の冒頭から呼ぶ．
`CLAUDE.md` のディレクトリ構成が既に `shared/scripts/ # preflight checks` と
書いているので，置き場所はそこに合わせる．
**独立したテストスイートは作らない方針**なので，これは検証専用スクリプトではなく
`up.sh` の前段チェックとして常に走る（単体でも実行できるようにはする）．

| 検査対象 | 下限 | 根拠 |
| --- | --- | --- |
| `podman` | 4.7 以上 | `host.containers.internal` が rootless で入るのが 4.7．Ubuntu 22.04 の 3.4.4 は弾く |
| compose provider | podman-compose 1.6.0 以上／`docker compose` 2.24 以上 | `!override` タグの解釈（#5） |
| `curl` | 存在確認のみ | `wait_http` / `status.sh` / `ingest.sh` |
| `python3` | 存在確認のみ | `ingest.sh` の JSON パース |
| `base64` | 存在確認のみ | OpenMetadata の admin ログイン |

案内文は `uname` で macOS / Linux / WSL を見て出し分ける
（macOS: `brew install ...`，Linux: `dnf install ...` / `apt install ...` の例と公式 URL）．

## 4. 実装ステップ（`jj` の論理単位）

1 ステップ = 1 `jj` change とする．

| # | change | 内容 | 触るファイル |
| --- | --- | --- | --- |
| 1 | `feat: 実行環境の判定とリソースチェックを OS 非依存にする` | 3.2 の `uses_podman_machine`，3.3 の `ensure_resources`，3.4 の warn 方針，3.6 の `require_cmd` / バージョン比較ヘルパ．案内文の出し分け | `shared/scripts/common.sh` |
| 2 | `feat: 事前チェックスクリプトを追加する` | 3.6 の `preflight.sh` 新設と，3 つの `up.sh` からの呼び出し．`ensure_machine` / `check_disk` の呼び出しを `ensure_resources` に置換 | `shared/scripts/preflight.sh`（新規），`openmetadata/scripts/up.sh`，`datahub/scripts/up.sh`，`examples/postgres/scripts/up.sh` |
| 3 | `feat: SELinux とホスト解決名を Linux ネイティブに対応させる` | 3.5．`ingest.sh` の `-v` に `selinux_mount_suffix`，`--add-host` の条件付き付与，compose 側の `:z` | `shared/scripts/common.sh`，`openmetadata/scripts/ingest.sh`，`datahub/scripts/ingest.sh`，`examples/postgres/compose.yml`，`datahub/compose.override.yml` |
| 4 | `docs: 対応 OS と OS ごとの前提環境を記載する` | 3.1 の線引き，OS 別のインストール手順とバージョン下限，WSL2 での実行方法，cgroup v1 の警告（#10）について | `README.md`，`examples/README.md`（`host.containers.internal` の記述），`docs/comparison.md`（検証環境の注記） |

ステップ 1 → 2 は順序依存．3 は 1 に依存．4 は最後．

## 5. 検証方法

macOS 実機しか無いため，Linux 経路は**代替手段で確認した上で，未確認箇所を明記する**．

1. **macOS での回帰**（必須）．`up.sh` → `ingest.sh` → `status.sh` → `down.sh` を
   両ツールで通し，既存の動作が変わっていないことを確認する．
   分岐を入れた以上，ここが壊れていないことが最優先．
2. **Linux ネイティブ経路の擬似検証**．`podman machine ssh` で入る Fedora CoreOS は
   **SELinux enforcing の Linux ネイティブ podman 環境**なので，
   `common.sh` / `preflight.sh` の判定（machine 無し・`/proc/meminfo`・`df`・
   `selinux_mount_suffix`）はここで実行して確認できる．
   ただしメモリが足りないため，スタック全体の起動は行わない．
   `examples/postgres` だけなら 512m なので起動できる可能性がある．
3. **shellcheck**．bash 3.2（macOS）と 5.x（Linux）の両方で解釈が変わらないことを静的に確認する．
4. **実 Linux 機での確認項目**（実施できたら）．
   - `up.sh` が machine チェックで落ちないこと（Issue の再現ケース）．
   - rootless で `host.containers.internal` 経由のインジェストが通ること．
   - SELinux enforcing のディストリで `ingest.sh` の bind mount が読めること．
   - 古い podman-compose を弾けること（#5）．

## 6. 確認済みのこと / 未確認のこと

**確認済み（このリポジトリと手元環境で確認した）**
- 2 章の依存箇所すべて（該当ファイルと行を読んで特定）．
- `podman machine list --format '{{.Name}}'` が macOS で machine 名を返し，終了コード 0 であること．
- `podman info` の `Host.ServiceIsRemote` が macOS で `true` を返すこと．
- `sort -V` が macOS の BSD sort でも動くこと．
- DataHub upstream compose の bind mount が `${HOME}/.aws` と `${HOME}/.datahub/plugins`（3 サービス）であること．
- upstream compose の bind mount が**長い構文**（`type: bind` / `source:`）で書かれていること．
  短縮構文＋`:z` の override で置換できるかは 3.5 の前提であり，未検証（下記）．

**未確認（推測で実装しない）**
- Linux ネイティブでの `podman machine list` の終了コードと出力（空で 0 を返す想定）．
- rootless Linux で `--add-host=host.containers.internal:host-gateway` を付けたとき，
  コンテナからホストの公開ポート（5432 / 8080）へ実際に到達できるか．
- 長い構文の bind mount を，短縮構文＋`:z` の override で置換できるか
  （podman-compose のマージ実装依存．できなければ #7 の DataHub 側は
  「SELinux 環境では `setsebool` か手動 relabel が要る」と README に書く方針へ切り替える）．
- Windows + Podman Desktop（WSL バックエンド）の `podman machine inspect` が，
  `.Resources.Memory` / `.Resources.DiskSize` を macOS と同じ単位（MiB / GB）で返すか．
- WSL2 内 podman での cgroup バージョン（v1 なら #10 の警告が出る）．
- 各ディストリが同梱する podman / podman-compose のバージョン分布
  （下限 4.7 / 1.6.0 が現実的かどうか．厳しすぎるなら公式リポジトリからの
  インストール手順を README に書く必要がある）．

## 7. 次のアクション

1. ~~3.1（対応範囲）を確定する~~ → Linux ネイティブ + WSL2．Git Bash は対象外（2026-09-07）．
2. ~~3.4（ネイティブでのメモリ不足の扱い）を確定する~~ → warn で続行（2026-09-07）．
3. 4 章のステップ 1 から着手する．
4. 6 章の未確認項目のうち，「短縮構文＋`:z` の override で置換できるか」は
   ステップ 3 の前提なので，着手前に手元の macOS で `podman compose config` の
   出力を見て確認しておく（実行はせずマージ結果だけ見れば分かる）．
