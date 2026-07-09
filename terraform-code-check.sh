#!/usr/bin/env bash
#
# terraform-code-check.sh
# =======================
# EC2 (RHEL 9) 上で、Terraform の「ルートモジュール」ディレクトリを指定して
# init / fmt / validate / plan を実行し、コードの状態を極めて詳細に分析・
# レポートするスクリプトです。
#
# 前提とする設計方針:
#   - コードは「再利用モジュール（modules/xxx など）」と「ルートモジュール
#     （環境ごとのディレクトリ）」に分割されている。
#   - 本スクリプトはルートモジュールのディレクトリを --root-dir で受け取り、
#     そのディレクトリを対象に terraform コマンドを実行する。
#
# 実行内容と分析:
#   [1] terraform init      : 実行と失敗時の原因分析（backend/認証/プロバイダ取得など）
#   [2] terraform fmt       : -check で整形要否を判定し、必要ならコマンドを提案
#                             （--fix-fmt 指定時はその場で整形を実行）
#   [3] terraform validate  : -json 結果を解析し、エラー/警告ごとに原因と対処のヒントを表示
#   [4] terraform plan      : -detailed-exitcode / show -json で変更内容を集計・一覧化
#   [5] apply リスク分析    : plan は成功しても apply で失敗・問題になり得る箇所を
#                             リソース種別×アクション別のヒューリスティックで指摘
#   [6] モジュール入力分析  : モジュール呼び出しの入力の過不足
#                             （必須変数の渡し漏れ / 未宣言引数 / default 依存）を判定
#   [7] モジュール設計提案  : 再利用モジュール側に定義されているが、ルートモジュール側で
#                             定義した方が良い項目（provider 定義・環境依存 default・
#                             ハードコード値・タグ直書きなど）を提案
#   [8] タグ分析            : provider default_tags / モジュールへ渡すタグ入力の設定内容と、
#                             plan JSON (tags_all) に基づく「実際に設定されるタグ」の予想一覧
#
# 出力:
#   - 画面: 全分析結果を日本語で詳細表示
#   - CSV : --csv-dir <dir> を指定すると、Excel できれいに読み込める CSV
#           （既定: UTF-8 BOM 付き・CRLF。--csv-encoding cp932 で Shift_JIS も可）を出力
#
# 認証 / 権限:
#   - 実行開始時に AWS 認証済みか（aws sts get-caller-identity）を確認します。
#     未認証の場合は「aws login --remote で認証してください」と警告して終了します。
#   - 本スクリプトは CodeCommit 操作を必要としませんが、init(S3 backend) / plan には
#     AWS への参照権限が必要です。現在の IAM 権限で AWS を操作できない場合
#     （CodeCommit 用ロールへスイッチしたまま等）:
#       * 既定                : スイッチバックするよう警告して終了します。
#       * --auto-switch-back  : --switch-back-script で指定した別チーム提供の専用シェルを
#                               source して自動的にスイッチバックし、再判定して続行します。
#
# 依存: bash, terraform, aws (CLI v2), awk, jq（plan の詳細分析・タグ予想に必要。
#       無い場合はテキストベースの簡易分析に自動縮退）, iconv（--csv-encoding cp932 時）
# 共通部品: common.sh（Codecommit_Git_Tags_S3_Upload の common.sh ベース）
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
VAR_FILES=()                # terraform plan に渡す -var-file（繰り返し指定可）
VARS=()                     # terraform plan に渡す -var（繰り返し指定可）
BACKEND_CONFIGS=()          # terraform init に渡す -backend-config（繰り返し指定可）
REGION=""                   # AWS リージョン（AWS_REGION として export）
SKIP_PLAN="false"           # true なら plan を実行しない（init は -backend=false）
UPGRADE="false"             # true なら init -upgrade
FIX_FMT="false"             # true なら fmt が必要なとき提案でなく実際に整形する
CSV_DIR=""                  # Excel 向け CSV の出力先ディレクトリ（指定時のみ出力）
CSV_ENCODING="utf8bom"      # utf8bom | cp932
NO_AWS_CHECK="false"        # true なら AWS 認証/権限チェックを行わない

# --- 認証 / 権限（スイッチバック）関連 ---
# true なら AWS 操作権限が無いとき、警告終了せず自動でスイッチバックする
AUTO_SWITCH_BACK="false"
# 別チーム提供の「スイッチバック用シェル」のパス（source で呼び出す）。環境変数でも指定可
SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-}"
# AWS 操作権限の有無を判定するコマンド（既定: aws ec2 describe-regions）。環境変数でも指定可
PROBE_COMMAND="${PROBE_COMMAND:-}"

DEBUG="${DEBUG:-false}"
export DEBUG

# --- 実行結果の状態（サマリ/終了コード用） ---
OVERALL_RC=0                # 0=正常, 2=init/validate/plan にエラーあり
INIT_RC=0
FMT_NEEDED=0                # 整形が必要なファイル数
VALIDATE_ERRORS=0
VALIDATE_WARNINGS=0
PLAN_RC=0                   # 0=変更なし, 1=エラー, 2=変更あり
HAVE_JQ="false"
WORKDIR=""                  # ログ・中間ファイル置き場（実行後も残す）

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --root-dir <dir> [オプション]

説明:
  ルートモジュールのディレクトリ <dir> で terraform init / fmt / validate / plan を
  実行し、コードの状態（エラー原因、apply 時のリスク、モジュール入力の過不足、
  モジュール設計の改善提案、タグの設定内容と実際に付与されるタグの予想）を
  詳細に分析して表示します。--csv-dir を指定すると Excel で読み込める CSV も出力します。

必須:
  --root-dir   <dir>      ルートモジュールのディレクトリ

Terraform 実行オプション:
  --var-file   <file>     plan に渡す -var-file（複数指定可）
  --var        <k=v>      plan に渡す -var（複数指定可）
  --backend-config <v>    init に渡す -backend-config（複数指定可。file または key=value）
  --upgrade               init に -upgrade を付ける
  --skip-plan             plan を実行しない（init は -backend=false。AWS 認証/権限
                          チェックも省略されるため、AWS 未接続環境でも静的チェック可能）
  --region     <region>   AWS リージョン（AWS_REGION として設定）

出力オプション:
  --csv-dir    <dir>      Excel 向け CSV の出力先ディレクトリ（未指定なら CSV は出力しない）
  --csv-encoding <enc>    CSV の文字コード: utf8bom（既定。Excel でそのまま開ける）| cp932
  --fix-fmt               fmt が必要な場合、提案だけでなく terraform fmt を実際に実行する

認証 / 権限オプション:
  --auto-switch-back      AWS 操作権限が無い場合、警告終了せず自動でスイッチバックする
                          （既定: スイッチバック方法を警告して終了）
  --switch-back-script <path>
                          自動スイッチバック時に source する専用シェルのパス
                          （別チーム提供。環境変数 SWITCH_BACK_SCRIPT でも指定可）
  --probe-command <cmd>   AWS 操作権限の有無を判定するコマンド（成功=権限あり）。
                          既定: aws ec2 describe-regions（リージョンは --region /
                          AWS_REGION / AWS_DEFAULT_REGION の順に解決し、無ければ
                          us-east-1 を補って判定する）。
                          例  : --probe-command "aws s3api head-bucket --bucket my-tfstate"
  --no-aws-check          AWS 認証/権限チェックを行わない（backend がローカルの場合など）

その他:
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

例:
  # 基本（画面表示のみ）
  ./${SCRIPT_NAME} --root-dir /opt/terraform/envs/prod

  # var-file を渡して plan し、Excel 向け CSV も出力
  ./${SCRIPT_NAME} --root-dir /opt/terraform/envs/prod \\
    --var-file /opt/terraform/envs/prod/prod.tfvars \\
    --csv-dir /tmp/tfcheck-report

  # AWS 権限が無ければ、別チーム提供のシェルで自動スイッチバックして続行
  ./${SCRIPT_NAME} --root-dir /opt/terraform/envs/prod \\
    --auto-switch-back --switch-back-script /opt/tools/switch-back.sh

  # AWS 未接続で静的チェックのみ（init -backend=false / fmt / validate / モジュール分析）
  ./${SCRIPT_NAME} --root-dir /opt/terraform/envs/dev --skip-plan

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
      --var-file)       VAR_FILES+=("${2:-}"); shift 2 ;;
      --var)            VARS+=("${2:-}"); shift 2 ;;
      --backend-config) BACKEND_CONFIGS+=("${2:-}"); shift 2 ;;
      --region)         REGION="${2:-}"; shift 2 ;;
      --upgrade)        UPGRADE="true"; shift 1 ;;
      --skip-plan)      SKIP_PLAN="true"; shift 1 ;;
      --csv-dir)        CSV_DIR="${2:-}"; shift 2 ;;
      --csv-encoding)   CSV_ENCODING="${2:-}"; shift 2 ;;
      --fix-fmt)        FIX_FMT="true"; shift 1 ;;
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
  [[ -n "${ROOT_DIR}" ]] || { usage; die "--root-dir は必須です。"; }
  [[ -d "${ROOT_DIR}" ]] || die "ルートモジュールのディレクトリが存在しません: ${ROOT_DIR}"
  ROOT_DIR="$(cd "${ROOT_DIR}" && pwd)"

  # .tf ファイルが 1 つ以上あること
  local tf_count
  tf_count="$(find "${ROOT_DIR}" -maxdepth 1 -name '*.tf' -type f 2>/dev/null | wc -l)"
  [[ "${tf_count}" -gt 0 ]] || die "ルートモジュールに .tf ファイルが見つかりません: ${ROOT_DIR}"

  case "${CSV_ENCODING}" in
    utf8bom|cp932) : ;;
    *) die "--csv-encoding は utf8bom または cp932 を指定してください: ${CSV_ENCODING}" ;;
  esac

  local vf
  for vf in "${VAR_FILES[@]:-}"; do
    [[ -z "${vf}" ]] && continue
    [[ -f "${vf}" ]] || die "--var-file が見つかりません: ${vf}"
  done

  if [[ -n "${CSV_DIR}" ]]; then
    mkdir -p "${CSV_DIR}" || die "CSV 出力先を作成できません: ${CSV_DIR}"
    CSV_DIR="$(cd "${CSV_DIR}" && pwd)"
    if [[ "${CSV_ENCODING}" == "cp932" ]]; then
      require_command iconv
    fi
  fi
}

