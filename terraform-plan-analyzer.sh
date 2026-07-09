#!/usr/bin/env bash
#
# terraform-plan-analyzer.sh
# ==========================
# EC2 (RHEL 9) 上で、Terraform の「ルートモジュール」ディレクトリを指定して
# terraform init / validate / plan を実行し、その plan の実行結果を極めて詳しく
# 分析して「日本語のレポート」を出力するスクリプトです。
#
# レポートの内容:
#   - 作成されるリソースの情報（アドレス / 種別 / 名前 / 主な属性）
#   - 修正されるリソースの情報（変更される属性ごとの 変更前 → 変更後）
#   - 削除・置換されるリソースの情報（純粋な削除か、削除→再作成の置換か、その理由）
#   - apply を実行した場合に問題が発生し得るコードの検知（リソース種別 × アクション
#     のヒューリスティック + provisioner / prevent_destroy 等の静的検知）
#   - 検討が必要なパラメータ指定の追加・修正検討のサポート
#     （モジュール入力の過不足 / default 依存 / apply 後まで値が確定しない属性 /
#       タグ未設定 / fmt 要否 など）
#   - 実際に設定されるタグの予想一覧（plan JSON の tags_all に基づく）
#
# 出力（--output-dir で指定したディレクトリに、必ず 2 ファイルを出力）:
#   1. 綺麗な Excel 形式  : *.xlsx（複数シート・色分け・見出し固定・オートフィルタ付き）
#                           OOXML(SpreadsheetML) を自前生成し zip 化して作成します。
#                           追加の pip パッケージ(openpyxl 等)は不要です。
#   2. ブラウザ表示形式    : *.html（自己完結・スタイル埋め込み・検索フィルタ付き）
#
# 依存:
#   - 必須 : bash, terraform, awk
#   - 準必須: jq（plan の詳細分析・タグ予想に必要。無い場合はテキストベースの簡易分析へ縮退）
#   - xlsx 生成: zip コマンド、無ければ python3（いずれも標準的に利用可能。RHEL9:
#              `sudo dnf install -y zip` / python3 は base に同梱）
# 共通部品: common.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. 共通部品(common.sh)の読み込み
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
  echo "[${SCRIPT_NAME}][ERROR] common.sh が見つかりません: ${SCRIPT_DIR}/common.sh" >&2
  exit 1
fi
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

TAB="$(printf '\t')"

# ---------------------------------------------------------------------------
# 1. 既定値
# ---------------------------------------------------------------------------
ROOT_DIR=""                 # ルートモジュールのディレクトリ（必須）
OUTPUT_DIR=""               # レポート(xlsx/html)の出力先ディレクトリ（必須）
REPORT_NAME=""              # 出力ファイルのベース名（未指定なら自動生成）
VAR_FILES=()                # terraform plan に渡す -var-file（繰り返し指定可）
VARS=()                     # terraform plan に渡す -var（繰り返し指定可）
BACKEND_CONFIGS=()          # terraform init に渡す -backend-config（繰り返し指定可）
REGION=""                   # AWS リージョン（AWS_REGION として export）
UPGRADE="false"             # true なら init -upgrade
NO_AWS_CHECK="false"        # true なら AWS 認証/権限チェックを行わない

# --- 認証 / 権限（スイッチバック）関連 ---
AUTO_SWITCH_BACK="false"
SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-}"
PROBE_COMMAND="${PROBE_COMMAND:-}"

DEBUG="${DEBUG:-false}"
export DEBUG

# --- 実行結果の状態 ---
OVERALL_RC=0                # 0=正常, 2=init/validate/plan にエラーあり
INIT_RC=0
# 権限判定で terraform init を実行済みかどうか（run_init での二重実行回避に使う）
PROBE_INIT_DONE="false"
PROBE_INIT_RC=0
PROBE_INIT_LOG=""
FMT_NEEDED=0
VALIDATE_ERRORS=0
VALIDATE_WARNINGS=0
PLAN_RC=0                   # 0=変更なし, 1=エラー, 2=変更あり
HAVE_JQ="false"
WORKDIR=""

# 変更件数の集計
CNT_CREATE=0
CNT_UPDATE=0
CNT_DELETE=0
CNT_REPLACE=0

# レポート出力先ファイル
XLSX_FILE=""
HTML_FILE=""

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --root-dir <dir> --output-dir <dir> [オプション]

説明:
  ルートモジュール <dir> で terraform init / validate / plan を実行し、
  その plan の結果（作成/修正/削除リソースの詳細、apply 時のリスク、検討すべき
  パラメータ、実際に付与されるタグの予想）を日本語で詳細に分析します。
  分析結果を、--output-dir に「Excel(.xlsx)」と「HTML」の 2 ファイルで出力します。

必須:
  --root-dir   <dir>      ルートモジュールのディレクトリ
  --output-dir <dir>      レポート(xlsx/html)の出力先ディレクトリ（無ければ作成）

Terraform 実行オプション:
  --var-file   <file>     plan に渡す -var-file（複数指定可）
  --var        <k=v>      plan に渡す -var（複数指定可）
  --backend-config <v>    init に渡す -backend-config（複数指定可。file または key=value）
  --upgrade               init に -upgrade を付ける
  --region     <region>   AWS リージョン（AWS_REGION として設定）

出力オプション:
  --report-name <name>    出力ファイルのベース名（既定: terraform-plan-report_<日時>）

認証 / 権限オプション:
  --auto-switch-back      AWS 操作権限が無い場合、警告終了せず自動でスイッチバックする
  --switch-back-script <path>
                          自動スイッチバック時に source する専用シェルのパス
                          （別チーム提供。環境変数 SWITCH_BACK_SCRIPT でも指定可）
  --probe-command <cmd>   AWS 操作権限の有無を判定するコマンド（成功=権限あり）。
                          既定は特定 API に依存せず「terraform init が通るか」で判定
                          します（backend 初期化に必要な権限をそのままテスト。判定時の
                          init 結果は本実行の init に再利用します）。特定 API で判定
                          したい場合のみ本オプションで差し替えてください
                          （例: --probe-command "aws s3api head-bucket --bucket my-tfstate"）。
  --no-aws-check          AWS 認証/権限チェックを行わない（backend がローカルの場合など）

その他:
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

例:
  ./${SCRIPT_NAME} --root-dir /opt/terraform/envs/prod --output-dir /tmp/report
  ./${SCRIPT_NAME} --root-dir /opt/terraform/envs/prod --output-dir /tmp/report \\
    --var-file /opt/terraform/envs/prod/prod.tfvars --region ap-northeast-1

終了コード:
  0  分析完了（validate/plan にエラーなし。差分の有無は問わない）
  1  スクリプト自体のエラー（引数不正、認証・権限エラー、依存コマンド不足など）
  2  分析完了したが init/validate/plan のいずれかでエラーを検出
USAGE
}

# ---------------------------------------------------------------------------
# 3. 引数パース
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --root-dir)       ROOT_DIR="${2:-}"; shift 2 ;;
      --output-dir)     OUTPUT_DIR="${2:-}"; shift 2 ;;
      --report-name)    REPORT_NAME="${2:-}"; shift 2 ;;
      --var-file)       VAR_FILES+=("${2:-}"); shift 2 ;;
      --var)            VARS+=("${2:-}"); shift 2 ;;
      --backend-config) BACKEND_CONFIGS+=("${2:-}"); shift 2 ;;
      --region)         REGION="${2:-}"; shift 2 ;;
      --upgrade)        UPGRADE="true"; shift 1 ;;
      --auto-switch-back)   AUTO_SWITCH_BACK="true"; shift 1 ;;
      --switch-back-script) SWITCH_BACK_SCRIPT="${2:-}"; shift 2 ;;
      --probe-command)  PROBE_COMMAND="${2:-}"; shift 2 ;;
      --no-aws-check)   NO_AWS_CHECK="true"; shift 1 ;;
      --debug)          DEBUG="true"; export DEBUG; shift 1 ;;
      -h|--help)        usage; exit 0 ;;
      *)                usage; die "不明なオプションです: ${1}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 4. 入力検証
# ---------------------------------------------------------------------------
validate_inputs() {
  [[ -n "${ROOT_DIR}" ]]   || { usage; die "--root-dir は必須です。"; }
  [[ -n "${OUTPUT_DIR}" ]] || { usage; die "--output-dir は必須です。"; }
  [[ -d "${ROOT_DIR}" ]]   || die "ルートモジュールのディレクトリが存在しません: ${ROOT_DIR}"
  ROOT_DIR="$(cd "${ROOT_DIR}" && pwd)"

  local tf_count
  tf_count="$(find "${ROOT_DIR}" -maxdepth 1 -name '*.tf' -type f 2>/dev/null | wc -l)"
  [[ "${tf_count}" -gt 0 ]] || die "ルートモジュールに .tf ファイルが見つかりません: ${ROOT_DIR}"

  local vf
  for vf in "${VAR_FILES[@]:-}"; do
    [[ -z "${vf}" ]] && continue
    [[ -f "${vf}" ]] || die "--var-file が見つかりません: ${vf}"
  done

  mkdir -p "${OUTPUT_DIR}" || die "出力先ディレクトリを作成できません: ${OUTPUT_DIR}"
  OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

  local ts base
  ts="$(date +%Y%m%d-%H%M%S)"
  base="${REPORT_NAME:-terraform-plan-report_${ts}}"
  # ファイル名に使えない文字を除去
  base="$(printf '%s' "${base}" | tr -c 'A-Za-z0-9._-' '_')"
  XLSX_FILE="${OUTPUT_DIR}/${base}.xlsx"
  HTML_FILE="${OUTPUT_DIR}/${base}.html"
}

