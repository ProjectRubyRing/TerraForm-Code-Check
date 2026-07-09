#!/usr/bin/env bash
#
# common.sh - 複数のスクリプトで共有するユーティリティ関数群
#
# 使い方:
#   このファイルを source して各関数を利用する。
#     source "$(dirname "$0")/common.sh"
#
#   DRY_RUN=true を設定すると run() は実コマンドを実行せず表示のみ行う。
#
# 注意: このファイル自体は単体実行を想定していない（source 専用）。
#
# ※ Codecommit_Git_Tags_S3_Upload プロジェクトの common.sh を基にしている。

# 既に読み込み済みなら何もしない（多重 source 対策）
#   注意: マーカー変数が環境に漏れていても、関数が未定義の新しいシェルでは
#   必ず定義し直すよう「変数あり かつ 関数定義済み」を読み込み済みの条件とする。
if [[ -n "${COMMON_SH_LOADED:-}" ]] && declare -F require_command >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi
COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# 色定義（端末が対応している場合のみ色を付ける）
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET="$(printf '\033[0m')"
  C_RED="$(printf '\033[31m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

# ---------------------------------------------------------------------------
# ログ関数
# ---------------------------------------------------------------------------
log_info()    { printf '%s[INFO]%s  %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_success() { printf '%s[OK]%s    %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()    { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

# エラーメッセージを出して終了する
# usage: die "メッセージ" [終了コード]
die() {
  local msg="$1"
  local code="${2:-1}"
  log_error "$msg"
  exit "$code"
}

# ---------------------------------------------------------------------------
# コマンド実行ヘルパー
#   DRY_RUN=true のときは実行内容を表示するだけで実行しない。
#   それ以外のときは表示してから実行する。
#
# usage: run terraform fmt -recursive
# ---------------------------------------------------------------------------
run() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '%s[DRY-RUN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
    return 0
  fi
  printf '%s[RUN]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
  "$@"
}

# ---------------------------------------------------------------------------
# 確認プロンプト
#   ASSUME_YES=true（--yes 相当）のときは確認せず yes とみなす。
#   DRY_RUN=true のときも確認をスキップする（破壊的操作は実行されないため）。
#
# usage: if confirm "本当に実行しますか?"; then ... ; fi
# 戻り値: yes -> 0, no -> 1
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-続行しますか?}"

  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run のため確認をスキップ)"
    return 0
  fi

  local reply
  read -r -p "$prompt [y/N]: " reply
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 必須コマンドの存在確認
# usage: require_command git
# ---------------------------------------------------------------------------
require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "コマンドが見つかりません: $cmd"
}

# ---------------------------------------------------------------------------
# デバッグログ
#   DEBUG=true のときだけ標準エラーへ出力する。
# ---------------------------------------------------------------------------
log_debug() {
  [[ "${DEBUG:-false}" == "true" ]] || return 0
  printf '%s[DEBUG]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

# ---------------------------------------------------------------------------
# AWS 認証チェック
#   事前に `aws login --remote` 等で認証済みか（= 有効な資格情報があるか）を
#   確認する。未認証なら警告メッセージを出して終了する。
#
# usage: require_aws_authenticated
# ---------------------------------------------------------------------------
require_aws_authenticated() {
  require_command aws

  local ident
  if ident="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
    log_debug "AWS 認証済み: ${ident}"
    return 0
  fi

  log_error "AWS が未認証です（有効な資格情報が見つかりません）。"
  log_error "  スクリプト実行前に、次のコマンドで認証してください:"
  log_error "      aws login --remote"
  exit 1
}

# ---------------------------------------------------------------------------
# 権限確認 + スイッチ（ロール/バック）共通処理
#
#   指定した「権限判定関数」を実行し、権限があれば何もしない。
#   権限が無い場合の挙動は auto フラグで切り替える:
#     - auto=false（既定） : 切替え方法を警告して終了する
#     - auto=true          : 専用シェルを source して切替え、再判定する
#                            （別チーム提供のスイッチ用シェルを source で呼び出す）
#
#   ※ source はカレントシェルで実行されるため、切替で設定される環境変数
#     （AWS_PROFILE / AWS_*_TOKEN 等）はそのまま後続処理に引き継がれる。
#
# usage:
#   ensure_permission_or_switch <ラベル> <判定関数名> <auto> <script_path> <切替名>
#     <ラベル>     : 表示用の操作名（例: CodeCommit / S3 / EC2）
#     <判定関数名> : 権限の有無を返す関数名（0=権限あり, 非0=権限なし）
#     <auto>       : true なら自動切替、false なら警告して終了
#     <script_path>: source する専用シェルのパス（自動切替時は必須）
#     <切替名>     : 表示用の切替操作名（例: スイッチロール / スイッチバック）
# ---------------------------------------------------------------------------
ensure_permission_or_switch() {
  local label="$1"
  local probe_fn="$2"
  local auto="$3"
  local script_path="$4"
  local switch_name="$5"

  if "${probe_fn}"; then
    log_debug "${label} への操作権限を確認しました。"
    return 0
  fi

  log_warn "現在の IAM 権限では ${label} への操作が許可されていません。"

  # --- 自動切替を行わない場合: 警告して終了 ---
  if [[ "${auto}" != "true" ]]; then
    log_error "${label} を操作するには${switch_name}してから再実行してください。"
    if [[ -n "${script_path}" ]]; then
      log_error "  例:  source \"${script_path}\""
    else
      log_error "  （別チーム提供の${switch_name}用シェルを source してください）"
    fi
    exit 1
  fi

  # --- 自動切替を行う場合: 専用シェルを source ---
  [[ -n "${script_path}" ]] || \
    die "${switch_name}を自動実行するには切替用シェルのパス指定が必要です。"
  [[ -f "${script_path}" ]] || \
    die "${switch_name}用シェルが見つかりません: ${script_path}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] ${switch_name}を実行します: source \"${script_path}\""
    return 0
  fi

  log_info "${switch_name}を自動実行します: source \"${script_path}\""
  # shellcheck source=/dev/null
  source "${script_path}" || \
    die "${switch_name}用シェルの実行に失敗しました: ${script_path}"

  # 切替後に再判定
  if "${probe_fn}"; then
    log_success "${switch_name}後、${label} への操作権限を確認しました。"
    return 0
  fi

  # ここに来たら「source は成功したのに権限判定だけ失敗」の状態。
  # 判定コマンドのフォールスネガティブ（無関係な権限やリージョン未解決、
  # 資格情報の export 漏れ等）が多いので、原因切り分け用の情報を提示する。
  log_error "${switch_name}を実行しましたが、${label} への操作権限を獲得できませんでした。"
  log_error "  ${switch_name}自体（source）は成功しています。権限「判定コマンド」が失敗しています。"
  log_error "  次の点を確認してください:"
  log_error "    1) リージョン: 既定判定は ec2:DescribeRegions を使うためリージョン解決が必要です。"
  log_error "                   --region <region>（例: ap-northeast-1）を指定してください。"
  log_error "    2) 判定内容 : 判定コマンドが切替先ロールの権限に合っているか。"
  log_error "                   合わない場合は --probe-command '<成功=権限ありとなるコマンド>' で差し替えてください。"
  log_error "    3) 資格情報 : ${switch_name}用シェルが AWS 資格情報を export しているか"
  log_error "                   （export されていないシェル変数は aws コマンドに引き継がれません）。"
  if command -v aws >/dev/null 2>&1; then
    local cur_arn
    cur_arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo '(取得失敗: 未認証の可能性)')"
    log_error "  現在の認証 ARN: ${cur_arn}"
  fi
  exit 1
}
