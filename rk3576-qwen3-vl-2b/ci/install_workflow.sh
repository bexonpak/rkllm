#!/usr/bin/env bash
# ============================================================================
#  install_workflow.sh —— 把 GitHub Actions workflow 安装到仓库的
#                         .github/workflows/ 目录
#
#  GitHub 只认**仓库根目录**下的 .github/workflows/*.yml，
#  而本套件的 workflow 模板放在 ci/ 里，所以用这个脚本放到位。
#
#  用法（在你的仓库根目录执行）:
#     bash rk3576-qwen3-vl-2b/ci/install_workflow.sh
#  或显式指定仓库根目录:
#     bash rk3576-qwen3-vl-2b/ci/install_workflow.sh /path/to/your-repo
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
KIT_DIR="$(cd "${HERE}/.." && pwd -P)"
KIT_NAME="$(basename "${KIT_DIR}")"
SRC="${HERE}/build-qwen3-vl-2b-rk3576.yml"
WF_NAME="build-qwen3-vl-2b-rk3576.yml"

[[ -f "${SRC}" ]] || { echo "[ERROR] 找不到 workflow 模板: ${SRC}" >&2; exit 1; }

# --- 确定仓库根目录 ---------------------------------------------------------
# 优先用参数；否则用 git 的真实顶层目录（比 "套件的上一级" 可靠）
if [[ $# -ge 1 ]]; then
    REPO_ROOT="$1"
    [[ -d "${REPO_ROOT}" ]] || { echo "[ERROR] 目录不存在: ${REPO_ROOT}" >&2; exit 1; }
    REPO_ROOT="$(cd "${REPO_ROOT}" && pwd -P)"
else
    if REPO_ROOT="$(git -C "${KIT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
        REPO_ROOT="$(cd "${REPO_ROOT}" && pwd -P)"
    else
        REPO_ROOT="$(cd "${KIT_DIR}/.." && pwd -P)"
        echo "[WARN] 没检测到 git 仓库，回退用套件的上一级目录作为仓库根。" >&2
    fi
fi

echo "套件目录   : ${KIT_DIR}"
echo "仓库根目录 : ${REPO_ROOT}"

# --- 关键前提：套件必须在仓库根目录下 ---------------------------------------
# 否则 workflow 里的 ${KIT}/ci/prepare_tree.sh 找不到，
# 而且 prepare_tree.sh 也找不到 <仓库根>/<套件名>/config.env
# pwd -P 很关键：macOS 上 /tmp 是 /private/tmp 的软链，
# git rev-parse --show-toplevel 返回物理路径，不统一就会误报
KIT_PARENT="$(cd "$(dirname "${KIT_DIR}")" && pwd -P)"
if [[ "${KIT_PARENT}" != "${REPO_ROOT}" ]]; then
    REL_KIT="${KIT_DIR#"${REPO_ROOT}"/}"
    echo >&2
    echo "[WARN] 套件不在仓库根目录下！" >&2
    echo "[WARN]   套件在      : ${KIT_DIR}" >&2
    echo "[WARN]   仓库根目录  : ${REPO_ROOT}" >&2
    echo "[WARN] GitHub 只会执行仓库根的 .github/workflows/，" >&2
    echo "[WARN] 而 workflow 假设仓库根下就有一个 ${KIT_NAME}/ 目录。" >&2
    echo "[WARN] 请把 ${KIT_NAME}/ 整个移到仓库根目录再执行本脚本，" >&2
    echo "[WARN] 例如:  git mv '${REL_KIT}' ." >&2
    echo "[WARN] 仍然会写入 ${REPO_ROOT}/.github/workflows/ ，但构建会失败。" >&2
    echo >&2
fi

# --- 安装 ------------------------------------------------------------------
DEST_DIR="${REPO_ROOT}/.github/workflows"
mkdir -p "${DEST_DIR}"
cp -f "${SRC}" "${DEST_DIR}/${WF_NAME}"

echo
echo "已安装: ${DEST_DIR}/${WF_NAME}"
echo
cat <<EOF
下一步：
  1. git add .github/workflows/${WF_NAME}
     git commit -m "ci: add RK3576 build workflow"
     git push
  2. 打开仓库的 Actions 页面 -> 左侧选 "Build Qwen3-VL-2B (RK3576)" -> Run workflow
  3. 需要让 workflow 有发布 Release 的权限：
     Settings -> Actions -> General -> Workflow permissions -> 选 "Read and write permissions"
     （workflow 里已经写了 permissions: contents: write，但没法放宽仓库级设置）

更详细的说明见 ${KIT_NAME}/ci/README.md
EOF