# ---------------------------------------------------------------------------
# 4b. AWS 操作権限の判定
#     既定判定は「実際に terraform init が通るか」で行う（= backend 初期化に
#     必要な AWS 権限があるか）。特定の AWS API（ec2:DescribeRegions 等）に
#     依存すると、その権限を持たない運用ロールでフォールスネガティブになるため、
#     tool が実際に必要とする操作そのものをテストする。
#     --probe-command 指定時はそのコマンド（成功=権限あり）で判定する。
# ---------------------------------------------------------------------------
probe_aws_permission() {
  if [[ -n "${PROBE_COMMAND}" ]]; then
    log_debug "権限判定コマンド: ${PROBE_COMMAND}"
    bash -c "${PROBE_COMMAND}" >/dev/null 2>&1
    return
  fi

  # 既定判定: terraform init を実行して成否を見る。
  # 判定結果（ログと終了コード）は run_init で再利用し、二重実行を避ける。
  local init_args=(init -input=false -no-color)
  [[ "${UPGRADE}" == "true" ]] && init_args+=(-upgrade)
  local bc
  for bc in "${BACKEND_CONFIGS[@]:-}"; do
    [[ -n "${bc}" ]] && init_args+=(-backend-config="${bc}")
  done

  # ログの置き場所（WORKDIR はまだ無いので専用の一時ファイルを使い回す）
  if [[ -z "${PROBE_INIT_LOG}" ]]; then
    PROBE_INIT_LOG="$(mktemp "${TMPDIR:-/tmp}/tfplan-probe-init.XXXXXX.log")" \
      || { log_warn "権限判定用の一時ログを作成できませんでした。"; return 1; }
  fi

  log_debug "権限判定: terraform -chdir=${ROOT_DIR} ${init_args[*]}"
  local rc=0
  terraform -chdir="${ROOT_DIR}" "${init_args[@]}" > "${PROBE_INIT_LOG}" 2>&1 || rc=$?
  PROBE_INIT_RC="${rc}"
  PROBE_INIT_DONE="true"
  if [[ "${rc}" -ne 0 ]]; then
    log_debug "権限判定の terraform init が失敗しました（rc=${rc}）。ログ: ${PROBE_INIT_LOG}"
  fi
  return "${rc}"
}

# ---------------------------------------------------------------------------
# 5. 前提確認（依存コマンド / 認証 / 権限）
# ---------------------------------------------------------------------------
preflight() {
  require_command terraform
  require_command awk

  if command -v jq >/dev/null 2>&1; then
    HAVE_JQ="true"
  else
    log_warn "jq が見つかりません。plan の詳細分析とタグ予想はテキストベースの簡易分析に縮退します。"
    log_warn "  （RHEL9: sudo dnf install -y jq でインストールできます）"
  fi

  if ! command -v zip >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    die "xlsx 生成には zip コマンドまたは python3 が必要です（RHEL9: sudo dnf install -y zip）。"
  fi

  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  if [[ "${NO_AWS_CHECK}" == "true" ]]; then
    log_info "AWS 認証/権限チェックをスキップします（--no-aws-check）。"
    return 0
  fi

  require_command aws
  require_aws_authenticated
  ensure_permission_or_switch \
    "AWS (Terraform init/plan)" probe_aws_permission \
    "${AUTO_SWITCH_BACK}" "${SWITCH_BACK_SCRIPT}" "スイッチバック"
  log_debug "AWS 操作権限の確認 OK。"
}

# ---------------------------------------------------------------------------
# 5b. 作業ディレクトリ（ログ・中間 TSV 置き場）
# ---------------------------------------------------------------------------
setup_workdir() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tfplan-${ts}.XXXX")" \
    || die "作業ディレクトリの作成に失敗しました。"
  log_info "作業ディレクトリ（ログ/中間ファイル）: ${WORKDIR}"
  log_warn "plan ファイルには機密値が含まれる場合があります。不要になったら削除してください。"

  # 各分析結果の中間 TSV（ヘッダは含めない。ヘッダはレポート出力時に付与）
  SUMMARY_TSV="${WORKDIR}/summary.tsv"       # 項目 / 結果 / 詳細
  CREATE_TSV="${WORKDIR}/create.tsv"         # アドレス / 種別 / 名前 / 主な属性
  UPDATE_TSV="${WORKDIR}/update.tsv"         # アドレス / 種別 / 属性 / 変更前 / 変更後
  DELETE_TSV="${WORKDIR}/delete.tsv"         # アドレス / 種別 / 区分 / 理由
  RISKS_TSV="${WORKDIR}/risks.tsv"           # 重大度 / 対象 / アクション / リスク内容 / 対処・確認事項
  PARAMS_TSV="${WORKDIR}/params.tsv"         # 分類 / 対象 / 指摘内容 / 推奨対応
  TAGS_TSV="${WORKDIR}/tags.tsv"             # リソース / 種別 / タグキー / 予想値 / 由来
  VALIDATE_TSV="${WORKDIR}/validate.tsv"     # 重大度 / 概要 / 詳細 / ファイル / 行 / ヒント
  META_TSV="${WORKDIR}/meta.tsv"             # 項目 / 内容
  CHANGES_TSV="${WORKDIR}/changes.tsv"       # アドレス / 種別 / アクション / 理由（内部用）
  : > "${SUMMARY_TSV}"; : > "${CREATE_TSV}"; : > "${UPDATE_TSV}"; : > "${DELETE_TSV}"
  : > "${RISKS_TSV}"; : > "${PARAMS_TSV}"; : > "${TAGS_TSV}"; : > "${VALIDATE_TSV}"
  : > "${META_TSV}"; : > "${CHANGES_TSV}"

  setup_awk_scripts
}