# ---------------------------------------------------------------------------
# 4b. AWS 操作権限の判定（ensure_permission_or_switch から呼ばれる）
#     既定は ec2:DescribeRegions（ほぼ全リソース操作系ロールで許可される読み取り API）。
#     CodeCommit 専用ロールへスイッチしたままの場合はここで失敗する想定。
#     backend や plan 対象に合わせて --probe-command で差し替え可能。
# ---------------------------------------------------------------------------
probe_aws_permission() {
  if [[ -n "${PROBE_COMMAND}" ]]; then
    log_debug "権限判定コマンド: ${PROBE_COMMAND}"
    bash -c "${PROBE_COMMAND}" >/dev/null 2>&1
  else
    # EC2 はリージョナル API のため、リージョン未解決だと「権限」とは無関係に
    # 失敗する（"You must specify a region" 等）。--region 未指定でも判定が
    # フォールスネガティブにならないよう、判定用のリージョンを補って実行する。
    local probe_region="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"
    aws ec2 describe-regions --region "${probe_region}" --output text >/dev/null 2>&1
  fi
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

  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  # --skip-plan（init -backend=false）または --no-aws-check なら AWS 接続は不要
  if [[ "${SKIP_PLAN}" == "true" || "${NO_AWS_CHECK}" == "true" ]]; then
    log_info "AWS 認証/権限チェックをスキップします（--skip-plan / --no-aws-check）。"
    return 0
  fi

  require_command aws

  # 認証チェック（未認証なら aws login --remote を促して終了）
  require_aws_authenticated

  # AWS 操作権限の確認（無ければスイッチバック: 自動 or 警告終了）
  # 本スクリプトは CodeCommit 操作を必要としないため、CodeCommit 用ロールに
  # スイッチしたままの場合はスイッチバックが必要になる。
  ensure_permission_or_switch \
    "AWS (Terraform init/plan)" probe_aws_permission \
    "${AUTO_SWITCH_BACK}" "${SWITCH_BACK_SCRIPT}" "スイッチバック"

  log_debug "AWS 操作権限の確認 OK。"
}

# ---------------------------------------------------------------------------
# 5b. 作業ディレクトリ（ログ・中間 TSV 置き場。分析根拠として実行後も残す）
# ---------------------------------------------------------------------------
setup_workdir() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tfcheck-${ts}.XXXX")" \
    || die "作業ディレクトリの作成に失敗しました。"
  log_info "作業ディレクトリ（ログ/中間ファイル）: ${WORKDIR}"
  log_warn "plan ファイルには機密値が含まれる場合があります。不要になったら削除してください。"

  # 中間 TSV（画面表示と CSV 出力の両方の元データ）
  SUMMARY_TSV="${WORKDIR}/01_summary.tsv"
  VALIDATE_TSV="${WORKDIR}/02_validate.tsv"
  FMT_TSV="${WORKDIR}/03_fmt.tsv"
  CHANGES_TSV="${WORKDIR}/04_plan_changes.tsv"
  RISKS_TSV="${WORKDIR}/05_apply_risks.tsv"
  MODINPUT_TSV="${WORKDIR}/06_module_inputs.tsv"
  MODSUGGEST_TSV="${WORKDIR}/07_module_suggestions.tsv"
  TAGS_TSV="${WORKDIR}/08_tags_predicted.tsv"
  DEFTAGS_TSV="${WORKDIR}/09_default_tags.tsv"
  : > "${SUMMARY_TSV}"; : > "${VALIDATE_TSV}"; : > "${FMT_TSV}"
  : > "${CHANGES_TSV}"; : > "${RISKS_TSV}"; : > "${MODINPUT_TSV}"
  : > "${MODSUGGEST_TSV}"; : > "${TAGS_TSV}"; : > "${DEFTAGS_TSV}"

  setup_awk_scripts
}

# ---------------------------------------------------------------------------
# 5c. HCL 簡易パーサ（awk）
#     ※ 1 行 1 属性の一般的な整形済みコードを想定した簡易パーサ。
#       複雑な HCL は取り切れない場合があるが、確定情報は plan JSON 側で補完する。
# ---------------------------------------------------------------------------
setup_awk_scripts() {
  # モジュールブロック抽出: MODULE<TAB>名前<TAB>ファイル / ARG<TAB>モジュール名<TAB>キー<TAB>値(先頭行)
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

  # variable ブロック抽出: VAR<TAB>名前<TAB>required|optional<TAB>type<TAB>default(先頭行)<TAB>description
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
      inv=1; depth=0; hasdef=0; vtype="-"; vdesc="-"; vdef="-"
      depth += gsub(/\{/,"{",line) - gsub(/\}/,"}",line)
      if (depth<=0) {
        printf "VAR\t%s\trequired\t-\t-\t-\n", vname
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
    } else if (line ~ /^[[:space:]]*description[[:space:]]*=/) {
      vdesc=line
      sub(/^[[:space:]]*description[[:space:]]*=[[:space:]]*/,"",vdesc)
      gsub(/^"|"[[:space:]]*$/,"",vdesc)
    }
  }
  depth += gsub(/\{/,"{",line) - gsub(/\}/,"}",line)
  if (depth<=0) {
    printf "VAR\t%s\t%s\t%s\t%s\t%s\n", vname, (hasdef ? "optional" : "required"), vtype, vdef, vdesc
    inv=0
  }
}
AWK

  # provider "aws" の default_tags 抽出:
  #   DTKEY<TAB>alias<TAB>キー<TAB>値<TAB>ファイル / DTREF<TAB>alias<TAB>式<TAB>ファイル
  cat > "${WORKDIR}/parse_default_tags.awk" <<'AWK'
