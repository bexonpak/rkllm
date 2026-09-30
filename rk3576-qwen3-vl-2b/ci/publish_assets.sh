#!/usr/bin/env bash
# ============================================================================
#  publish_assets.sh —— 把转换产物发布到 GitHub Release
#
#  为什么不用 actions/upload-artifact：
#    GitHub Free 的 artifact 存储配额只有 **500MB**（Pro 1GB / Team 2GB），
#    而本项目的 .rkllm 约 1.5GB、.rknn 约 0.6GB，必定超限失败。
#    Release 附件允许单文件最大 **2GiB**，且不占用 artifact 配额。
#
#  超过 SPLIT_THRESHOLD 的文件会自动分卷成  <file>.part-00/.part-01/...
#  合并方式：  cat <file>.part-* > <file>
#
#  用法:
#    TAG=qwen3-vl-2b-rk3576 bash ci/publish_assets.sh <tag> <file> [file...]
#  环境变量:
#    GH_TOKEN  必填（CI 里用 ${{ github.token }}）
#    GITHUB_REPOSITORY  形如 owner/repo（CI 自动提供）
# ============================================================================
set -euo pipefail

TAG="${1:-}"
shift || true
FILES=("$@")

die() { printf '[publish][ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[publish] %s\n' "$*"; }

[[ -n "${TAG}" ]] || die "用法: publish_assets.sh <tag> <file> [file...]"
[[ ${#FILES[@]} -gt 0 ]] || die "没有传入任何产物文件"
[[ -n "${GH_TOKEN:-}" ]] || die "缺少 GH_TOKEN 环境变量"

SPLIT_THRESHOLD_MB="${SPLIT_THRESHOLD_MB:-1900}"   # Release 单文件上限 2GiB，留点余量
SPLIT_SIZE="${SPLIT_SIZE:-1800M}"
REPO_FLAG=()
[[ -n "${GITHUB_REPOSITORY:-}" ]] && REPO_FLAG=(--repo "${GITHUB_REPOSITORY}")

# --- 过滤出真实存在的文件 ---------------------------------------------------
EXIST=()
for f in "${FILES[@]}"; do
    if [[ -f "${f}" ]]; then
        EXIST+=("${f}")
    else
        info "跳过不存在的文件: ${f}"
    fi
done
(( ${#EXIST[@]} > 0 )) || die "传入的文件都不存在"

# --- 分卷（超过 2GiB 会传不上去） -------------------------------------------
shopt -s nullglob
ASSETS=()
for f in "${EXIST[@]}"; do
    size_bytes=$(stat -c%s "${f}")
    size_mb=$(( size_bytes / 1024 / 1024 ))
    info "$(basename "${f}") = ${size_mb} MB (${size_bytes} bytes)"
    if (( size_mb > SPLIT_THRESHOLD_MB )); then
        info "  超过 ${SPLIT_THRESHOLD_MB}MB，分卷为 ${SPLIT_SIZE} 一片"
        rm -f "${f}".part-*
        split -b "${SPLIT_SIZE}" -d -a 2 "${f}" "${f}.part-"
        ASSETS+=("${f}".part-*)
        # 记下原文件哈希，方便合并后校验
        printf '%s  %s\n' "$(sha256sum "${f}" | awk '{print $1}')" "$(basename "${f}")" \
            > "${f}.parts.sha256.txt"
        ASSETS+=("${f}.parts.sha256.txt")
    else
        ASSETS+=("${f}")
        printf '%s  %s\n' "$(sha256sum "${f}" | awk '{print $1}')" "$(basename "${f}")" \
            > "${f}.sha256.txt"
        ASSETS+=("${f}.sha256.txt")
    fi
done
shopt -u nullglob

# --- 建 release（已存在就忽略） ---------------------------------------------
NOTES="$(mktemp)"
cat > "${NOTES}" <<EOF
Qwen3-VL-2B for RK3576 —— 转换产物

由 GitHub Actions 自动构建（workflow run #${GITHUB_RUN_NUMBER:-?}）。

**下载后请看每个文件旁边的 \`.sha256.txt\` 校验哈希。**

如果看到 \`.part-00 / .part-01 / ...\` 结尾的分卷，说明原文件超过 2GiB 的
Release 单文件上限，需要先合并再校验：

\`\`\`bash
cat qwen3-vl-2b-instruct_w8a8_rk3576.rkllm.part-* > qwen3-vl-2b-instruct_w8a8_rk3576.rkllm
sha256sum -c qwen3-vl-2b-instruct_w8a8_rk3576.rkllm.parts.sha256.txt
\`\`\`

**重要**：RKLLM 1.3.1 的上下文上限是 16384（且须 32 对齐），32K 无法制作。

用法见仓库内 \`rk3576-qwen3-vl-2b/README.md\` 与 \`rk3576-qwen3-vl-2b/ci/README.md\`。
EOF

info "创建/复用 release: ${TAG}"
if ! CREATE_ERR=$(gh release create "${TAG}" \
        --title "Qwen3-VL-2B RK3576 (${TAG})" \
        --notes-file "${NOTES}" \
        ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} 2>&1); then
    info "gh release create 返回（通常表示 release 已存在，直接复用）: $(echo "${CREATE_ERR}" | head -2 | tr '\n' ' ')"
fi

info "上传 ${#ASSETS[@]} 个附件 ..."
gh release upload "${TAG}" \
    ${ASSETS[@]+"${ASSETS[@]}"} \
    --clobber ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} \
    || die "上传附件失败（单文件是否超过 2GiB？GH_TOKEN 是否有 contents:write 权限？）"

info "完成。产物地址: https://github.com/${GITHUB_REPOSITORY:-owner/repo}/releases/tag/${TAG}"