# ---------------------------------------------------------------------------
# 5c. HCL 簡易パーサ（awk） - モジュール入力の過不足分析用
# ---------------------------------------------------------------------------
setup_awk_scripts() {
  cat > "${WORKDIR}/parse_modules.awk" <<'AWK'
FNR==1 { inmod=0; depth=0 }
{
  line=$0
  sub(/\r$/,"",line)
  if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*\/\//) next
  if (inmod==0) {
    if (line ~ /^[[:space:]]*module[[:space:]]+"[^"]+"/) {
      name=line
      sub(/^[[:space:]]*module[[:space:]]+"/,"",name)
      sub(/".*$/,"",name)
      printf "MODULE\t%s\t%s\n", name, FILENAME
      inmod=1; depth=0
      depth += gsub(/\{/,"{",line) - gsub(/\}/,"}",line)
      if (depth<=0) inmod=0
    }
    next
  }
  if (depth==1 && line ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*=/) {
    key=line
    sub(/^[[:space:]]*/,"",key)
    sub(/[[:space:]]*=.*$/,"",key)
    val=line
    sub(/^[^=]*=[[:space:]]*/,"",val)
    printf "ARG\t%s\t%s\t%s\n", name, key, val
  }
  depth += gsub(/\{/,"{",line) - gsub(/\}/,"}",line)
  if (depth<=0) inmod=0
}
AWK

  cat > "${WORKDIR}/parse_variables.awk" <<'AWK'
FNR==1 { inv=0; depth=0 }
{
  line=$0
  sub(/\r$/,"",line)
  if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*\/\//) next
  if (inv==0) {
    if (line ~ /^[[:space:]]*variable[[:space:]]+"[^"]+"/) {
      vname=line
      sub(/^[[:space:]]*variable[[:space:]]+"/,"",vname)
      sub(/".*$/,"",vname)
      inv=1; depth=0; hasdef=0; vtype="-"; vdef="-"
      depth += gsub(/\{/,"{",line) - gsub(/\}/,"}",line)
      if (depth<=0) {
        printf "VAR\t%s\trequired\t-\t-\n", vname
        inv=0
      }
    }
    next
  }
  if (depth==1) {
    if (line ~ /^[[:space:]]*default[[:space:]]*=/) {
      hasdef=1
      vdef=line
      sub(/^[[:space:]]*default[[:space:]]*=[[:space:]]*/,"",vdef)
    } else if (line ~ /^[[:space:]]*type[[:space:]]*=/) {
      vtype=line
      sub(/^[[:space:]]*type[[:space:]]*=[[:space:]]*/,"",vtype)
    }
  }
  depth += gsub(/\{/,"{",line) - gsub(/\}/,"}",line)
  if (depth<=0) {
    printf "VAR\t%s\t%s\t%s\t%s\n", vname, (hasdef ? "optional" : "required"), vtype, vdef
    inv=0
  }
}
AWK
}

# ---------------------------------------------------------------------------
# 5d. 記録ヘルパー
# ---------------------------------------------------------------------------
section() {
  printf '\n%s\n %s\n%s\n' \
    "==============================================================================" \
    "$*" \
    "=============================================================================="
}
add_meta()    { printf '%s\t%s\n' "$1" "$2" >> "${META_TSV}"; }
add_summary() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${SUMMARY_TSV}"; }
add_risk()    { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "${RISKS_TSV}"; }
add_param()   { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${PARAMS_TSV}"; }

# ---------------------------------------------------------------------------
# 5e. terraform エラーログの原因分析（init / plan 共通）
# ---------------------------------------------------------------------------
analyze_tf_error_log() {
  local log="$1" ctx="$2" found=0
  _hint() {
    found=1
    log_error "  [原因分析] $1"
    log_error "    → 対処: $2"
    add_param "${ctx} エラー" "ログ: ${log}" "$1" "$2"
  }
  if grep -qiE "No valid credential sources|failed to refresh cached credentials|Unable to locate credentials" "${log}"; then
    _hint "AWS 資格情報が見つからない/取得できない" "aws login --remote で再認証し、AWS_PROFILE 等の環境変数を確認する"
  fi
  if grep -qiE "ExpiredToken|security token included in the request is expired" "${log}"; then
    _hint "一時認証トークンの期限切れ" "aws login --remote で再認証する"
  fi
  if grep -qiE "InvalidClientTokenId|SignatureDoesNotMatch" "${log}"; then
    _hint "資格情報が不正（トークン/キーの不一致）" "認証をやり直す。スイッチロール中なら正しいロールか確認する"
  fi
  if grep -qiE "AccessDenied|UnauthorizedOperation|not authorized to perform|status code: 403" "${log}"; then
    _hint "IAM 権限不足（AccessDenied）" "必要な権限を持つロールへスイッチ（またはスイッチバック）する。backend の S3/DynamoDB 権限も確認"
  fi
  if grep -qiE "Error acquiring the state lock" "${log}"; then
    _hint "state ロックの取得失敗（他の実行がロック保持中）" "他の terraform 実行の完了を待つ。異常残留なら terraform force-unlock <LOCK_ID> を関係者確認の上で実行"
  fi
  if grep -qiE "NoSuchBucket|bucket does not exist" "${log}"; then
    _hint "backend の S3 バケットが存在しない" "backend 設定のバケット名/リージョン、-backend-config の値を確認する"
  fi
  if grep -qiE "Backend configuration changed|Backend initialization required" "${log}"; then
    _hint "backend 設定が変更されている" "terraform init -reconfigure（state 移行が必要なら -migrate-state）を実行する"
  fi
  if grep -qiE "Failed to query available provider packages|could not connect to registry|no such host|connection refused|i/o timeout|TLS handshake timeout" "${log}"; then
    _hint "プロバイダ/レジストリへのネットワーク接続失敗" "プロキシ設定(HTTPS_PROXY)・レジストリミラー・DNS を確認する"
  fi
  if grep -qiE "Unsupported Terraform Core version" "${log}"; then
    _hint "terraform 本体のバージョンが required_version を満たさない" "versions.tf の required_version と terraform version を突き合わせ、tfenv 等で切り替える"
  fi
  if grep -qiE "No value for required variable" "${log}"; then
    _hint "必須変数が未指定" "-var / -var-file（--var / --var-file オプション）で値を渡すか、default を定義する"
  fi
  if grep -qiE "Cycle:" "${log}"; then
    _hint "リソース間の循環参照" "depends_on や参照関係を見直して循環を解消する"
  fi
  if grep -qE "Unsupported argument" "${log}"; then
    _hint "モジュール/ブロックに宣言されていない引数を渡している" "引数名の誤記、またはモジュール側の variable 宣言漏れを確認する"
  fi
  if grep -qE "Missing required argument" "${log}"; then
    _hint "必須の引数（モジュールの必須変数など）が渡されていない" "モジュール呼び出しに不足している引数を追加する"
  fi
  if grep -qiE "Module not installed|module must be installed|Unreadable module directory" "${log}"; then
    _hint "モジュールが未取得/取得不能（source パス誤り等）" "module の source パスを確認し、terraform init（または -upgrade）でモジュールを再取得する"
  fi
  if [[ "${found}" -eq 0 ]]; then
    log_error "  [原因分析] 既知パターンに一致しませんでした。ログ全文を確認してください: ${log}"
    add_param "${ctx} エラー" "ログ: ${log}" "既知パターン外のエラー" "ログ全文を確認してください"
  fi
}

# ---------------------------------------------------------------------------
# 6. terraform init
# ---------------------------------------------------------------------------
run_init() {
  section "[1/6] terraform init"
  local log="${WORKDIR}/init.log"

  # 権限判定（既定判定）の段階で terraform init を実行済みなら、その結果を再利用し
  # 二重実行を避ける。--probe-command 使用時や --no-aws-check 時は未実行なので通常実行。
  if [[ "${PROBE_INIT_DONE}" == "true" ]]; then
    log_info "権限判定時に実行した terraform init の結果を再利用します。"
    if [[ -n "${PROBE_INIT_LOG}" && -f "${PROBE_INIT_LOG}" ]]; then
      cp -f "${PROBE_INIT_LOG}" "${log}" 2>/dev/null || : > "${log}"
      rm -f "${PROBE_INIT_LOG}"
    else
      : > "${log}"
    fi
    INIT_RC="${PROBE_INIT_RC}"
  else
    local init_args=(init -input=false -no-color)
    [[ "${UPGRADE}" == "true" ]] && init_args+=(-upgrade)
    local bc
    for bc in "${BACKEND_CONFIGS[@]:-}"; do
      [[ -n "${bc}" ]] && init_args+=(-backend-config="${bc}")
    done
    log_info "実行: terraform -chdir=${ROOT_DIR} ${init_args[*]}"
    INIT_RC=0
    terraform -chdir="${ROOT_DIR}" "${init_args[@]}" > "${log}" 2>&1 || INIT_RC=$?
  fi

  if [[ "${INIT_RC}" -eq 0 ]]; then
    log_success "init 成功。プロバイダ・モジュールの取得と backend 初期化が完了しました。"
    add_summary "terraform init" "成功" "backend 初期化・プロバイダ/モジュール取得が完了"
  else
    OVERALL_RC=2
    log_error "init 失敗（終了コード: ${INIT_RC}）。エラー抜粋:"
    grep -E "Error|error" "${log}" | head -n 10 | sed 's/^/    /' >&2 || true
    add_summary "terraform init" "失敗" "ログ: ${log}"
    analyze_tf_error_log "${log}" "init"
    log_error "init に失敗したため、validate / plan は実行できません。"
  fi
}

# ---------------------------------------------------------------------------
# 7. terraform fmt（整形要否の確認。パラメータ検討の材料として利用）
# ---------------------------------------------------------------------------
run_fmt_check() {
  section "[2/6] terraform fmt（コード整形チェック）"
  local out="${WORKDIR}/fmt.log" rc=0
  terraform -chdir="${ROOT_DIR}" fmt -check -recursive -no-color > "${out}" 2>&1 || rc=$?
  FMT_NEEDED=0
  if [[ "${rc}" -eq 0 ]]; then
    log_success "全ファイル整形済みです。"
    add_summary "terraform fmt" "整形不要" "全ファイル整形済み"
  elif [[ "${rc}" -eq 3 ]]; then
    FMT_NEEDED="$(grep -c . "${out}" || true)"
    log_warn "整形が必要なファイルが ${FMT_NEEDED} 件あります。"
    add_summary "terraform fmt" "整形必要 (${FMT_NEEDED} 件)" "terraform fmt -recursive で整形可能"
    local f
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      add_param "コード整形" "${f}" "terraform の推奨フォーマットに未整形" "terraform -chdir=${ROOT_DIR} fmt -recursive で整形（意味は変わらず空白/インデントのみ修正）"
    done < "${out}"
  else
    log_warn "fmt チェック自体が失敗しました（構文エラーの可能性）。ログ: ${out}"
    add_summary "terraform fmt" "チェック失敗" "構文エラーの可能性（validate 結果を参照）"
  fi
}

# ---------------------------------------------------------------------------
# 8. terraform validate（実行と結果分析）
# ---------------------------------------------------------------------------
validate_hint() {
  case "$1" in
    *"Unsupported argument"*) echo "引数名の誤記、またはモジュール側 variables.tf に無い引数を渡している。宣言と綴りを確認" ;;
    *"Missing required argument"*) echo "必須引数の未指定。リソース/モジュールの必須項目を追加する" ;;
    *"Reference to undeclared input variable"*) echo "宣言されていない変数を参照。variables.tf に variable を追加するか参照名を修正する" ;;
    *"Reference to undeclared resource"*|*"Reference to undeclared module"*) echo "存在しないリソース/モジュールを参照。アドレスの綴りと定義の有無を確認する" ;;
    *"Duplicate"*) echo "同名定義の重複。ファイル間で resource/variable/output 等を二重定義していないか確認する" ;;
    *"Module not installed"*|*"module is not yet installed"*) echo "モジュール未取得。terraform init を（再）実行する" ;;
    *"Invalid function argument"*) echo "関数の引数の型/形式が不正。merge・lookup・format 等に渡す値を確認する" ;;
    *"Invalid for_each argument"*) echo "for_each に apply 後まで確定しない値、または map/set 以外を渡している可能性" ;;
    *"Invalid count argument"*) echo "count に apply 後まで確定しない値を渡している可能性。段階適用(-target)か設計見直しを検討" ;;
    *"Unsupported block type"*) echo "ブロック名の誤記、またはプロバイダのバージョン不足。required_providers の version を確認する" ;;
    *"Provider configuration not present"*|*"provider configuration is required"*) echo "provider 設定の不整合。provider はルートで定義しモジュールへは providers 引数で渡す" ;;
    *"Inconsistent conditional result types"*) echo "三項演算子(condition ? a : b)の両辺の型が不一致" ;;
    *"Invalid value for input variable"*|*"Invalid value for variable"*) echo "variable の validation / 型制約に違反する値。tfvars と variable の type/validation を確認する" ;;
    *) echo "-" ;;
  esac
}