FNR==1 { inprov=0; pdepth=0; indt=0; intags=0; alias="(default)" }
{
  line=$0
  sub(/\r$/,"",line)
  if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*\/\//) next
  if (inprov==0) {
    if (line ~ /^[[:space:]]*provider[[:space:]]+"aws"/) {
      inprov=1; pdepth=0; indt=0; intags=0; alias="(default)"
      pdepth += gsub(/\{/,"{",line) - gsub(/\}/,"}",line)
    }
    next
  }
  if (pdepth==1 && line ~ /^[[:space:]]*alias[[:space:]]*=/) {
    a=line
    sub(/^[^=]*=[[:space:]]*/,"",a)
    gsub(/["[:space:]]/,"",a)
    alias=a
  }
  if (indt==0 && line ~ /^[[:space:]]*default_tags[[:space:]]*\{/) {
    indt=1
  } else if (indt==1 && intags==0 && line ~ /^[[:space:]]*tags[[:space:]]*=/) {
    if (line ~ /=[[:space:]]*\{[[:space:]]*$/) {
      intags=1
    } else if (line ~ /=[[:space:]]*\{.*\}/) {
      s=line
      sub(/^[^{]*\{/,"",s)
      sub(/\}[^}]*$/,"",s)
      n=split(s, parts, ",")
      for (i=1; i<=n; i++) {
        p=parts[i]
        if (p ~ /=/) {
          k=p; sub(/^[[:space:]]*/,"",k); sub(/[[:space:]]*=.*$/,"",k); gsub(/"/,"",k)
          v=p; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/^[[:space:]]*"|"[[:space:]]*$/,"",v)
          printf "DTKEY\t%s\t%s\t%s\t%s\n", alias, k, v, FILENAME
        }
      }
    } else {
      v=line
      sub(/^[^=]*=[[:space:]]*/,"",v)
      printf "DTREF\t%s\t%s\t%s\n", alias, v, FILENAME
    }
  } else if (intags==1) {
    if (line ~ /^[[:space:]]*\}/) {
      intags=0
    } else if (line ~ /^[[:space:]]*"?[^=[:space:]]+"?[[:space:]]*=/) {
      k=line; sub(/^[[:space:]]*/,"",k); sub(/[[:space:]]*=.*$/,"",k); gsub(/"/,"",k)
      v=line; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/,[[:space:]]*$/,"",v); gsub(/^"|"$/,"",v)
      printf "DTKEY\t%s\t%s\t%s\t%s\n", alias, k, v, FILENAME
    }
  }
  pdepth += gsub(/\{/,"{",line) - gsub(/\}/,"}",line)
  if (pdepth<=0) { inprov=0; indt=0; intags=0 }
}
AWK
}

# ---------------------------------------------------------------------------
# 5d. 表示・記録ヘルパー
# ---------------------------------------------------------------------------
section() {
  printf '\n'
  printf '%s\n' "=============================================================================="
  printf ' %s\n' "$*"
  printf '%s\n' "=============================================================================="
}

# TSV を画面表示用に整形して出力する
display_table() {
  local file="$1"
  [[ -s "${file}" ]] || { printf '    （該当なし）\n'; return 0; }
  sed "s/${TAB}/  |  /g" "${file}" | sed 's/^/    /'
}

add_summary() { # 項目, 結果, 詳細
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${SUMMARY_TSV}"
}

add_risk() { # 対象, アクション, リスク内容, 対処・確認事項
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${RISKS_TSV}"
}

# ---------------------------------------------------------------------------
# 5e. terraform エラーログの原因分析（init / plan 共通）
# ---------------------------------------------------------------------------
analyze_tf_error_log() {
  local log="$1"
  local ctx="$2"
  local found=0

  _hint() {
    found=1
    log_error "  [原因分析] $1"
    log_error "    → 対処: $2"
    add_summary "${ctx} エラー分析" "$1" "$2"
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
  if grep -qiE "Invalid provider version constraint|no available releases match" "${log}"; then
    _hint "プロバイダのバージョン制約を満たす版が見つからない" "required_providers の version 制約を見直す（ロックファイル .terraform.lock.hcl の再生成も検討）"
  fi
  if grep -qiE "Invalid legacy provider address|Failed to install provider" "${log}"; then
    _hint "プロバイダのインストール失敗" "terraform init -upgrade、キャッシュ(.terraform)削除後の再 init を試す"
  fi
  if grep -qiE "No value for required variable" "${log}"; then
    _hint "必須変数が未指定" "-var / -var-file（--var / --var-file オプション）で値を渡すか、default を定義する"
  fi
  if grep -qiE "Cycle:" "${log}"; then
    _hint "リソース間の循環参照" "depends_on や参照関係を見直して循環を解消する"
  fi
  if grep -qE "Unsupported argument" "${log}"; then
    _hint "モジュール/ブロックに宣言されていない引数を渡している" "引数名の誤記、またはモジュール側の variable 宣言漏れを確認する（[6/8] モジュール入力の過不足分析も参照）"
  fi
  if grep -qE "Missing required argument" "${log}"; then
    _hint "必須の引数（モジュールの必須変数など）が渡されていない" "モジュール呼び出しに不足している引数を追加する（[6/8] モジュール入力の過不足分析も参照）"
  fi
  if grep -qiE "Module not installed|module must be installed|Unreadable module directory" "${log}"; then
    _hint "モジュールが未取得/取得不能（source パス誤り等）" "module の source パスを確認し、terraform init（または -upgrade）でモジュールを再取得する"
  fi

  if [[ "${found}" -eq 0 ]]; then
    log_error "  [原因分析] 既知パターンに一致しませんでした。ログ全文を確認してください: ${log}"
    add_summary "${ctx} エラー分析" "既知パターン外" "ログ全文を確認: ${log}"
  fi
}

# ---------------------------------------------------------------------------
# 6. [1/8] terraform init
# ---------------------------------------------------------------------------
run_init() {
  section "[1/8] terraform init"

  local init_args=(init -input=false -no-color)
  [[ "${SKIP_PLAN}" == "true" ]] && init_args+=(-backend=false)
  [[ "${UPGRADE}" == "true" ]]   && init_args+=(-upgrade)
  local bc
  for bc in "${BACKEND_CONFIGS[@]:-}"; do
    [[ -n "${bc}" ]] && init_args+=(-backend-config="${bc}")
  done

  local log="${WORKDIR}/init.log"
  log_info "実行: terraform -chdir=${ROOT_DIR} ${init_args[*]}"
  INIT_RC=0
  terraform -chdir="${ROOT_DIR}" "${init_args[@]}" > "${log}" 2>&1 || INIT_RC=$?

  if [[ "${INIT_RC}" -eq 0 ]]; then
    log_success "init 成功。プロバイダ・モジュールの取得と backend 初期化が完了しました。"
    add_summary "terraform init" "成功" "$( [[ "${SKIP_PLAN}" == "true" ]] && echo '-backend=false（--skip-plan）' || echo 'backend 初期化を含む' )"
  else
    OVERALL_RC=2
    log_error "init 失敗（終了コード: ${INIT_RC}）。エラー抜粋:"
    grep -E "Error|error" "${log}" | head -n 10 | sed 's/^/    /' >&2 || true
    add_summary "terraform init" "失敗" "ログ: ${log}"
    analyze_tf_error_log "${log}" "init"
    log_error "init に失敗したため、validate / plan は実行できません。fmt チェックと静的分析のみ継続します。"
  fi
}

# ---------------------------------------------------------------------------
# 7. [2/8] terraform fmt（チェックと提案 / --fix-fmt で実行）
# ---------------------------------------------------------------------------
run_fmt_check() {
  section "[2/8] terraform fmt（コード整形チェック）"

  # ルート配下を再帰チェック + ルート外のローカルモジュールも個別にチェック
  local -a target_dirs=("${ROOT_DIR}")
  local d
  for d in "${LOCAL_MODULE_DIRS[@]:-}"; do
    [[ -z "${d}" ]] && continue
    case "${d}/" in
      "${ROOT_DIR}"/*) : ;;               # ルート配下は -recursive で網羅済み
      *) target_dirs+=("${d}") ;;
    esac
  done

  FMT_NEEDED=0
  for d in "${target_dirs[@]}"; do
    local out="${WORKDIR}/fmt_$(basename "${d}").log"
    local rc=0
    terraform -chdir="${d}" fmt -check -recursive -no-color > "${out}" 2>&1 || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      log_success "整形済み: ${d}"
    elif [[ "${rc}" -eq 3 ]]; then
      local f
      while IFS= read -r f; do
        [[ -z "${f}" ]] && continue
        printf '%s\t%s\n' "${d}" "${f}" >> "${FMT_TSV}"
        FMT_NEEDED=$((FMT_NEEDED + 1))
      done < "${out}"
    else
      log_warn "fmt チェック自体が失敗しました（${d}）。構文エラーの可能性。ログ: ${out}"
      add_summary "terraform fmt" "チェック失敗" "${d}（構文エラーの可能性。validate 結果を参照）"
    fi
  done

  if [[ "${FMT_NEEDED}" -eq 0 ]]; then
    log_success "全ファイル整形済みです。fmt の実行は不要です。"
    add_summary "terraform fmt" "整形不要" "全ファイル整形済み"
    return 0
  fi

  log_warn "整形が必要なファイルが ${FMT_NEEDED} 件あります:"
  printf '    ディレクトリ%s対象ファイル\n' "  |  "
  display_table "${FMT_TSV}"
  add_summary "terraform fmt" "整形必要 (${FMT_NEEDED} 件)" "詳細は fmt の CSV/一覧を参照"

  if [[ "${FIX_FMT}" == "true" ]]; then
    log_info "--fix-fmt が指定されたため、整形を実行します。"
    for d in "${target_dirs[@]}"; do
      run terraform -chdir="${d}" fmt -recursive
    done
    log_success "terraform fmt を実行しました。差分を git diff 等で確認してください。"
    add_summary "terraform fmt" "整形実行済み" "--fix-fmt により自動整形"
  else
    log_info "【提案】次のコマンドで整形できます（コードの意味は変わらず、空白/インデントのみ修正されます）:"
    for d in "${target_dirs[@]}"; do
      printf '      terraform -chdir=%q fmt -recursive\n' "${d}"
    done
    log_info "  または本スクリプトに --fix-fmt を付けて再実行してください。"
  fi
}

# ---------------------------------------------------------------------------
# 8. [3/8] terraform validate（実行と結果分析）
# ---------------------------------------------------------------------------
validate_hint() {
  local s="$1"
  case "${s}" in
    *"Unsupported argument"*)
      echo "引数名の誤記、またはモジュール側 variables.tf に無い引数を渡している。宣言と綴りを確認（本レポートのモジュール入力分析も参照）" ;;
    *"Missing required argument"*)
      echo "必須引数の未指定。リソース/モジュールの必須項目を追加する" ;;
    *"Reference to undeclared input variable"*)
      echo "宣言されていない変数を参照。variables.tf に variable を追加するか参照名を修正する" ;;
    *"Reference to undeclared resource"*|*"Reference to undeclared module"*)
      echo "存在しないリソース/モジュールを参照。アドレスの綴りと定義の有無を確認する" ;;
    *"Duplicate"*)
      echo "同名定義の重複。ファイル間で resource/variable/output 等を二重定義していないか確認する" ;;
    *"Module not installed"*|*"module is not yet installed"*)
      echo "モジュール未取得。terraform init を（再）実行する" ;;
    *"Invalid function argument"*)
      echo "関数の引数の型/形式が不正。merge・lookup・format 等に渡す値を確認する" ;;
    *"Invalid for_each argument"*)
      echo "for_each に apply 後まで確定しない値、または map/set 以外を渡している可能性" ;;
    *"Invalid count argument"*)
      echo "count に apply 後まで確定しない値を渡している可能性。段階適用（-target）か設計見直しを検討" ;;
    *"Unsupported block type"*)
      echo "ブロック名の誤記、またはプロバイダのバージョン不足。required_providers の version を確認する" ;;
    *"Provider configuration not present"*|*"provider configuration is required"*)
      echo "provider 設定の不整合。provider はルートモジュールで定義し、モジュールへは providers 引数で渡す（設計提案の節も参照）" ;;
    *"Inconsistent conditional result types"*)
      echo "三項演算子（condition ? a : b）の両辺の型が不一致" ;;
    *"Invalid value for input variable"*|*"Invalid value for variable"*)
      echo "variable の validation / 型制約に違反する値。tfvars の値と variable の type/validation を確認する" ;;
    *)
      echo "-" ;;
  esac
}

run_validate() {
  section "[3/8] terraform validate（構文・整合性チェックと結果分析）"

  if [[ "${INIT_RC}" -ne 0 ]]; then
    log_warn "init が失敗しているため validate をスキップします。"
    add_summary "terraform validate" "スキップ" "init 失敗のため"
    return 0
  fi

  local vjson="${WORKDIR}/validate.json"
  local rc=0
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

    # diagnostics を TSV 化（severity, summary, detail, file, line）
    jq -r '.diagnostics[]? | [
        .severity,
        (.summary // "-"),
        ((.detail // "-") | gsub("\n"; " ")),
        (.range.filename // "-"),
        ((.range.start.line // 0) | tostring)
      ] | @tsv' "${vjson}" > "${WORKDIR}/validate_diag.tsv" || true

    # ヒント列を付与
    while IFS="${TAB}" read -r sev summary detail file lineno; do
      [[ -z "${sev}" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${sev}" "${summary}" "${detail}" "${file}" "${lineno}" "$(validate_hint "${summary}")" \
        >> "${VALIDATE_TSV}"
    done < "${WORKDIR}/validate_diag.tsv"
  else
    # jq なし: valid 判定のみ簡易に行う
    if grep -q '"valid":true' "${vjson}" || grep -q '"valid": true' "${vjson}"; then
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
  add_summary "terraform validate" "エラー ${VALIDATE_ERRORS} 件 / 警告 ${VALIDATE_WARNINGS} 件" "詳細は validate の CSV/一覧を参照"

  printf '\n    ■ 診断一覧（重大度 | 概要 | 詳細 | ファイル | 行 | 原因と対処のヒント）\n'
  display_table "${VALIDATE_TSV}"
  printf '\n'
  log_info "上記の「原因と対処のヒント」列は代表的なエラーパターンからの推定です。"
  log_info "エラーを解消するまで plan/apply は先へ進めません。ファイル:行 を直接確認してください。"
}

# ---------------------------------------------------------------------------
# 9. [4/8] terraform plan（実行と結果分析）
# ---------------------------------------------------------------------------
run_plan() {
  section "[4/8] terraform plan（実行計画の作成と結果分析）"

  if [[ "${SKIP_PLAN}" == "true" ]]; then
    log_info "--skip-plan 指定のため plan をスキップします。"
    add_summary "terraform plan" "スキップ" "--skip-plan 指定"
    PLAN_RC=-1
    return 0
  fi
  if [[ "${INIT_RC}" -ne 0 ]]; then
    log_warn "init が失敗しているため plan をスキップします。"
    add_summary "terraform plan" "スキップ" "init 失敗のため"
    PLAN_RC=-1
    return 0
  fi
  if [[ "${VALIDATE_ERRORS}" -gt 0 ]]; then
    log_warn "validate エラーがあるため plan をスキップします（先に validate エラーを解消してください）。"
    add_summary "terraform plan" "スキップ" "validate エラーのため"
    PLAN_RC=-1
    return 0
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
      log_success "plan 成功: 変更はありません（コードと実環境/state が一致しています）。"
      add_summary "terraform plan" "成功（変更なし）" "コードと実環境が一致"
      ;;
    2)
      log_warn "plan 成功: 適用されていない変更があります。"
      add_summary "terraform plan" "成功（変更あり）" "$(grep -E '^Plan:' "${PLAN_LOG}" | tail -n 1 || echo '差分あり')"
      ;;
    *)
      OVERALL_RC=2
      log_error "plan 失敗（終了コード: ${PLAN_RC}）。エラー抜粋:"
      grep -E "Error" "${PLAN_LOG}" | head -n 10 | sed 's/^/    /' >&2 || true
      add_summary "terraform plan" "失敗" "ログ: ${PLAN_LOG}"
      analyze_tf_error_log "${PLAN_LOG}" "plan"
      return 0
      ;;
  esac

  # --- 変更内容の一覧化 ---
  if [[ "${HAVE_JQ}" == "true" && -f "${PLAN_BIN}" ]]; then
    terraform -chdir="${ROOT_DIR}" show -json "${PLAN_BIN}" > "${PLAN_JSON}" 2>/dev/null || true
  fi

  if [[ -s "${PLAN_JSON:-/nonexistent}" ]]; then
    # アクション別の件数集計
    printf '\n    ■ アクション別の変更件数\n'
    jq -r '[.resource_changes[]?.change.actions | join("+")]
           | group_by(.) | map([.[0], (length|tostring)]) | .[] | @tsv' "${PLAN_JSON}" \
      | sed "s/^no-op/no-op（変更なし）/" \
      | sed "s/${TAB}/  :  /" | sed 's/^/      /'

    # 変更対象の一覧（no-op 以外）
    jq -r '.resource_changes[]?
           | select((.change.actions | join(",")) != "no-op" and (.change.actions | join(",")) != "read")
           | [.address, .type, (.change.actions | join("+")), (.action_reason // "-")]
           | @tsv' "${PLAN_JSON}" > "${CHANGES_TSV}" || true

    printf '\n    ■ 変更対象リソース一覧（アドレス | 種別 | アクション | 理由）\n'
    printf '        ※ delete+create = 置換（リソースの作り直し）。replace_because_* は置換理由。\n'
    display_table "${CHANGES_TSV}"

    # 置換（作り直し）の強調
    local replace_count
    replace_count="$(awk -F'\t' '$3 ~ /create/ && $3 ~ /delete/ {n++} END{print n+0}' "${CHANGES_TSV}")"
    if [[ "${replace_count}" -gt 0 ]]; then
      log_warn "リソースの置換（削除→再作成）が ${replace_count} 件含まれます。ダウンタイム・データ消失の可能性を必ず確認してください。"
    fi

    # 削除の強調
    local delete_only
    delete_only="$(awk -F'\t' '$3 == "delete" {n++} END{print n+0}' "${CHANGES_TSV}")"
    if [[ "${delete_only}" -gt 0 ]]; then
      log_warn "純粋な削除が ${delete_only} 件含まれます。意図した削除か確認してください（state からの消滅を含む）。"
    fi

    # apply 後まで確定しない値（known after apply）を多く含むリソース
    printf '\n    ■ apply 後まで値が確定しない属性（known after apply）が多いリソース（上位10）\n'
    jq -r '.resource_changes[]?
           | select(.change.after_unknown != null and ((.change.actions|join(",")) != "no-op"))
           | [.address, ((.change.after_unknown | [.. | select(. == true)] | length) | tostring)]
           | @tsv' "${PLAN_JSON}" 2>/dev/null \
      | sort -t"${TAB}" -k2,2nr | head -n 10 \
      | sed "s/${TAB}/  :  /" | sed 's/^/      /' || true
    printf '        ※ 件数が多いほど apply 中に初めて確定する値が多く、apply 時エラーの余地が残ります。\n'

    # 出力値の変更
    local outchg="${WORKDIR}/output_changes.tsv"
    jq -r '.output_changes // {} | to_entries[]
           | select((.value.actions | join(",")) != "no-op")
           | [.key, (.value.actions | join("+"))] | @tsv' "${PLAN_JSON}" > "${outchg}" || true
    if [[ -s "${outchg}" ]]; then
      printf '\n    ■ output（出力値）の変更\n'
      display_table "${outchg}"
    fi
  else
    # jq なし or show 失敗: plan テキストから簡易抽出
    log_warn "plan JSON の解析ができないため、テキストログから簡易集計します。"
    grep -E '^Plan:|^No changes' "${PLAN_LOG}" | sed 's/^/    /' || true
    grep -E '^[[:space:]]*# .* (will be|must be)' "${PLAN_LOG}" \
      | sed -e 's/^[[:space:]]*# //' \
            -e 's/ will be created/\tcreate/' \
            -e 's/ will be updated in-place/\tupdate/' \
            -e 's/ will be destroyed/\tdelete/' \
            -e 's/ must be replaced/\tdelete+create/' \
      | awk -F'\t' '{ t=$1; sub(/\[.*/,"",t); n=split(t,a,"."); type=(n>=2? a[n-1] : "-"); printf "%s\t%s\t%s\t-\n", $1, type, $2 }' \
      > "${CHANGES_TSV}" || true
    printf '\n    ■ 変更対象リソース一覧（アドレス | 種別 | アクション | 理由）\n'
    display_table "${CHANGES_TSV}"
  fi
}

# ---------------------------------------------------------------------------
# 10. [5/8] apply リスク分析（plan は成功しても apply で失敗し得る箇所）
# ---------------------------------------------------------------------------
risk_for_change() {
  local addr="$1" type="$2" action="$3" reason="$4"
  local is_create="false" is_delete="false" is_update="false" is_replace="false"
  [[ "${action}" == *create* ]] && is_create="true"
  [[ "${action}" == *delete* ]] && is_delete="true"
  [[ "${action}" == *update* ]] && is_update="true"
  [[ "${action}" == *create* && "${action}" == *delete* ]] && is_replace="true"

  if [[ "${is_replace}" == "true" ]]; then
    add_risk "${addr}" "${action}" "置換（削除→再作成）に伴うダウンタイム/データ消失" "置換理由（${reason}）を確認。名前固定のリソースで create_before_destroy を使うと同名衝突するため注意"
  fi

  case "${type}" in
    aws_s3_bucket)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "バケット名はグローバル一意。既存名と重複すると BucketAlreadyExists で apply 失敗" "命名にアカウント ID や環境名を含め一意性を担保する"
      [[ "${is_delete}" == "true" ]] && add_risk "${addr}" "${action}" "オブジェクトが残っていると BucketNotEmpty で削除失敗。削除直後の同名再作成は待ちが発生" "事前にバケットを空にする（force_destroy = true の検討）"
      ;;
    aws_iam_role|aws_iam_policy|aws_iam_user|aws_iam_instance_profile)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "同名 IAM エンティティが手動作成済みだと EntityAlreadyExists で失敗。作成直後は伝播遅延で参照側が一時失敗することがある" "既存 IAM を確認し、必要なら import する。参照側エラーはリトライで解消することが多い"
      [[ "${is_delete}" == "true" ]] && add_risk "${addr}" "${action}" "ポリシー/インスタンスプロファイルがアタッチされたままだと DeleteConflict で失敗" "アタッチ関係のリソースも同時に管理・削除されているか確認"
      ;;
    aws_iam_role_policy_attachment|aws_iam_policy_attachment)
      add_risk "${addr}" "${action}" "IAM 変更の伝播遅延により、直後にそのロールを使うリソース作成が一時的に失敗することがある" "apply の再実行（リトライ）で解消するか確認"
      ;;
    aws_security_group)
      [[ "${is_delete}" == "true" ]] && add_risk "${addr}" "${action}" "他リソース（ENI/EC2/RDS 等）から参照中だと DependencyViolation で削除失敗・タイムアウト" "参照元を先に付け替える。置換時は create_before_destroy と name_prefix の併用を検討"
      ;;
    aws_security_group_rule)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "同一内容のルールが既に存在すると Duplicate エラーで失敗（手動追加や inline ルールとの競合）" "inline ルールと aws_security_group_rule の併用を避ける"
      ;;
    aws_instance)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "InsufficientInstanceCapacity / vCPU クォータ超過 / AMI・キーペアが対象リージョンに無い、で失敗し得る" "Service Quotas と AMI ID のリージョン整合を事前確認"
      [[ "${is_update}" == "true" ]] && add_risk "${addr}" "${action}" "instance_type 等の変更は再起動（停止→起動）を伴う場合がある" "メンテナンス時間帯での適用を検討"
      ;;
    aws_eip)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "EIP のアカウント上限（既定 5/リージョン）超過で失敗し得る" "Service Quotas を確認"
      ;;
    aws_db_instance|aws_rds_cluster|aws_rds_cluster_instance)
      [[ "${is_delete}" == "true" ]] && add_risk "${addr}" "${action}" "deletion_protection 有効だと削除失敗。skip_final_snapshot=false の場合 final_snapshot_identifier 必須" "削除保護の解除手順と最終スナップショット設定を確認"
      [[ "${is_update}" == "true" ]] && add_risk "${addr}" "${action}" "apply_immediately 未指定の変更は次回メンテナンスウィンドウまで適用されない。一部変更は再起動を伴う" "適用タイミングと再起動有無をパラメータごとに確認"
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "作成に長時間かかりタイムアウトし得る。パスワード文字種制約・サブネットグループの AZ 要件違反で失敗し得る" "timeouts ブロックの設定とパラメータ制約を確認"
      ;;
    aws_kms_key)
      [[ "${is_delete}" == "true" ]] && add_risk "${addr}" "${action}" "KMS キーは即時削除不可（7〜30 日の待機）。削除予約中の再作成で運用が複雑化" "削除の必要性を再確認"
      ;;
    aws_kms_alias)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "エイリアス名はアカウント×リージョン内で一意。既存と重複すると AlreadyExists で失敗" "既存エイリアスを確認"
      ;;
    aws_ecr_repository)
      [[ "${is_delete}" == "true" ]] && add_risk "${addr}" "${action}" "イメージが残っていると RepositoryNotEmpty で削除失敗" "force_delete = true の検討、または事前にイメージ削除"
      ;;
    aws_cloudwatch_log_group)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "Lambda 等が同名 log group を自動作成済みだと ResourceAlreadyExists で失敗" "既存 log group を import するか名前を確認"
      ;;
    aws_lambda_function)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "IAM ロール伝播遅延による InvalidParameterValueException（リトライで解消）、パッケージサイズ超過で失敗し得る" "初回失敗時は再 apply を試す"
      ;;
    aws_acm_certificate|aws_acm_certificate_validation)
      add_risk "${addr}" "${action}" "DNS/メール検証が完了しないと validation がタイムアウトする（既定 45 分等）" "検証用 Route53 レコードの作成有無・DNS 委任を確認"
      ;;
    aws_route53_record)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "同名レコードが既に存在すると作成に失敗する" "allow_overwrite の設定と既存レコードを確認"
      ;;
    aws_lb|aws_alb|aws_elb)
      [[ "${is_create}" == "true" ]] && add_risk "${addr}" "${action}" "LB 名はリージョン内一意。ALB/NLB は 2 AZ 以上のサブネット必須" "命名とサブネット構成を確認"
      ;;
    aws_subnet|aws_vpc)
      [[ "${is_delete}" == "true" ]] && add_risk "${addr}" "${action}" "ENI 等の依存リソースが残っていると DependencyViolation で削除失敗" "依存リソース（ENI/エンドポイント/NAT GW 等）の削除順序を確認"
      [[ "${is_create}" == "true" && "${type}" == "aws_subnet" ]] && add_risk "${addr}" "${action}" "CIDR が既存サブネットと重複すると InvalidSubnet.Conflict で失敗" "CIDR 設計を確認"
      ;;
    aws_eks_cluster|aws_eks_node_group)
      add_risk "${addr}" "${action}" "作成/更新/削除に長時間かかりタイムアウトし得る" "timeouts ブロックの設定を検討"
      ;;
    aws_autoscaling_group)
      [[ "${is_delete}" == "true" ]] && add_risk "${addr}" "${action}" "インスタンスの終了待ちで削除に時間がかかる/タイムアウトし得る" "force_delete や timeouts の設定を確認"
      ;;
  esac
}

