#!/usr/bin/env bash
# ============================================================================
#  prepare_tree.sh —— 在 CI 里准备好一棵「带本套件」的 rknn-llm 源码树
#
#  本套件的所有脚本都用  REPO_ROOT = <套件目录>/..  定位上游文件
#  （examples/multimodal_model_demo、rkllm-toolkit/packages/*.whl），
#  所以套件必须位于 rknn-llm 源码树的根目录下才能工作。
#
#  支持两种用户仓库形态：
#    A) 用户直接 fork 了完整 rknn-llm，套件也在其中
#       -> 直接用当前仓库当源码树
#    B) 用户仓库里只有本套件（推荐，仓库很小）
#       -> 浅克隆 airockchip/rknn-llm 到临时目录，再把套件拷进去
#
#  用法:
#    TREE=$(bash ci/prepare_tree.sh <src_repo_dir> <upstream_clone_dir> [ref])
#
#  stdout 只输出一行：可用的源码树路径（便于 $( ) 捕获）
#  所有进度信息走 stderr
# ============================================================================
set -euo pipefail

log() { printf '[prepare_tree] %s\n' "$*" >&2; }
die() { printf '[prepare_tree][ERROR] %s\n' "$*" >&2; exit 1; }

SRC_REPO="${1:-}"
UPSTREAM_DIR="${2:-}"
UPSTREAM_REF="${3:-release-v1.3.1}"
KIT_NAME="rk3576-qwen3-vl-2b"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/airockchip/rknn-llm.git}"

[[ -n "${SRC_REPO}" ]]    || die "缺参数: <src_repo_dir>"
[[ -d "${SRC_REPO}" ]]    || die "目录不存在: ${SRC_REPO}"
[[ -n "${UPSTREAM_DIR}" ]] || die "缺参数: <upstream_clone_dir>"

SRC_REPO="$(cd "${SRC_REPO}" && pwd)"
UPSTREAM_DIR_ABS="$(cd "$(dirname "${UPSTREAM_DIR}")" 2>/dev/null && pwd || echo "")/$(basename "${UPSTREAM_DIR}")"
[[ "${UPSTREAM_DIR_ABS}" != "${SRC_REPO}" ]] || die "upstream 克隆目录不能等于用户仓库目录"

KIT_SRC="${SRC_REPO}/${KIT_NAME}"
[[ -f "${KIT_SRC}/config.env" ]] || die "在 ${SRC_REPO} 下找不到 ${KIT_NAME}/config.env"

# --- 形态 A：当前仓库本身就是完整的 rknn-llm --------------------------------
if [[ -f "${SRC_REPO}/examples/multimodal_model_demo/export/export_vision.py" \
   && -d "${SRC_REPO}/rkllm-toolkit/packages" ]]; then
    log "形态 A：当前仓库已是完整 rknn-llm 源码树，直接使用"
    echo "${SRC_REPO}"
    exit 0
fi

# --- 形态 B：浅克隆上游，再把套件拷进去 -------------------------------------
log "形态 B：浅克隆 ${UPSTREAM_URL} (ref=${UPSTREAM_REF}) -> ${UPSTREAM_DIR}"
rm -rf "${UPSTREAM_DIR}"
mkdir -p "$(dirname "${UPSTREAM_DIR}")"
git clone --depth 1 --branch "${UPSTREAM_REF}" "${UPSTREAM_URL}" "${UPSTREAM_DIR}" >&2 \
    || die "克隆上游失败（ref=${UPSTREAM_REF} 是否存在？网络是否可达 github.com？）"

[[ -f "${UPSTREAM_DIR}/examples/multimodal_model_demo/export/export_vision.py" ]] \
    || die "克隆结果里没有 examples/multimodal_model_demo，ref 可能不对"
[[ -d "${UPSTREAM_DIR}/rkllm-toolkit/packages" ]] \
    || die "克隆结果里没有 rkllm-toolkit/packages（rkllm-toolkit 的 wheel 就在这里）"

log "拷贝套件 -> ${UPSTREAM_DIR}/${KIT_NAME}"
rm -rf "${UPSTREAM_DIR:?}/${KIT_NAME}"
cp -a "${KIT_SRC}" "${UPSTREAM_DIR}/"

log "源码树就绪: ${UPSTREAM_DIR}"
echo "${UPSTREAM_DIR}"