run_validate() {
  section "[3/6] terraform validate（構文・整合性チェック）"
  if [[ "${INIT_RC}" -ne 0 ]]; then
    log_warn "init が失敗しているため validate をスキップします。"
    add_summary "terraform validate" "スキップ" "init 失敗のため"
    return 0
  fi

  local vjson="${WORKDIR}/validate.json" rc=0
  terraform -chdir="${ROOT_DIR}" validate -json > "${vjson}" 2> "${WORKDIR}/validate.err" || rc=$?
  if [[ ! -s "${vjson}" ]]; then
    OVERALL_RC=2
    log_error "validate の実行自体に失敗しました。stderr: $(head -n 5 "${WORKDIR}/validate.err" 2>/dev/null)"
    add_summary "terraform validate" "実行失敗" "ログ: ${WORKDIR}/validate.err"
    return 0
  fi

  if [[ "${HAVE_JQ}" == "true" ]]; then
    VALIDATE_ERRORS="$(jq -r '.error_count // 0' "${vjson}")"
    VALIDATE_WARNINGS="$(jq -r '.warning_count // 0' "${vjson}")"
    jq -r '.diagnostics[]? | [
        .severity, (.summary // "-"),
        ((.detail // "-") | gsub("\n"; " ")),
        (.range.filename // "-"), ((.range.start.line // 0) | tostring)
      ] | @tsv' "${vjson}" > "${WORKDIR}/validate_diag.tsv" || true
    local sev summary detail file lineno
    while IFS="${TAB}" read -r sev summary detail file lineno; do
      [[ -z "${sev}" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${sev}" "${summary}" "${detail}" "${file}" "${lineno}" "$(validate_hint "${summary}")" \
        >> "${VALIDATE_TSV}"
    done < "${WORKDIR}/validate_diag.tsv"
  else
    if grep -q '"valid":[[:space:]]*true' "${vjson}"; then
      VALIDATE_ERRORS=0
    else
      VALIDATE_ERRORS=1
      printf 'error\t(jq 無しのため詳細解析不可)\t%s\t-\t-\t-\n' "validate.json を直接確認: ${vjson}" >> "${VALIDATE_TSV}"
    fi
    VALIDATE_WARNINGS=0
  fi

  if [[ "${VALIDATE_ERRORS}" -eq 0 && "${VALIDATE_WARNINGS}" -eq 0 ]]; then
    log_success "validate 成功。構文エラー・引数の過不足・未宣言参照は検出されませんでした。"
    add_summary "terraform validate" "成功" "エラー 0 件 / 警告 0 件"
    return 0
  fi
  if [[ "${VALIDATE_ERRORS}" -gt 0 ]]; then
    OVERALL_RC=2
    log_error "validate でエラー ${VALIDATE_ERRORS} 件、警告 ${VALIDATE_WARNINGS} 件を検出しました。"
  else
    log_warn "validate で警告 ${VALIDATE_WARNINGS} 件を検出しました（エラーはありません）。"
  fi
  add_summary "terraform validate" "エラー ${VALIDATE_ERRORS} 件 / 警告 ${VALIDATE_WARNINGS} 件" "詳細は「validate 診断」シートを参照"
}

# ---------------------------------------------------------------------------
# 9. terraform plan（実行と結果分析）
# ---------------------------------------------------------------------------
run_plan() {
  section "[4/6] terraform plan（実行計画の作成と結果分析）"
  if [[ "${INIT_RC}" -ne 0 ]]; then
    log_warn "init が失敗しているため plan をスキップします。"
    add_summary "terraform plan" "スキップ" "init 失敗のため"
    PLAN_RC=-1; return 0
  fi
  if [[ "${VALIDATE_ERRORS}" -gt 0 ]]; then
    log_warn "validate エラーがあるため plan をスキップします。"
    add_summary "terraform plan" "スキップ" "validate エラーのため"
    PLAN_RC=-1; return 0
  fi

  PLAN_BIN="${WORKDIR}/plan.bin"
  PLAN_LOG="${WORKDIR}/plan.log"
  PLAN_JSON="${WORKDIR}/plan.json"

  local plan_args=(plan -input=false -no-color -detailed-exitcode -out="${PLAN_BIN}")
  local vf v
  for vf in "${VAR_FILES[@]:-}"; do
    [[ -n "${vf}" ]] && plan_args+=(-var-file="$(cd "$(dirname "${vf}")" && pwd)/$(basename "${vf}")")
  done
  for v in "${VARS[@]:-}"; do
    [[ -n "${v}" ]] && plan_args+=(-var "${v}")
  done

  log_info "実行: terraform -chdir=${ROOT_DIR} plan ...（ログ: ${PLAN_LOG}）"
  PLAN_RC=0
  terraform -chdir="${ROOT_DIR}" "${plan_args[@]}" > "${PLAN_LOG}" 2>&1 || PLAN_RC=$?

  case "${PLAN_RC}" in
    0)
      log_success "plan 成功: 変更はありません（コードと実環境/state が一致）。"
      add_summary "terraform plan" "成功（変更なし）" "コードと実環境が一致" ;;
    2)
      log_warn "plan 成功: 適用されていない変更があります。"
      add_summary "terraform plan" "成功（変更あり）" "$(grep -E '^Plan:' "${PLAN_LOG}" | tail -n 1 || echo '差分あり')" ;;
    *)
      OVERALL_RC=2
      log_error "plan 失敗（終了コード: ${PLAN_RC}）。エラー抜粋:"
      grep -E "Error" "${PLAN_LOG}" | head -n 10 | sed 's/^/    /' >&2 || true
      add_summary "terraform plan" "失敗" "ログ: ${PLAN_LOG}"
      analyze_tf_error_log "${PLAN_LOG}" "plan"
      return 0 ;;
  esac

  # plan JSON を生成
  if [[ "${HAVE_JQ}" == "true" && -f "${PLAN_BIN}" ]]; then
    terraform -chdir="${ROOT_DIR}" show -json "${PLAN_BIN}" > "${PLAN_JSON}" 2>/dev/null || true
  fi

  if [[ -s "${PLAN_JSON:-/nonexistent}" ]]; then
    extract_changes_from_json
  else
    extract_changes_from_text
  fi
}

# plan JSON から作成/修正/削除リソース情報を抽出（jq 使用）
extract_changes_from_json() {
  # 内部用: アドレス / 種別 / アクション / 理由（リスク分析で使用）
  jq -r '.resource_changes[]?
         | (.change.actions | join("+")) as $a
         | select($a != "no-op" and $a != "read")
         | [.address, .type, $a, (.action_reason // "-")] | @tsv' \
    "${PLAN_JSON}" > "${CHANGES_TSV}" || true

  # --- 作成リソース ---
  jq -r '.resource_changes[]?
    | select((.change.actions // []) == ["create"])
    | . as $rc | ($rc.change.after // {}) as $a
    | [ $rc.address, $rc.type,
        ( $a.name // $a.bucket // $a.function_name // $a.identifier // $a.tags.Name // "-" ),
        ( ["instance_type","cidr_block","engine","engine_version","runtime","ami","image_id",
           "port","protocol","policy_arn","role","vpc_id","subnet_id","availability_zone","family"]
          | map( . as $k | if ($a | has($k)) and ($a[$k] != null)
                           then "\($k)=\($a[$k] | tostring)" else empty end )
          | join(", ") ) ]
    | @tsv' "${PLAN_JSON}" > "${CREATE_TSV}" || true

  # --- 修正リソース（属性ごとの 変更前 → 変更後） ---
  jq -r '
    def trunc: tostring | if (length > 500) then (.[0:500] + " …") else . end;
    .resource_changes[]?
    | select((.change.actions // []) | index("update"))
    | select(((.change.actions // []) | index("create")) | not)
    | . as $rc
    | ($rc.change.before // {}) as $b
    | ($rc.change.after  // {}) as $a
    | ($rc.change.after_unknown // {}) as $u
    | ( [$b, $a] | add | keys_unstable | unique ) as $ks
    | $ks[] | . as $k
    | ($b[$k]) as $bv | ($a[$k]) as $av | ($u[$k]) as $uv
    | select( ($uv == true) or ($bv != $av) )
    | [ $rc.address, $rc.type, $k,
        ( if $bv == null then "(なし)" else ($bv | trunc) end ),
        ( if $uv == true then "(apply後に確定)" elif $av == null then "(なし)" else ($av | trunc) end ) ]
    | @tsv' "${PLAN_JSON}" > "${UPDATE_TSV}" || true

  # --- 削除・置換リソース ---
  jq -r '.resource_changes[]?
    | (.change.actions // []) as $ac
    | select($ac | index("delete"))
    | [ .address, .type,
        ( if ($ac | index("create")) then "置換（削除→再作成）" else "削除" end ),
        (.action_reason // "-") ]
    | @tsv' "${PLAN_JSON}" > "${DELETE_TSV}" || true

  # --- 件数集計 ---
  CNT_CREATE="$(jq -r '[.resource_changes[]? | select((.change.actions//[])==["create"])] | length' "${PLAN_JSON}" 2>/dev/null || echo 0)"
  CNT_UPDATE="$(jq -r '[.resource_changes[]? | select(((.change.actions//[])|index("update")) and (((.change.actions//[])|index("create"))|not))] | length' "${PLAN_JSON}" 2>/dev/null || echo 0)"
  CNT_REPLACE="$(jq -r '[.resource_changes[]? | select(((.change.actions//[])|index("delete")) and ((.change.actions//[])|index("create")))] | length' "${PLAN_JSON}" 2>/dev/null || echo 0)"
  CNT_DELETE="$(jq -r '[.resource_changes[]? | select((.change.actions//[])==["delete"])] | length' "${PLAN_JSON}" 2>/dev/null || echo 0)"

  log_info "変更集計: 作成 ${CNT_CREATE} / 修正 ${CNT_UPDATE} / 置換 ${CNT_REPLACE} / 削除 ${CNT_DELETE}"

  # 出力値の変更
  local outchg="${WORKDIR}/output_changes.tsv"
  jq -r '.output_changes // {} | to_entries[]
         | select((.value.actions | join(",")) != "no-op")
         | [.key, (.value.actions | join("+"))] | @tsv' "${PLAN_JSON}" > "${outchg}" 2>/dev/null || true
  if [[ -s "${outchg}" ]]; then
    local ok oa
    while IFS="${TAB}" read -r ok oa; do
      add_param "output 変更" "output.${ok}" "出力値が変更されます（${oa}）" "この出力を参照する他の構成（remote state 等）への影響を確認する"
    done < "${outchg}"
  fi
}

# plan テキストログから簡易抽出（jq が無い場合）
extract_changes_from_text() {
  log_warn "plan JSON を解析できないため、テキストログから簡易集計します（jq の導入を推奨）。"
  grep -E '^Plan:|^No changes' "${PLAN_LOG}" | sed 's/^/    /' || true

  # "# addr will be created" 等を抽出
  local tmp="${WORKDIR}/text_changes.tsv"
  grep -E '^[[:space:]]*# .* (will be|must be)' "${PLAN_LOG}" \
    | sed -e 's/^[[:space:]]*# //' \
          -e 's/ will be created/\tcreate/' \
          -e 's/ will be updated in-place/\tupdate/' \
          -e 's/ will be destroyed/\tdelete/' \
          -e 's/ must be replaced/\tdelete+create/' \
    | awk -F'\t' '{ t=$1; sub(/\[.*/,"",t); n=split(t,a,"."); type=(n>=2? a[n-1] : "-"); printf "%s\t%s\t%s\t-\n", $1, type, $2 }' \
    > "${CHANGES_TSV}" 2>/dev/null || true

  local addr type action _r
  while IFS="${TAB}" read -r addr type action _r; do
    [[ -z "${addr}" ]] && continue
    case "${action}" in
      create) printf '%s\t%s\t%s\t%s\n' "${addr}" "${type}" "-" "(詳細は plan ログ参照。jq 導入で属性まで抽出可能)" >> "${CREATE_TSV}"; CNT_CREATE=$((CNT_CREATE+1)) ;;
      update) printf '%s\t%s\t%s\t%s\t%s\n' "${addr}" "${type}" "(全体)" "-" "(詳細は plan ログ参照)" >> "${UPDATE_TSV}"; CNT_UPDATE=$((CNT_UPDATE+1)) ;;
      delete) printf '%s\t%s\t%s\t%s\n' "${addr}" "${type}" "削除" "-" >> "${DELETE_TSV}"; CNT_DELETE=$((CNT_DELETE+1)) ;;
      delete+create) printf '%s\t%s\t%s\t%s\n' "${addr}" "${type}" "置換（削除→再作成）" "-" >> "${DELETE_TSV}"; CNT_REPLACE=$((CNT_REPLACE+1)) ;;
    esac
  done < "${CHANGES_TSV}"
  log_info "変更集計(簡易): 作成 ${CNT_CREATE} / 修正 ${CNT_UPDATE} / 置換 ${CNT_REPLACE} / 削除 ${CNT_DELETE}"
}

# ---------------------------------------------------------------------------
# 10. apply リスク分析（plan は成功しても apply で失敗し得る箇所）
# ---------------------------------------------------------------------------
risk_for_change() {
  local addr="$1" type="$2" action="$3" reason="$4"
  local is_create="false" is_delete="false" is_update="false" is_replace="false"
  [[ "${action}" == *create* ]] && is_create="true"
  [[ "${action}" == *delete* ]] && is_delete="true"
  [[ "${action}" == *update* ]] && is_update="true"
  [[ "${action}" == *create* && "${action}" == *delete* ]] && is_replace="true"

  if [[ "${is_replace}" == "true" ]]; then
    add_risk "高" "${addr}" "${action}" "置換（削除→再作成）に伴うダウンタイム/データ消失の恐れ" "置換理由（${reason}）を確認。名前固定リソースで create_before_destroy を使うと同名衝突するため注意"
  fi

  case "${type}" in
    aws_s3_bucket)
      [[ "${is_create}" == "true" ]] && add_risk "高" "${addr}" "${action}" "バケット名はグローバル一意。既存名と重複すると BucketAlreadyExists で apply 失敗" "命名にアカウント ID や環境名を含め一意性を担保する"
      [[ "${is_delete}" == "true" ]] && add_risk "高" "${addr}" "${action}" "オブジェクトが残っていると BucketNotEmpty で削除失敗" "事前にバケットを空にする（force_destroy = true の検討）" ;;
    aws_iam_role|aws_iam_policy|aws_iam_user|aws_iam_instance_profile)
      [[ "${is_create}" == "true" ]] && add_risk "中" "${addr}" "${action}" "同名 IAM エンティティが手動作成済みだと EntityAlreadyExists で失敗。作成直後は伝播遅延で参照側が一時失敗することがある" "既存 IAM を確認し、必要なら import する。参照側エラーはリトライで解消することが多い"
      [[ "${is_delete}" == "true" ]] && add_risk "中" "${addr}" "${action}" "ポリシー/インスタンスプロファイルがアタッチされたままだと DeleteConflict で失敗" "アタッチ関係のリソースも同時に管理・削除されているか確認" ;;
    aws_iam_role_policy_attachment|aws_iam_policy_attachment)
      add_risk "低" "${addr}" "${action}" "IAM 変更の伝播遅延により、直後にそのロールを使うリソース作成が一時的に失敗することがある" "apply の再実行（リトライ）で解消するか確認" ;;
    aws_security_group)
      [[ "${is_delete}" == "true" ]] && add_risk "中" "${addr}" "${action}" "他リソース（ENI/EC2/RDS 等）から参照中だと DependencyViolation で削除失敗・タイムアウト" "参照元を先に付け替える。置換時は create_before_destroy と name_prefix の併用を検討" ;;
    aws_security_group_rule)
      [[ "${is_create}" == "true" ]] && add_risk "低" "${addr}" "${action}" "同一内容のルールが既に存在すると Duplicate エラーで失敗（手動追加や inline ルールとの競合）" "inline ルールと aws_security_group_rule の併用を避ける" ;;
    aws_instance)
      [[ "${is_create}" == "true" ]] && add_risk "中" "${addr}" "${action}" "InsufficientInstanceCapacity / vCPU クォータ超過 / AMI・キーペアが対象リージョンに無い、で失敗し得る" "Service Quotas と AMI ID のリージョン整合を事前確認"
      [[ "${is_update}" == "true" ]] && add_risk "中" "${addr}" "${action}" "instance_type 等の変更は再起動（停止→起動）を伴う場合がある" "メンテナンス時間帯での適用を検討" ;;
    aws_eip)
      [[ "${is_create}" == "true" ]] && add_risk "低" "${addr}" "${action}" "EIP のアカウント上限（既定 5/リージョン）超過で失敗し得る" "Service Quotas を確認" ;;
    aws_db_instance|aws_rds_cluster|aws_rds_cluster_instance)
      [[ "${is_delete}" == "true" ]] && add_risk "高" "${addr}" "${action}" "deletion_protection 有効だと削除失敗。skip_final_snapshot=false の場合 final_snapshot_identifier 必須" "削除保護の解除手順と最終スナップショット設定を確認"
      [[ "${is_update}" == "true" ]] && add_risk "中" "${addr}" "${action}" "apply_immediately 未指定の変更は次回メンテナンスウィンドウまで適用されない。一部変更は再起動を伴う" "適用タイミングと再起動有無をパラメータごとに確認"
      [[ "${is_create}" == "true" ]] && add_risk "中" "${addr}" "${action}" "作成に長時間かかりタイムアウトし得る。パスワード文字種制約・サブネットグループの AZ 要件違反で失敗し得る" "timeouts ブロックの設定とパラメータ制約を確認" ;;
    aws_kms_key)
      [[ "${is_delete}" == "true" ]] && add_risk "高" "${addr}" "${action}" "KMS キーは即時削除不可（7〜30 日の待機）。削除予約中の再作成で運用が複雑化" "削除の必要性を再確認" ;;
    aws_kms_alias)
      [[ "${is_create}" == "true" ]] && add_risk "低" "${addr}" "${action}" "エイリアス名はアカウント×リージョン内で一意。既存と重複すると AlreadyExists で失敗" "既存エイリアスを確認" ;;
    aws_ecr_repository)
      [[ "${is_delete}" == "true" ]] && add_risk "中" "${addr}" "${action}" "イメージが残っていると RepositoryNotEmpty で削除失敗" "force_delete = true の検討、または事前にイメージ削除" ;;
    aws_cloudwatch_log_group)
      [[ "${is_create}" == "true" ]] && add_risk "低" "${addr}" "${action}" "Lambda 等が同名 log group を自動作成済みだと ResourceAlreadyExists で失敗" "既存 log group を import するか名前を確認" ;;
    aws_lambda_function)
      [[ "${is_create}" == "true" ]] && add_risk "低" "${addr}" "${action}" "IAM ロール伝播遅延による InvalidParameterValueException（リトライで解消）、パッケージサイズ超過で失敗し得る" "初回失敗時は再 apply を試す" ;;
    aws_acm_certificate|aws_acm_certificate_validation)
      add_risk "中" "${addr}" "${action}" "DNS/メール検証が完了しないと validation がタイムアウトする（既定 45 分等）" "検証用 Route53 レコードの作成有無・DNS 委任を確認" ;;
    aws_route53_record)
      [[ "${is_create}" == "true" ]] && add_risk "低" "${addr}" "${action}" "同名レコードが既に存在すると作成に失敗する" "allow_overwrite の設定と既存レコードを確認" ;;
    aws_lb|aws_alb|aws_elb)
      [[ "${is_create}" == "true" ]] && add_risk "中" "${addr}" "${action}" "LB 名はリージョン内一意。ALB/NLB は 2 AZ 以上のサブネット必須" "命名とサブネット構成を確認" ;;
    aws_subnet|aws_vpc)
      [[ "${is_delete}" == "true" ]] && add_risk "中" "${addr}" "${action}" "ENI 等の依存リソースが残っていると DependencyViolation で削除失敗" "依存リソース（ENI/エンドポイント/NAT GW 等）の削除順序を確認"
      [[ "${is_create}" == "true" && "${type}" == "aws_subnet" ]] && add_risk "中" "${addr}" "${action}" "CIDR が既存サブネットと重複すると InvalidSubnet.Conflict で失敗" "CIDR 設計を確認" ;;
    aws_eks_cluster|aws_eks_node_group)
      add_risk "中" "${addr}" "${action}" "作成/更新/削除に長時間かかりタイムアウトし得る" "timeouts ブロックの設定を検討" ;;
    aws_autoscaling_group)
      [[ "${is_delete}" == "true" ]] && add_risk "中" "${addr}" "${action}" "インスタンスの終了待ちで削除に時間がかかる/タイムアウトし得る" "force_delete や timeouts の設定を確認" ;;
  esac
}