analyze_apply_risks() {
  section "[5/8] apply リスク分析（plan 成功でも apply で問題になり得る箇所）"

  if [[ ! -s "${CHANGES_TSV}" && "${PLAN_RC}" != "0" ]]; then
    log_info "plan の変更一覧が無いため、静的チェックのみ実施します。"
  fi

  # --- plan の変更一覧に基づくリソース種別×アクション別のリスク ---
  if [[ -s "${CHANGES_TSV}" ]]; then
    while IFS="${TAB}" read -r addr type action reason; do
      [[ -z "${addr}" ]] && continue
      risk_for_change "${addr}" "${type}" "${action}" "${reason}"
    done < "${CHANGES_TSV}"
  fi

  # --- 静的チェック（変更の有無に依存しない全般リスク） ---
  local scan_dirs=("${ROOT_DIR}")
  local d
  for d in "${LOCAL_MODULE_DIRS[@]:-}"; do
    [[ -n "${d}" ]] && scan_dirs+=("${d}")
  done

  # provisioner: apply 時にのみ実行され、plan では検証されない
  local prov
  prov="$(grep -rnE '^[[:space:]]*provisioner[[:space:]]+"' "${scan_dirs[@]}" --include='*.tf' 2>/dev/null | head -n 20 || true)"
  if [[ -n "${prov}" ]]; then
    while IFS= read -r line; do
      add_risk "${line%%:*}:$(echo "${line}" | cut -d: -f2)" "(静的検出)" "provisioner は plan で検証されず apply 時に初めて実行・失敗する" "接続情報(SSH/WinRM)・スクリプトの冪等性を事前確認。可能なら user_data や SSM への置換を検討"
    done <<< "${prov}"
  fi

  # prevent_destroy: 削除がかかる apply/destroy はエラーで停止する
  local pd
  pd="$(grep -rnE 'prevent_destroy[[:space:]]*=[[:space:]]*true' "${scan_dirs[@]}" --include='*.tf' 2>/dev/null | head -n 20 || true)"
  if [[ -n "${pd}" ]]; then
    while IFS= read -r line; do
      add_risk "${line%%:*}:$(echo "${line}" | cut -d: -f2)" "(静的検出)" "prevent_destroy = true のため、置換/削除を伴う変更は apply がエラーで停止する" "置換が必要な変更を入れる前に lifecycle 設定の扱いを合意しておく"
    done <<< "${pd}"
  fi

  # 削除を伴う plan がある場合の一般リスク
  if [[ -s "${CHANGES_TSV}" ]] && awk -F'\t' '$3 ~ /delete/ {found=1} END{exit !found}' "${CHANGES_TSV}"; then
    add_risk "(全般)" "delete を含む" "削除順序の依存関係により DependencyViolation 等で途中失敗し、環境が中途半端な状態になり得る" "重要環境では削除を伴う apply の前に state バックアップ（terraform state pull）を取得する"
  fi

  # state ロック（同時実行）
  if [[ "${PLAN_RC}" == "0" || "${PLAN_RC}" == "2" ]]; then
    add_risk "(全般)" "apply 時" "plan 成功後〜apply までに他者が変更すると差分が変わる。CI 等の同時実行では state ロック競合も発生" "保存済み plan（plan.bin）を使った apply、または短時間での plan→apply を徹底"
  fi

  if [[ -s "${RISKS_TSV}" ]]; then
    local risk_count
    risk_count="$(wc -l < "${RISKS_TSV}")"
    log_warn "apply 時に注意すべきポイントを ${risk_count} 件検出しました:"
    printf '\n    ■ リスク一覧（対象 | アクション | リスク内容 | 対処・確認事項）\n'
    display_table "${RISKS_TSV}"
    add_summary "apply リスク分析" "${risk_count} 件の注意点" "詳細はリスク一覧の CSV/一覧を参照"
  else
    log_success "既知パターンに該当する apply 時リスクは検出されませんでした。"
    add_summary "apply リスク分析" "指摘なし" "既知パターンに該当なし"
  fi
  printf '\n'
  log_info "※ 本分析はリソース種別×アクションに基づくヒューリスティックです。クォータ・実環境の手動変更など、コードから読み取れない要因は網羅できません。"
}

# ---------------------------------------------------------------------------
# 11. モジュール情報の収集（[6][7] の前処理）
# ---------------------------------------------------------------------------
LOCAL_MODULE_DIRS=()
collect_modules() {
  MODULES_RAW="${WORKDIR}/modules_raw.tsv"
  find "${ROOT_DIR}" -maxdepth 1 -name '*.tf' -type f -print0 2>/dev/null \
    | xargs -0 awk -f "${WORKDIR}/parse_modules.awk" > "${MODULES_RAW}" 2>/dev/null || true

  MODULE_NAMES=()
  local name
  while IFS="${TAB}" read -r kind name file; do
    [[ "${kind}" == "MODULE" ]] || continue
    MODULE_NAMES+=("${name}")
  done < "${MODULES_RAW}"

  # 各モジュールの source と（ローカルなら）実ディレクトリを解決
  local mod src dir
  for mod in "${MODULE_NAMES[@]:-}"; do
    [[ -z "${mod}" ]] && continue
    src="$(awk -F'\t' -v m="${mod}" '$1=="ARG" && $2==m && $3=="source" {print $4; exit}' "${MODULES_RAW}" | tr -d '"' | sed 's/,$//')"
    printf '%s\t%s\n' "${mod}" "${src:-?}" >> "${WORKDIR}/module_sources.tsv"
    case "${src}" in
      ./*|../*)
        if dir="$(cd "${ROOT_DIR}" && cd "${src}" 2>/dev/null && pwd)"; then
          printf '%s\t%s\n' "${mod}" "${dir}" >> "${WORKDIR}/module_dirs.tsv"
          LOCAL_MODULE_DIRS+=("${dir}")
        else
          log_warn "モジュール '${mod}' の source が解決できません: ${src}"
        fi
        ;;
    esac
  done

  # 重複除去
  if [[ "${#LOCAL_MODULE_DIRS[@]}" -gt 0 ]]; then
    local -a uniq=()
    while IFS= read -r dir; do
      uniq+=("${dir}")
    done < <(printf '%s\n' "${LOCAL_MODULE_DIRS[@]}" | sort -u)
    LOCAL_MODULE_DIRS=("${uniq[@]}")
  fi
  log_debug "検出モジュール数: ${#MODULE_NAMES[@]} / ローカルモジュールディレクトリ: ${#LOCAL_MODULE_DIRS[@]}"
}

# ---------------------------------------------------------------------------
# 12. [6/8] モジュール入力の過不足分析
# ---------------------------------------------------------------------------
analyze_module_inputs() {
  section "[6/8] モジュール入力の過不足分析（呼び出し側 vs モジュール側 variables）"

  if [[ "${#MODULE_NAMES[@]}" -eq 0 ]]; then
    log_info "ルートモジュールに module ブロックが見つかりませんでした。"
    add_summary "モジュール入力分析" "対象なし" "module ブロックなし"
    return 0
  fi

  local mod src dir ng_count=0 info_count=0
  for mod in "${MODULE_NAMES[@]}"; do
    src="$(awk -F'\t' -v m="${mod}" '$1==m {print $2; exit}' "${WORKDIR}/module_sources.tsv" 2>/dev/null || echo '?')"
    dir="$(awk -F'\t' -v m="${mod}" '$1==m {print $2; exit}' "${WORKDIR}/module_dirs.tsv" 2>/dev/null || true)"

    if [[ -z "${dir}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${mod}" "${src}" "(全体)" "-" "-" "解析対象外" "レジストリ/リモート source のため静的解析不可（validate/plan の結果で担保）" \
        >> "${MODINPUT_TSV}"
      continue
    fi

    # モジュール側の variable 宣言
    local vars_tsv="${WORKDIR}/vars_${mod}.tsv"
    find "${dir}" -maxdepth 1 -name '*.tf' -type f -print0 2>/dev/null \
      | xargs -0 awk -f "${WORKDIR}/parse_variables.awk" > "${vars_tsv}" 2>/dev/null || true

    # 呼び出し側で渡している引数（メタ引数は除外）
    local args_tsv="${WORKDIR}/args_${mod}.tsv"
    awk -F'\t' -v m="${mod}" \
      '$1=="ARG" && $2==m && $3!="source" && $3!="version" && $3!="count" && $3!="for_each" && $3!="depends_on" && $3!="providers" {print $3 "\t" $4}' \
      "${MODULES_RAW}" > "${args_tsv}" || true

    # --- モジュール側の各 variable について、渡し状況を判定 ---
    local vname vreq vtype vdef vdesc passed
    while IFS="${TAB}" read -r kind vname vreq vtype vdef vdesc; do
      [[ "${kind}" == "VAR" ]] || continue
      if awk -F'\t' -v k="${vname}" '$1==k {found=1} END{exit !found}' "${args_tsv}"; then
        passed="渡している"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${mod}" "${src}" "${vname}" "$( [[ "${vreq}" == "required" ]] && echo '必須' || echo '任意' )" \
          "${passed}" "OK" "-" >> "${MODINPUT_TSV}"
      else
        if [[ "${vreq}" == "required" ]]; then
          ng_count=$((ng_count + 1))
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${mod}" "${src}" "${vname}" "必須" "渡していない" "NG: 不足" \
            "必須変数の渡し漏れ。validate/plan が Missing required argument で失敗する" >> "${MODINPUT_TSV}"
        else
          info_count=$((info_count + 1))
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${mod}" "${src}" "${vname}" "任意" "渡していない（default 使用）" "情報" \
            "default 値（${vdef}）が適用される。環境ごとに変えるべき値なら明示指定を推奨" >> "${MODINPUT_TSV}"
        fi
      fi
    done < "${vars_tsv}"

    # --- 呼び出し側で渡しているが、モジュール側に宣言が無い引数（過剰） ---
    local aname aval
    while IFS="${TAB}" read -r aname aval; do
      [[ -z "${aname}" ]] && continue
      if ! awk -F'\t' -v k="${aname}" '$2==k {found=1} END{exit !found}' "${vars_tsv}"; then
        ng_count=$((ng_count + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${mod}" "${src}" "${aname}" "(宣言なし)" "渡している" "NG: 過剰" \
          "モジュール側に variable 宣言が無い。validate が Unsupported argument で失敗する（変数名の誤記の可能性）" >> "${MODINPUT_TSV}"
      fi
    done < "${args_tsv}"
  done

  printf '\n    ■ 入力一覧（モジュール | source | 変数 | 必須/任意 | 渡し状況 | 判定 | 備考）\n'
  display_table "${MODINPUT_TSV}"
  printf '\n'

  if [[ "${ng_count}" -gt 0 ]]; then
    log_error "入力の過不足（NG）が ${ng_count} 件あります。validate の結果と突き合わせて修正してください。"
  else
    log_success "入力の過不足（NG）はありません。"
  fi
  [[ "${info_count}" -gt 0 ]] && \
    log_info "default に依存している任意変数が ${info_count} 件あります。環境差分になり得る値は明示指定を検討してください。"
  add_summary "モジュール入力分析" "NG ${ng_count} 件 / default 依存 ${info_count} 件" "詳細はモジュール入力の CSV/一覧を参照"
  log_info "※ 静的解析のため、複雑な HCL（動的ブロック等）は判定できない場合があります。最終的な正は validate/plan の結果です。"
}

# ---------------------------------------------------------------------------
# 13. [7/8] モジュール設計の改善提案
#      （再利用モジュール側の定義で、ルートモジュール側に定義した方が良い項目）
# ---------------------------------------------------------------------------
add_suggest() { # モジュール, 場所, 種別, 内容, 提案
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "${MODSUGGEST_TSV}"
}

analyze_module_design() {
  section "[7/8] モジュール設計の改善提案（ルートモジュール側へ移すべき項目）"

  if [[ "${#LOCAL_MODULE_DIRS[@]}" -eq 0 ]]; then
    log_info "ローカルの再利用モジュールが無いため、この分析はスキップします。"
    add_summary "モジュール設計提案" "対象なし" "ローカルモジュールなし"
    return 0
  fi

  local mod dir
  while IFS="${TAB}" read -r mod dir; do
    [[ -z "${mod}" ]] && continue

    # (a) モジュール内の provider 定義（アンチパターン: ルートで定義すべき）
    local hits
    hits="$(grep -rnE '^[[:space:]]*provider[[:space:]]+"' "${dir}" --include='*.tf' 2>/dev/null || true)"
    if [[ -n "${hits}" ]]; then
      while IFS= read -r line; do
        add_suggest "${mod}" "${line%%:*}:$(echo "${line}" | cut -d: -f2)" "provider 定義" \
          "再利用モジュール内に provider ブロックがある" \
          "provider はルートモジュールで定義し、モジュールへは providers 引数で渡す。モジュール内 provider は for_each/count 併用不可・削除時に provider 消失で apply 不能になる公式非推奨構成"
      done <<< "${hits}"
    fi

    # (b) モジュール内の backend 定義（state はルートで管理すべき）
    hits="$(grep -rnE '^[[:space:]]*backend[[:space:]]+"' "${dir}" --include='*.tf' 2>/dev/null || true)"
    if [[ -n "${hits}" ]]; then
      while IFS= read -r line; do
        add_suggest "${mod}" "${line%%:*}:$(echo "${line}" | cut -d: -f2)" "backend 定義" \
          "再利用モジュール内に backend 設定がある" \
          "backend 設定はルートモジュールにのみ置く（モジュール内の backend は無視されるか混乱の元になる）"
      done <<< "${hits}"
    fi

    # (c) 環境依存らしき default 値を持つ variable（ルート/tfvars で指定すべき）
    local vars_tsv="${WORKDIR}/vars_${mod}.tsv"
    if [[ -f "${vars_tsv}" ]]; then
      local kind vname vreq vtype vdef vdesc
      while IFS="${TAB}" read -r kind vname vreq vtype vdef vdesc; do
        [[ "${kind}" == "VAR" && "${vreq}" == "optional" ]] || continue
        if printf '%s' "${vdef}" | grep -qE 'ami-[0-9a-f]{8}|arn:aws[a-z-]*:|[^0-9][0-9]{12}[^0-9]|^[0-9]{12}$|(ap|us|eu|sa|ca|me|af|il)-[a-z]+-[0-9]|([0-9]{1,3}\.){3}[0-9]{1,3}|vpc-[0-9a-f]|subnet-[0-9a-f]|sg-[0-9a-f]'; then
          add_suggest "${mod}" "variable \"${vname}\"" "環境依存 default" \
            "default に環境依存らしき値（${vdef}）が入っている" \
            "default を外して必須化するか、ルートモジュール（tfvars）から明示的に渡す。モジュールを別環境で再利用した際の事故（別環境のリソース ID 参照等）を防止"
        fi
      done < "${vars_tsv}"
    fi

    # (d) モジュール内リソースへの環境依存値の直書き（variables.tf 以外）
    hits="$(grep -rnE 'ami-[0-9a-f]{8}|arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}:|(ap|us|eu|sa|ca|me|af|il)-[a-z]+-[0-9][a-z]?' \
              "${dir}" --include='*.tf' 2>/dev/null \
            | grep -vE '/variables\.tf:' \
            | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(#|//)' \
            | head -n 20 || true)"
    if [[ -n "${hits}" ]]; then
      while IFS= read -r line; do
        add_suggest "${mod}" "${line%%:*}:$(echo "${line}" | cut -d: -f2)" "ハードコード疑い" \
          "AMI ID / ARN / リージョン等の直書き疑い: $(echo "${line}" | cut -d: -f3- | sed 's/^[[:space:]]*//' | cut -c1-80)" \
          "variable 化してルートモジュールから注入する（data source での動的解決も検討）"
      done <<< "${hits}"
    fi

    # (e) モジュール内での tags 直書き（マージ用の変数を受けていない場合）
    local tags_hard
    tags_hard="$(grep -rnE '^[[:space:]]*tags[[:space:]]*=[[:space:]]*\{' "${dir}" --include='*.tf' 2>/dev/null | head -n 10 || true)"
    if [[ -n "${tags_hard}" ]]; then
      local has_tags_var="false"
      if [[ -f "${vars_tsv}" ]] && awk -F'\t' '$2 ~ /tags/ {found=1} END{exit !found}' "${vars_tsv}"; then
        has_tags_var="true"
      fi
      if [[ "${has_tags_var}" == "false" ]]; then
        while IFS= read -r line; do
          add_suggest "${mod}" "${line%%:*}:$(echo "${line}" | cut -d: -f2)" "タグ直書き" \
            "モジュール内で tags をリテラル定義しており、tags 系の variable も受けていない" \
            "variable \"tags\" を追加し merge(var.tags, {...}) とする。共通タグはルートの provider default_tags へ寄せる"
        done <<< "${tags_hard}"
      fi
    fi
  done < "${WORKDIR}/module_dirs.tsv"

  if [[ -s "${MODSUGGEST_TSV}" ]]; then
    local n
    n="$(wc -l < "${MODSUGGEST_TSV}")"
    log_warn "ルートモジュール側へ移す/注入することを検討すべき項目が ${n} 件あります:"
    printf '\n    ■ 提案一覧（モジュール | 場所 | 種別 | 内容 | 提案）\n'
    display_table "${MODSUGGEST_TSV}"
    add_summary "モジュール設計提案" "${n} 件の提案" "詳細は設計提案の CSV/一覧を参照"
  else
    log_success "再利用モジュール側の定義に、ルートへ移すべき項目は検出されませんでした。"
    add_summary "モジュール設計提案" "指摘なし" "provider/backend/環境依存値の直書きなし"
  fi
  printf '\n'
  log_info "※ 判定はパターンマッチによる推定です。意図した設計（例: 全環境共通の固定値）であれば提案を無視して構いません。"
}