analyze_apply_risks() {
  section "[5/6] apply リスク分析（plan 成功でも apply で問題になり得る箇所）"

  # plan の変更一覧に基づくリソース種別×アクション別のリスク
  if [[ -s "${CHANGES_TSV}" ]]; then
    local addr type action reason
    while IFS="${TAB}" read -r addr type action reason; do
      [[ -z "${addr}" ]] && continue
      risk_for_change "${addr}" "${type}" "${action}" "${reason}"
    done < "${CHANGES_TSV}"
  fi

  # 静的チェック（変更有無に依存しない全般リスク）
  local prov pd
  prov="$(grep -rnE '^[[:space:]]*provisioner[[:space:]]+"' "${ROOT_DIR}" --include='*.tf' 2>/dev/null | head -n 20 || true)"
  if [[ -n "${prov}" ]]; then
    local line
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      add_risk "中" "${line%%:*}:$(echo "${line}" | cut -d: -f2)" "(静的検出)" "provisioner は plan で検証されず apply 時に初めて実行・失敗する" "接続情報(SSH/WinRM)・スクリプトの冪等性を事前確認。可能なら user_data や SSM への置換を検討"
    done <<< "${prov}"
  fi
  pd="$(grep -rnE 'prevent_destroy[[:space:]]*=[[:space:]]*true' "${ROOT_DIR}" --include='*.tf' 2>/dev/null | head -n 20 || true)"
  if [[ -n "${pd}" ]]; then
    local line
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      add_risk "中" "${line%%:*}:$(echo "${line}" | cut -d: -f2)" "(静的検出)" "prevent_destroy = true のため、置換/削除を伴う変更は apply がエラーで停止する" "置換が必要な変更を入れる前に lifecycle 設定の扱いを合意しておく"
    done <<< "${pd}"
  fi

  if [[ -s "${CHANGES_TSV}" ]] && awk -F'\t' '$3 ~ /delete/ {found=1} END{exit !found}' "${CHANGES_TSV}"; then
    add_risk "高" "(全般)" "delete を含む" "削除順序の依存関係により DependencyViolation 等で途中失敗し、環境が中途半端な状態になり得る" "重要環境では削除を伴う apply の前に state バックアップ（terraform state pull）を取得する"
  fi
  if [[ "${PLAN_RC}" == "2" ]]; then
    add_risk "低" "(全般)" "apply 時" "plan 成功後〜apply までに他者が変更すると差分が変わる。CI 等の同時実行では state ロック競合も発生" "保存済み plan を使った apply、または短時間での plan→apply を徹底"
  fi

  if [[ -s "${RISKS_TSV}" ]]; then
    local risk_count
    risk_count="$(wc -l < "${RISKS_TSV}")"
    log_warn "apply 時に注意すべきポイントを ${risk_count} 件検出しました。"
    add_summary "apply リスク分析" "${risk_count} 件の注意点" "詳細は「apply リスク」シートを参照"
  else
    log_success "既知パターンに該当する apply 時リスクは検出されませんでした。"
    add_summary "apply リスク分析" "指摘なし" "既知パターンに該当なし"
  fi
}