# ---------------------------------------------------------------------------
# 14. [8/8] タグ分析（設定内容と、実際に設定されるタグの予想）
# ---------------------------------------------------------------------------
analyze_tags() {
  section "[8/8] タグ分析（default_tags / タグ入力 / 実際に設定されるタグの予想）"

  # --- (1) provider default_tags の定義内容（静的解析） ---
  printf '    ■ provider "aws" の default_tags 定義（静的解析）\n'
  find "${ROOT_DIR}" -maxdepth 1 -name '*.tf' -type f -print0 2>/dev/null \
    | xargs -0 awk -f "${WORKDIR}/parse_default_tags.awk" > "${WORKDIR}/deftags_raw.tsv" 2>/dev/null || true

  if [[ -s "${WORKDIR}/deftags_raw.tsv" ]]; then
    local kind alias k v f
    while IFS="${TAB}" read -r kind alias k v f; do
      case "${kind}" in
        DTKEY) printf '%s\t%s\t%s\n' "provider aws (alias: ${alias})" "${k}" "${v}" >> "${DEFTAGS_TSV}" ;;
        DTREF) printf '%s\t%s\t%s\n' "provider aws (alias: ${alias})" "(式)" "${k}" >> "${DEFTAGS_TSV}" ;;
      esac
    done < "${WORKDIR}/deftags_raw.tsv"
    display_table "${DEFTAGS_TSV}"
    printf '        ※ default_tags は、そのプロバイダで作成される全リソースの tags_all に自動的に付与されます。\n'
  else
    printf '      （default_tags の定義なし）\n'
    printf '%s\t%s\t%s\n' "provider aws" "(定義なし)" "-" >> "${DEFTAGS_TSV}"
    log_info "  【提案】共通タグ（Environment / Project / ManagedBy 等）は provider default_tags での一括付与を推奨します。"
  fi

  # --- (2) モジュールへ渡しているタグ系入力（静的解析） ---
  printf '\n    ■ モジュール呼び出しで渡しているタグ系入力（静的解析）\n'
  local modtags="${WORKDIR}/module_tags.tsv"
  awk -F'\t' '$1=="ARG" && $3 ~ /(^tags$|_tags$|^tags_)/ {printf "module.%s\t%s\t%s\n", $2, $3, $4}' \
    "${MODULES_RAW:-/dev/null}" > "${modtags}" 2>/dev/null || true
  display_table "${modtags}"

  # --- (3) plan JSON に基づく「実際に設定されるタグ」の予想一覧 ---
  printf '\n    ■ 実際に設定されるタグの予想一覧（plan JSON の tags_all に基づく）\n'
  if [[ "${HAVE_JQ}" == "true" && -s "${PLAN_JSON:-/nonexistent}" ]]; then
    # tags_all（provider default_tags 込みの最終タグ）を、由来付きで一覧化
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

    # tags_all 全体が apply 後確定のリソース
    jq -r '.resource_changes[]?
      | select(.change.after_unknown != null and (.change.after_unknown | type == "object") and (.change.after_unknown.tags_all? == true))
      | [.address, .type, "(全タグ)", "(apply後に確定)", "-"] | @tsv' "${PLAN_JSON}" >> "${TAGS_TSV}" 2>/dev/null || true

    # 一部タグ値のみ apply 後確定のリソース
    jq -r '.resource_changes[]?
      | select(.change.after_unknown != null and (.change.after_unknown | type == "object") and ((.change.after_unknown.tags_all? | type) == "object"))
      | . as $rc
      | ($rc.change.after_unknown.tags_all | to_entries[] | select(.value == true))
      | [$rc.address, $rc.type, .key, "(apply後に確定)", "リソース/モジュール指定"] | @tsv' "${PLAN_JSON}" >> "${TAGS_TSV}" 2>/dev/null || true

    if [[ -s "${TAGS_TSV}" ]]; then
      sort -t"${TAB}" -k1,1 -k3,3 -o "${TAGS_TSV}" "${TAGS_TSV}"
      printf '      （リソース | 種別 | タグキー | 予想される値 | 由来）\n'
      display_table "${TAGS_TSV}"
      local tag_res_count
      tag_res_count="$(cut -f1 "${TAGS_TSV}" | sort -u | wc -l)"
      add_summary "タグ分析" "${tag_res_count} リソースのタグを予想" "plan JSON の tags_all に基づく（由来付き）"

      # タグ付け漏れ（tags_all が空）の検出
      local untagged="${WORKDIR}/untagged.tsv"
      jq -r '.resource_changes[]?
        | select(.change.after != null and (.change.after | type == "object") and (.change.after | has("tags_all")))
        | select((.change.actions | join(",")) != "delete")
        | select(((.change.after.tags_all // {}) | length) == 0)
        | [.address, .type] | @tsv' "${PLAN_JSON}" > "${untagged}" 2>/dev/null || true
      if [[ -s "${untagged}" ]]; then
        printf '\n'
        log_warn "タグが 1 つも設定されないリソースがあります（コスト配賦・棚卸しの観点で要確認）:"
        display_table "${untagged}"
      fi
    else
      printf '      （タグ対応リソースの変更が plan に含まれていません）\n'
      add_summary "タグ分析" "対象なし" "plan にタグ対応リソースの変更なし"
    fi
    printf '\n'
    log_info "※ tags_all は provider default_tags とリソース個別 tags のマージ結果で、AWS に実際に付与されるタグと一致します。"
    log_info "※ 「由来」列: リソース/モジュール指定 = resource の tags で指定、provider default_tags = プロバイダ既定タグから継承。"
    log_info "※ 同一キーが両方にある場合はリソース個別 tags が default_tags を上書きします。"
  else
    if [[ "${SKIP_PLAN}" == "true" ]]; then
      printf '      （--skip-plan のため予想不可。上記 (1)(2) の静的解析結果を参照してください）\n'
      add_summary "タグ分析" "静的解析のみ" "--skip-plan のため tags_all 予想なし"
    elif [[ "${HAVE_JQ}" != "true" ]]; then
      printf '      （jq が無いため予想不可。jq をインストールすると tags_all ベースの正確な予想一覧を出力できます）\n'
      add_summary "タグ分析" "静的解析のみ" "jq 未インストールのため tags_all 予想なし"
    else
      printf '      （plan が失敗/スキップされたため予想不可）\n'
      add_summary "タグ分析" "静的解析のみ" "plan 未取得のため tags_all 予想なし"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 15. Excel 向け CSV 出力（--csv-dir 指定時）
# ---------------------------------------------------------------------------
tsv_to_csv() {
  local tsv="$1" csv="$2" header="$3"
  {
    [[ "${CSV_ENCODING}" == "utf8bom" ]] && printf '\357\273\277'
    printf '%s' "${header}" | awk -F'\t' \
      '{ out=""; for (i=1; i<=NF; i++) { g=$i; gsub(/"/,"\"\"",g); out = out (i>1 ? "," : "") "\"" g "\"" } printf "%s\r\n", out }'
    if [[ -s "${tsv}" ]]; then
      awk -F'\t' \
        '{ out=""; for (i=1; i<=NF; i++) { g=$i; gsub(/"/,"\"\"",g); out = out (i>1 ? "," : "") "\"" g "\"" } printf "%s\r\n", out }' \
        "${tsv}"
    fi
  } > "${csv}"

  if [[ "${CSV_ENCODING}" == "cp932" ]]; then
    local tmp="${csv}.cp932"
    if iconv -f UTF-8 -t CP932//TRANSLIT "${csv}" > "${tmp}" 2>/dev/null; then
      mv "${tmp}" "${csv}"
    else
      rm -f "${tmp}"
      log_warn "CP932 変換に失敗したため UTF-8 のまま出力します: ${csv}"
    fi
  fi
}

write_csv_reports() {
  [[ -n "${CSV_DIR}" ]] || return 0
  section "Excel 向け CSV 出力"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local out="${CSV_DIR}/tfcheck_${ts}"
  mkdir -p "${out}"

  tsv_to_csv "${SUMMARY_TSV}"    "${out}/01_サマリ.csv"                "項目	結果	詳細"
  tsv_to_csv "${VALIDATE_TSV}"   "${out}/02_validate結果.csv"          "重大度	概要	詳細	ファイル	行	原因と対処のヒント"
  tsv_to_csv "${FMT_TSV}"        "${out}/03_fmt要整形ファイル.csv"     "ディレクトリ	対象ファイル"
  tsv_to_csv "${CHANGES_TSV}"    "${out}/04_plan変更一覧.csv"          "リソースアドレス	種別	アクション	理由"
  tsv_to_csv "${RISKS_TSV}"      "${out}/05_applyリスク一覧.csv"       "対象	アクション	リスク内容	対処・確認事項"
  tsv_to_csv "${MODINPUT_TSV}"   "${out}/06_モジュール入力過不足.csv"  "モジュール	source	変数	必須任意	渡し状況	判定	備考"
  tsv_to_csv "${MODSUGGEST_TSV}" "${out}/07_モジュール設計提案.csv"    "モジュール	場所	種別	内容	提案"
  tsv_to_csv "${TAGS_TSV}"       "${out}/08_タグ予想一覧.csv"          "リソース	種別	タグキー	予想される値	由来"
  tsv_to_csv "${DEFTAGS_TSV}"    "${out}/09_default_tags定義.csv"      "定義箇所	タグキー	値または式"

  log_success "CSV を出力しました: ${out}"
  log_info "  文字コード: $( [[ "${CSV_ENCODING}" == "utf8bom" ]] && echo 'UTF-8 (BOM 付き)' || echo 'Shift_JIS (CP932)' ) / 改行: CRLF / 全フィールド引用符付き（Excel でそのまま開けます）"
  ls -1 "${out}" | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# 16. 最終サマリ
# ---------------------------------------------------------------------------
final_summary() {
  section "総合サマリ"
  printf '    ルートモジュール : %s\n' "${ROOT_DIR}"
  printf '    terraform        : %s\n' "$(terraform version 2>/dev/null | head -n 1)"
  printf '    実行日時         : %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '    ■ 項目 | 結果 | 詳細\n'
  display_table "${SUMMARY_TSV}"
  printf '\n'
  printf '    ログ/中間ファイル: %s\n' "${WORKDIR}"

  if [[ "${OVERALL_RC}" -eq 0 ]]; then
    log_success "チェック完了: init / validate / plan にエラーはありません。"
  else
    log_error "チェック完了: エラーが検出されています。上記の原因分析と一覧を確認してください。"
  fi
}

# ---------------------------------------------------------------------------
# 17. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight
  setup_workdir

  log_info "=== 実行内容 ==="
  log_info "  ルートモジュール : ${ROOT_DIR}"
  log_info "  plan 実行        : $( [[ "${SKIP_PLAN}" == "true" ]] && echo 'しない (--skip-plan)' || echo 'する' )"
  log_info "  CSV 出力         : ${CSV_DIR:-（画面表示のみ）}"
  log_info "  自動スイッチバック: ${AUTO_SWITCH_BACK}"
  [[ "${AUTO_SWITCH_BACK}" == "true" ]] && \
    log_info "  切替用シェル     : ${SWITCH_BACK_SCRIPT:-(未指定)}"

  collect_modules          # [6][7] とfmt 対象解決の前処理
  run_init                 # [1/8]
  run_fmt_check            # [2/8]
  run_validate             # [3/8]
  run_plan                 # [4/8]
  analyze_apply_risks      # [5/8]
  analyze_module_inputs    # [6/8]
  analyze_module_design    # [7/8]
  analyze_tags             # [8/8]
  write_csv_reports
  final_summary

  exit "${OVERALL_RC}"
}

main "$@"