# ---------------------------------------------------------------------------
# 11. パラメータ検討サポート（追加/修正を検討すべき項目）
# ---------------------------------------------------------------------------
analyze_params() {
  section "[6/6] パラメータ検討サポート（追加・修正を検討すべき項目）"

  # (1) apply 後まで確定しない属性が多いリソース（plan JSON）
  if [[ "${HAVE_JQ}" == "true" && -s "${PLAN_JSON:-/nonexistent}" ]]; then
    local ka="${WORKDIR}/known_after.tsv"
    jq -r '.resource_changes[]?
      | select(.change.after_unknown != null and ((.change.actions|join(",")) != "no-op"))
      | [.address, ((.change.after_unknown | [.. | select(. == true)] | length) | tostring)]
      | @tsv' "${PLAN_JSON}" 2>/dev/null | sort -t"${TAB}" -k2,2nr | head -n 10 > "${ka}" || true
    local addr n
    while IFS="${TAB}" read -r addr n; do
      [[ -z "${addr}" || "${n}" == "0" ]] && continue
      add_param "apply後に確定する値" "${addr}" "apply 後まで確定しない属性が ${n} 件あります" "他リソースがこの値を参照する場合、apply が段階的に失敗しないか（count/for_each に使っていないか）確認する"
    done < "${ka}"
  fi

  # (2) タグ未設定リソース（plan JSON）
  if [[ "${HAVE_JQ}" == "true" && -s "${PLAN_JSON:-/nonexistent}" ]]; then
    local untagged="${WORKDIR}/untagged.tsv"
    jq -r '.resource_changes[]?
      | select(.change.after != null and (.change.after | type == "object") and (.change.after | has("tags_all")))
      | select((.change.actions | join(",")) != "delete")
      | select(((.change.after.tags_all // {}) | length) == 0)
      | [.address, .type] | @tsv' "${PLAN_JSON}" 2>/dev/null > "${untagged}" || true
    local addr type
    while IFS="${TAB}" read -r addr type; do
      [[ -z "${addr}" ]] && continue
      add_param "タグ未設定" "${addr}" "タグが 1 つも設定されません（コスト配賦・棚卸しに影響）" "provider の default_tags または resource の tags で Environment/Project/ManagedBy 等を付与する"
    done < "${untagged}"
  fi

  # (3) モジュール入力の過不足（静的解析）
  analyze_module_inputs

  # 結果集計
  if [[ -s "${PARAMS_TSV}" ]]; then
    local n
    n="$(wc -l < "${PARAMS_TSV}")"
    log_warn "追加・修正を検討すべきパラメータ等を ${n} 件検出しました。"
    add_summary "パラメータ検討" "${n} 件の検討事項" "詳細は「パラメータ検討」シートを参照"
  else
    log_success "追加・修正を検討すべきパラメータの指摘はありません。"
    add_summary "パラメータ検討" "指摘なし" "-"
  fi
}

# モジュール呼び出し側 vs モジュール側 variables の過不足（PARAMS_TSV へ追記）
analyze_module_inputs() {
  local raw="${WORKDIR}/modules_raw.tsv"
  find "${ROOT_DIR}" -maxdepth 1 -name '*.tf' -type f -print0 2>/dev/null \
    | xargs -0 awk -f "${WORKDIR}/parse_modules.awk" > "${raw}" 2>/dev/null || true
  [[ -s "${raw}" ]] || return 0

  local -a mod_names=()
  local kind name file src dir
  while IFS="${TAB}" read -r kind name file; do
    [[ "${kind}" == "MODULE" ]] || continue
    mod_names+=("${name}")
  done < "${raw}"
  [[ "${#mod_names[@]}" -gt 0 ]] || return 0

  local mod
  for mod in "${mod_names[@]}"; do
    [[ -z "${mod}" ]] && continue
    src="$(awk -F'\t' -v m="${mod}" '$1=="ARG" && $2==m && $3=="source" {print $4; exit}' "${raw}" | tr -d '"' | sed 's/,$//')"
    case "${src}" in
      ./*|../*)
        dir="$(cd "${ROOT_DIR}" && cd "${src}" 2>/dev/null && pwd || true)" ;;
      *)
        # リモート/レジストリ source は静的解析対象外
        continue ;;
    esac
    [[ -n "${dir}" ]] || { log_warn "モジュール '${mod}' の source が解決できません: ${src}"; continue; }

    local vars_tsv="${WORKDIR}/vars_${mod}.tsv" args_tsv="${WORKDIR}/args_${mod}.tsv"
    find "${dir}" -maxdepth 1 -name '*.tf' -type f -print0 2>/dev/null \
      | xargs -0 awk -f "${WORKDIR}/parse_variables.awk" > "${vars_tsv}" 2>/dev/null || true
    awk -F'\t' -v m="${mod}" \
      '$1=="ARG" && $2==m && $3!="source" && $3!="version" && $3!="count" && $3!="for_each" && $3!="depends_on" && $3!="providers" {print $3 "\t" $4}' \
      "${raw}" > "${args_tsv}" || true

    local vk vname vreq vtype vdef
    while IFS="${TAB}" read -r vk vname vreq vtype vdef; do
      [[ "${vk}" == "VAR" ]] || continue
      if awk -F'\t' -v k="${vname}" '$1==k {found=1} END{exit !found}' "${args_tsv}"; then
        continue  # 渡している
      fi
      if [[ "${vreq}" == "required" ]]; then
        add_param "必須入力の不足" "module.${mod}（${src}）" "必須変数 '${vname}' が渡されていません" "module 呼び出しに ${vname} を追加する（未対応だと Missing required argument で失敗）"
      else
        add_param "default 依存" "module.${mod}（${src}）" "任意変数 '${vname}' が未指定で default（${vdef}）が使われます" "環境ごとに変えるべき値なら tfvars 等で明示指定を検討"
      fi
    done < "${vars_tsv}"

    local aname aval
    while IFS="${TAB}" read -r aname aval; do
      [[ -z "${aname}" ]] && continue
      if ! awk -F'\t' -v k="${aname}" '$2==k {found=1} END{exit !found}' "${vars_tsv}"; then
        add_param "未宣言の引数" "module.${mod}（${src}）" "引数 '${aname}' に対応する variable がモジュール側にありません" "変数名の誤記か variable 宣言漏れを確認（Unsupported argument で失敗）"
      fi
    done < "${args_tsv}"
  done
}

# ---------------------------------------------------------------------------
# 12. タグ予想（plan JSON の tags_all に基づく）
# ---------------------------------------------------------------------------
analyze_tags() {
  [[ "${HAVE_JQ}" == "true" && -s "${PLAN_JSON:-/nonexistent}" ]] || return 0
  jq -r '.resource_changes[]?
    | select(.change.after != null and (.change.after | type == "object") and (.change.after | has("tags_all")))
    | select((.change.actions | join(",")) != "delete")
    | . as $rc
    | ($rc.change.after.tags // {}) as $t
    | (($rc.change.after.tags_all // {}) | to_entries[])
    | [$rc.address, $rc.type, .key,
       (if .value == null then "(apply後に確定)" else (.value | tostring) end),
       (if ($t | has(.key)) then "リソース/モジュール指定" else "provider default_tags" end)]
    | @tsv' "${PLAN_JSON}" > "${TAGS_TSV}" 2>/dev/null || true
  if [[ -s "${TAGS_TSV}" ]]; then
    sort -t"${TAB}" -k1,1 -k3,3 -o "${TAGS_TSV}" "${TAGS_TSV}"
    local n
    n="$(cut -f1 "${TAGS_TSV}" | sort -u | wc -l)"
    add_summary "タグ予想" "${n} リソースのタグを予想" "plan JSON の tags_all に基づく（由来付き）"
  fi
}

# ===========================================================================
# 13. レポート出力（共通: 色分けキーワード）
# ===========================================================================
# awk で使う色分け関数（xlsx / html 共通のロジック）
AWK_HUE='
function hue(v){
  if (v ~ /置換|replace|再作成/) return "orange";
  if (v ~ /create|新規|成功|正常|OK/) return "green";
  if (v ~ /削除|delete|destroy|失敗|NG|不足|過剰|エラー|error|Error|致命|高/) return "red";
  if (v ~ /警告|warn|注意|検討|default|確定|情報|低|スキップ|中/) return "yellow";
  return "plain";
}'

# ---------------------------------------------------------------------------
# 13a. Excel(.xlsx) 生成（OOXML を自前生成し zip 化）
# ---------------------------------------------------------------------------
# 出力するシートの登録（並列配列）
SHEET_TITLE=(); SHEET_HEADER=(); SHEET_DATA=(); SHEET_COLORCOL=()
register_sheet() { # title, header(TAB区切り), datafile, colorcol
  SHEET_TITLE+=("$1"); SHEET_HEADER+=("$2"); SHEET_DATA+=("$3"); SHEET_COLORCOL+=("$4")
}

# ディレクトリを zip 化（zip 優先、無ければ python3）
zip_dir() { # srcdir, outfile(絶対パス)
  local src="$1" out="$2"
  rm -f "${out}"
  if command -v zip >/dev/null 2>&1; then
    ( cd "${src}" && zip -X -q -r "${out}" . )
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "${src}" "${out}" <<'PY'
import sys, os, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
  else
    return 1
  fi
}

# 1 つのワークシート XML を生成
write_worksheet() { # combined_tsv(1行目=ヘッダ), colorcol, outfile
  local ctsv="$1" colorcol="$2" out="$3"
  local ncols nrows lastcol cols_xml
  ncols="$(awk -F'\t' 'NR==1{print NF; exit}' "${ctsv}")"
  [[ -z "${ncols}" || "${ncols}" -lt 1 ]] && ncols=1
  nrows="$(awk 'END{print NR}' "${ctsv}")"
  [[ -z "${nrows}" || "${nrows}" -lt 1 ]] && nrows=1
  lastcol="$(awk -v n="${ncols}" 'BEGIN{s="";while(n>0){r=(n-1)%26;s=sprintf("%c",65+r) s;n=int((n-1)/26)}print s}')"

  cols_xml="$(awk -F'\t' '
    { for(i=1;i<=NF;i++){ l=length($i); if(l>mx[i]) mx[i]=l } if(NF>maxnf) maxnf=NF }
    END{
      printf "<cols>";
      for(i=1;i<=maxnf;i++){ w=mx[i]*1.15+3; if(w<10)w=10; if(w>70)w=70;
        printf "<col min=\"%d\" max=\"%d\" width=\"%.1f\" customWidth=\"1\"/>", i, i, w }
      printf "</cols>";
    }' "${ctsv}")"

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    printf '<dimension ref="A1:%s%s"/>' "${lastcol}" "${nrows}"
    printf '%s' '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>'
    printf '%s' '<sheetFormatPr defaultRowHeight="15"/>'
    printf '%s' "${cols_xml}"
    awk -F'\t' -v colorcol="${colorcol}" "
    ${AWK_HUE}
    function esc(s){ gsub(/&/,\"\\\\&amp;\",s); gsub(/</,\"\\\\&lt;\",s); gsub(/>/,\"\\\\&gt;\",s); gsub(/\r/,\"\",s); return s }
    function colletter(n,  s,r){ s=\"\"; while(n>0){ r=(n-1)%26; s=sprintf(\"%c\",65+r) s; n=int((n-1)/26) } return s }
    BEGIN{ printf \"<sheetData>\" }
    {
      r=NR; rs=2;
      if(r==1){ rs=1 }
      else if(colorcol+0 < 0){ rs = -(colorcol+0) }
      else {
        rs = (r%2==0)?2:7;
        if(colorcol+0 > 0 && colorcol+0 <= NF){
          h=hue(\$(colorcol+0));
          if(h==\"green\") rs=3; else if(h==\"red\") rs=4; else if(h==\"orange\") rs=5; else if(h==\"yellow\") rs=6;
        }
      }
      printf \"<row r=\\\"%d\\\">\", r;
      for(i=1;i<=NF;i++){
        printf \"<c r=\\\"%s%d\\\" t=\\\"inlineStr\\\" s=\\\"%d\\\"><is><t xml:space=\\\"preserve\\\">%s</t></is></c>\", colletter(i), r, rs, esc(\$i);
      }
      printf \"</row>\";
    }
    END{ printf \"</sheetData>\" }
    " "${ctsv}"
    printf '<autoFilter ref="A1:%s%s"/>' "${lastcol}" "${nrows}"
    printf '%s' '</worksheet>'
  } > "${out}"
}

generate_xlsx() {
  local bd="${WORKDIR}/xlsx_build"
  rm -rf "${bd}"
  mkdir -p "${bd}/_rels" "${bd}/xl/_rels" "${bd}/xl/worksheets"

  # styles.xml
  cat > "${bd}/xl/styles.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="3">
<font><sz val="11"/><name val="Meiryo"/></font>
<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Meiryo"/></font>
<font><b/><sz val="16"/><color rgb="FF1F4E78"/><name val="Meiryo"/></font>
</fonts>
<fills count="8">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFC6EFCE"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFFC7CE"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFCE4D6"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFFEB9C"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="2">
<border><left/><right/><top/><bottom/><diagonal/></border>
<border><left style="thin"><color rgb="FFD9D9D9"/></left><right style="thin"><color rgb="FFD9D9D9"/></right><top style="thin"><color rgb="FFD9D9D9"/></top><bottom style="thin"><color rgb="FFD9D9D9"/></bottom><diagonal/></border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="9">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="5" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="6" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="7" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
XML

  # _rels/.rels
  cat > "${bd}/_rels/.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
XML

  # 各ワークシート + workbook / rels / content types を組み立て
  local n="${#SHEET_TITLE[@]}"
  local i sheets_xml="" wbrels_xml="" ct_over="" name safe combined
  for (( i=0; i<n; i++ )); do
    local idx=$(( i + 1 ))
    combined="${WORKDIR}/sheet_${idx}.tsv"
    { printf '%s\n' "${SHEET_HEADER[$i]}"
      if [[ -s "${SHEET_DATA[$i]}" ]]; then
        cat "${SHEET_DATA[$i]}"
      else
        printf '（該当なし）\n'
      fi
    } > "${combined}"
    write_worksheet "${combined}" "${SHEET_COLORCOL[$i]}" "${bd}/xl/worksheets/sheet${idx}.xml"

    # シート名（31 文字以内、禁止文字除去）
    safe="$(printf '%s' "${SHEET_TITLE[$i]}" | tr -d '[]:*?/\\' | cut -c1-31)"
    sheets_xml+="<sheet name=\"${safe}\" sheetId=\"${idx}\" r:id=\"rId${idx}\"/>"
    wbrels_xml+="<Relationship Id=\"rId${idx}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet${idx}.xml\"/>"
    ct_over+="<Override PartName=\"/xl/worksheets/sheet${idx}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
  done
  local style_rid=$(( n + 1 ))

  # xl/workbook.xml
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    printf '<sheets>%s</sheets>' "${sheets_xml}"
    printf '%s' '</workbook>'
  } > "${bd}/xl/workbook.xml"

  # xl/_rels/workbook.xml.rels
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    printf '%s' "${wbrels_xml}"
    printf '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' "${style_rid}"
    printf '%s' '</Relationships>'
  } > "${bd}/xl/_rels/workbook.xml.rels"

  # [Content_Types].xml
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    printf '%s' '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    printf '%s' '<Default Extension="xml" ContentType="application/xml"/>'
    printf '%s' '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    printf '%s' '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    printf '%s' "${ct_over}"
    printf '%s' '</Types>'
  } > "${bd}/[Content_Types].xml"

  zip_dir "${bd}" "${XLSX_FILE}" || die "xlsx の zip 化に失敗しました。"
  log_success "Excel レポートを出力しました: ${XLSX_FILE}"
}

# ---------------------------------------------------------------------------
# 13b. HTML レポート生成（自己完結・スタイル埋め込み）
# ---------------------------------------------------------------------------
html_escape() { # stdin -> stdout
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# 1 テーブル分の HTML を出力
html_table() { # title, header(TAB), datafile, colorcol, section_id
  local title="$1" header="$2" data="$3" colorcol="$4" sid="$5"
  local combined="${WORKDIR}/html_${sid}.tsv" rowcount=0
  { printf '%s\n' "${header}"
    if [[ -s "${data}" ]]; then cat "${data}"; fi
  } > "${combined}"
  rowcount="$( [[ -s "${data}" ]] && wc -l < "${data}" || echo 0 )"

  printf '<section id="%s"><h2>%s <span class="count">%s 件</span></h2>' "${sid}" "${title}" "${rowcount}"
  printf '<input class="filter" type="text" placeholder="この表を絞り込み..." oninput="filterTable(this)">'
  if [[ ! -s "${data}" ]]; then
    printf '<p class="none">該当なし</p></section>'
    return 0
  fi
  printf '<div class="tablewrap"><table>'
  awk -F'\t' -v colorcol="${colorcol}" "
  ${AWK_HUE}
  function esc(s){ gsub(/&/,\"\\\\&amp;\",s); gsub(/</,\"\\\\&lt;\",s); gsub(/>/,\"\\\\&gt;\",s); gsub(/\r/,\"\",s); return s }
  NR==1{
    printf \"<thead><tr>\";
    for(i=1;i<=NF;i++) printf \"<th>%s</th>\", esc(\$i);
    printf \"</tr></thead><tbody>\";
    next;
  }
  {
    cls=\"\";
    if(colorcol+0 < 0){
      v=-(colorcol+0);
      if(v==3)cls=\"c-green\"; else if(v==4)cls=\"c-red\"; else if(v==5)cls=\"c-orange\"; else if(v==6)cls=\"c-yellow\";
    } else if(colorcol+0 > 0 && colorcol+0 <= NF){
      h=hue(\$(colorcol+0));
      if(h==\"green\")cls=\"c-green\"; else if(h==\"red\")cls=\"c-red\"; else if(h==\"orange\")cls=\"c-orange\"; else if(h==\"yellow\")cls=\"c-yellow\";
    }
    printf \"<tr class=\\\"%s\\\">\", cls;
    for(i=1;i<=NF;i++) printf \"<td>%s</td>\", esc(\$i);
    printf \"</tr>\";
  }
  END{ printf \"</tbody>\" }
  " "${combined}"
  printf '</table></div></section>'
}

generate_html() {
  local tf_ver
  tf_ver="$(terraform version 2>/dev/null | head -n 1 || true)"
  local status_txt status_cls
  if [[ "${OVERALL_RC}" -eq 0 ]]; then
    status_txt="エラーなし（init / validate / plan 正常）"; status_cls="ok"
  else
    status_txt="エラー検出あり（詳細を確認してください）"; status_cls="ng"
  fi

  {
    cat <<'HEAD'
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Terraform Plan 分析レポート</title>
<style>
  :root{ --fg:#1a2733; --muted:#5b6b7b; --line:#e2e8f0; --bg:#f5f7fa; --card:#fff; --accent:#1f4e78; }
  *{ box-sizing:border-box; }
  body{ margin:0; font-family:"Meiryo","Hiragino Kaku Gothic ProN","Yu Gothic",sans-serif; color:var(--fg); background:var(--bg); line-height:1.6; }
  header{ background:linear-gradient(135deg,#1f4e78,#2d6da3); color:#fff; padding:28px 32px; }
  header h1{ margin:0 0 6px; font-size:22px; }
  header .sub{ opacity:.9; font-size:13px; }
  main{ max-width:1200px; margin:0 auto; padding:24px 20px 60px; }
  .meta{ display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px; margin:20px 0; }
  .meta .item{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; }
  .meta .item .k{ font-size:11px; color:var(--muted); }
  .meta .item .v{ font-size:14px; font-weight:600; word-break:break-all; }
  .cards{ display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin:18px 0 26px; }
  .card{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; text-align:center; }
  .card .num{ font-size:30px; font-weight:700; }
  .card .lbl{ font-size:12px; color:var(--muted); }
  .card.create .num{ color:#1e8e4e; } .card.update .num{ color:#b7791f; }
  .card.replace .num{ color:#c05621; } .card.delete .num{ color:#c53030; }
  .status{ display:inline-block; padding:6px 14px; border-radius:20px; font-size:13px; font-weight:700; }
  .status.ok{ background:#c6efce; color:#1e6b3a; } .status.ng{ background:#ffc7ce; color:#a02020; }
  nav{ margin:10px 0 24px; display:flex; flex-wrap:wrap; gap:8px; }
  nav a{ font-size:12px; text-decoration:none; color:var(--accent); background:#fff; border:1px solid var(--line); padding:5px 10px; border-radius:16px; }
  nav a:hover{ background:var(--accent); color:#fff; }
  section{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:18px 18px 8px; margin:0 0 20px; }
  section h2{ font-size:16px; margin:0 0 12px; padding-bottom:8px; border-bottom:2px solid var(--accent); }
  section h2 .count{ font-size:12px; color:var(--muted); font-weight:400; }
  .filter{ width:100%; max-width:340px; margin:0 0 12px; padding:7px 10px; border:1px solid var(--line); border-radius:8px; font-size:13px; }
  .tablewrap{ overflow-x:auto; }
  table{ border-collapse:collapse; width:100%; font-size:13px; }
  th,td{ border:1px solid var(--line); padding:7px 9px; text-align:left; vertical-align:top; word-break:break-word; }
  th{ background:var(--accent); color:#fff; position:sticky; top:0; white-space:nowrap; }
  tbody tr:nth-child(even){ background:#f7f9fb; }
  tr.c-green{ background:#e7f6ec !important; } tr.c-red{ background:#fdecec !important; }
  tr.c-orange{ background:#fdeee0 !important; } tr.c-yellow{ background:#fdf6d8 !important; }
  .none{ color:var(--muted); font-style:italic; padding:4px 0 12px; }
  footer{ text-align:center; color:var(--muted); font-size:11px; padding:20px; }
  @media (prefers-color-scheme: dark){
    :root{ --fg:#e6edf3; --muted:#9aa7b4; --line:#2d3742; --bg:#0f141a; --card:#161c24; --accent:#2d6da3; }
    tbody tr:nth-child(even){ background:#1b222b; }
    tr.c-green{ background:#173a26 !important; } tr.c-red{ background:#3a1c1c !important; }
    tr.c-orange{ background:#3a2a17 !important; } tr.c-yellow{ background:#38341a !important; }
    nav a{ background:var(--card); } .card,.meta .item,section{ background:var(--card); }
  }
</style>
</head>
<body>
HEAD

    printf '<header><h1>Terraform Plan 分析レポート</h1><div class="sub">生成: %s ／ %s</div></header>\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "${tf_ver}" | html_escape)"
    printf '<main>'
    printf '<p><span class="status %s">%s</span></p>' "${status_cls}" "${status_txt}"

    # メタ情報カード
    printf '<div class="meta">'
    local mk mv
    while IFS="${TAB}" read -r mk mv; do
      [[ -z "${mk}" ]] && continue
      printf '<div class="item"><div class="k">%s</div><div class="v">%s</div></div>' \
        "$(printf '%s' "${mk}" | html_escape)" "$(printf '%s' "${mv}" | html_escape)"
    done < "${META_TSV}"
    printf '</div>'

    # 変更サマリカード
    printf '<div class="cards">'
    printf '<div class="card create"><div class="num">%s</div><div class="lbl">作成</div></div>' "${CNT_CREATE}"
    printf '<div class="card update"><div class="num">%s</div><div class="lbl">修正</div></div>' "${CNT_UPDATE}"
    printf '<div class="card replace"><div class="num">%s</div><div class="lbl">置換</div></div>' "${CNT_REPLACE}"
    printf '<div class="card delete"><div class="num">%s</div><div class="lbl">削除</div></div>' "${CNT_DELETE}"
    printf '</div>'

    # ナビ
    printf '<nav>'
    local ti sid
    for (( ti=0; ti<${#SHEET_TITLE[@]}; ti++ )); do
      sid="sec${ti}"
      printf '<a href="#%s">%s</a>' "${sid}" "$(printf '%s' "${SHEET_TITLE[$ti]}" | html_escape)"
    done
    printf '</nav>'

    # 各テーブル
    for (( ti=0; ti<${#SHEET_TITLE[@]}; ti++ )); do
      sid="sec${ti}"
      html_table "${SHEET_TITLE[$ti]}" "${SHEET_HEADER[$ti]}" "${SHEET_DATA[$ti]}" "${SHEET_COLORCOL[$ti]}" "${sid}"
    done

    cat <<'FOOT'
</main>
<footer>terraform-plan-analyzer.sh により生成。plan の値には機密情報が含まれる場合があります。取り扱いにご注意ください。</footer>
<script>
function filterTable(input){
  var sec = input.closest('section');
  var q = input.value.toLowerCase();
  var rows = sec.querySelectorAll('tbody tr');
  rows.forEach(function(tr){
    tr.style.display = tr.textContent.toLowerCase().indexOf(q) > -1 ? '' : 'none';
  });
}
</script>
</body>
</html>
FOOT
  } > "${HTML_FILE}"
  log_success "HTML レポートを出力しました: ${HTML_FILE}"
}

# ---------------------------------------------------------------------------
# 14. レポート生成の親関数
# ---------------------------------------------------------------------------
build_reports() {
  section "レポート出力（Excel / HTML）"

  # メタ情報
  add_meta "ルートモジュール" "${ROOT_DIR}"
  add_meta "Terraform" "$(terraform version 2>/dev/null | head -n 1 || true)"
  add_meta "実行日時" "$(date '+%Y-%m-%d %H:%M:%S')"
  add_meta "リージョン" "${REGION:-（未指定/環境変数）}"
  add_meta "plan 結果" "$(case "${PLAN_RC}" in 0) echo '変更なし';; 2) echo '変更あり';; -1) echo 'スキップ';; *) echo '失敗';; esac)"
  add_meta "作成/修正/置換/削除" "${CNT_CREATE} / ${CNT_UPDATE} / ${CNT_REPLACE} / ${CNT_DELETE}"

  # シート登録（順序＝タブ順・ナビ順）
  register_sheet "概要"           "項目${TAB}内容" "${META_TSV}" 0
  register_sheet "サマリ"         "項目${TAB}結果${TAB}詳細" "${SUMMARY_TSV}" 2
  register_sheet "作成リソース"   "アドレス${TAB}種別${TAB}名前${TAB}主な属性" "${CREATE_TSV}" -3
  register_sheet "修正リソース"   "アドレス${TAB}種別${TAB}属性${TAB}変更前${TAB}変更後" "${UPDATE_TSV}" 0
  register_sheet "削除・置換"     "アドレス${TAB}種別${TAB}区分${TAB}理由" "${DELETE_TSV}" 3
  register_sheet "applyリスク"    "重大度${TAB}対象${TAB}アクション${TAB}リスク内容${TAB}対処・確認事項" "${RISKS_TSV}" 1
  register_sheet "パラメータ検討" "分類${TAB}対象${TAB}指摘内容${TAB}推奨対応" "${PARAMS_TSV}" 1
  register_sheet "タグ予想"       "リソース${TAB}種別${TAB}タグキー${TAB}予想される値${TAB}由来" "${TAGS_TSV}" 0
  register_sheet "validate診断"   "重大度${TAB}概要${TAB}詳細${TAB}ファイル${TAB}行${TAB}原因と対処のヒント" "${VALIDATE_TSV}" 1

  generate_xlsx
  generate_html
}

# ---------------------------------------------------------------------------
# 15. 最終サマリ
# ---------------------------------------------------------------------------
final_summary() {
  section "総合サマリ"
  printf '    ルートモジュール : %s\n' "${ROOT_DIR}"
  printf '    plan 結果        : 作成 %s / 修正 %s / 置換 %s / 削除 %s\n' \
    "${CNT_CREATE}" "${CNT_UPDATE}" "${CNT_REPLACE}" "${CNT_DELETE}"
  printf '    出力ファイル     :\n'
  printf '      - Excel : %s\n' "${XLSX_FILE}"
  printf '      - HTML  : %s\n' "${HTML_FILE}"
  printf '    ログ/中間ファイル: %s\n' "${WORKDIR}"
  if [[ "${OVERALL_RC}" -eq 0 ]]; then
    log_success "分析完了: init / validate / plan にエラーはありません。"
  else
    log_error "分析完了: エラーが検出されています。レポートの内容を確認してください。"
  fi
}

# ---------------------------------------------------------------------------
# 16. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight
  setup_workdir

  log_info "=== 実行内容 ==="
  log_info "  ルートモジュール : ${ROOT_DIR}"
  log_info "  出力先           : ${OUTPUT_DIR}"
  log_info "  Excel            : ${XLSX_FILE}"
  log_info "  HTML             : ${HTML_FILE}"

  run_init
  run_fmt_check
  run_validate
  run_plan
  analyze_apply_risks
  analyze_params
  analyze_tags
  build_reports
  final_summary

  exit "${OVERALL_RC}"
}

# source されたときは main を実行しない（テスト用）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
