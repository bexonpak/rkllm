#!/usr/bin/env bash
# ============================================================================
#  ci_free_space.sh —— GitHub Actions runner 的磁盘/内存预处理
#
#  为什么需要：
#    * GitHub 托管的 ubuntu runner 根分区虽然有上百 GB，但镜像里预装了
#      大量用不到的 SDK（.NET / Android / Swift / GHC / CodeQL …），
#      删掉它们能腾出 20GB 以上，给 conda 环境 + 模型 + 中间产物留余量。
#    * runner 内存约 16GB（公有仓库），而 export_vision.py 要以 float32
#      加载整个 2B 模型，峰值 12-16GB。镜像自带约 3GB swap，再补一点更稳。
#
#  ★ 本脚本是「尽力而为」的环境准备，**故意不使用 set -e**：
#    之前用 set -e，结果在给 swap 收尾时踩到 runner 自带 swap 文件
#    （/swapfile 正在使用，dd 覆盖它 -> 'Text file busy'）而返回非 0，
#    把整个 job 直接判失败。环境准备出点小岔子不该毁掉一次 1 小时的构建，
#    所以这里只告警、不退出非 0。
#
#  用法（在转换步骤之前调用）:
#    SWAP_GB=12 bash ci/ci_free_space.sh
# ============================================================================
set -uo pipefail

SWAP_GB="${SWAP_GB:-8}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
# 绝不使用 /swapfile：runner 镜像自带的 swap 就在那里且正在使用
SWAP_FILE_EXTRA="${SWAP_FILE_EXTRA:-/swap-extra}"

echo "==== 1. 清理 runner 预装 SDK ===="
df -h / | tail -1
echo "内存:"; command -v free >/dev/null 2>&1 && free -h || awk '/MemTotal|MemAvailable|SwapTotal|SwapFree/{printf "  %-14s %d MB\n", $1, int($2/1024)}' /proc/meminfo

# 这些都是 GitHub runner 预装、本转换完全用不到的组件
for d in \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /opt/ghc \
    /opt/hostedtoolcache/CodeQL \
    /usr/local/share/boost \
    /usr/share/swift \
    /opt/az \
    /opt/pipx ; do
    if [[ -e "${d}" ]]; then
        echo "  删除 ${d}"
        sudo rm -rf "${d}" || echo "  [WARN] 删除 ${d} 失败，忽略"
    fi
done
sudo apt-get clean >/dev/null 2>&1 || true
sudo rm -rf /var/lib/apt/lists/* >/dev/null 2>&1 || true

echo "清理后:"
df -h / | tail -1

FREE_GB="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
[[ -n "${FREE_GB}" ]] || FREE_GB=0
echo "可用空间: ${FREE_GB} GB"
if (( FREE_GB < MIN_FREE_GB )); then
    echo "[WARN] 可用空间只有 ${FREE_GB}GB，低于 ${MIN_FREE_GB}GB，后面可能写满磁盘"
fi

echo
echo "==== 2. 补充 swap ===="
CUR_MB="$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
[[ -n "${CUR_MB}" ]] || CUR_MB=0
NEED_MB=$(( SWAP_GB * 1024 ))
echo "当前 swap: ${CUR_MB} MB，目标总量: ${NEED_MB} MB"

if (( CUR_MB >= NEED_MB )); then
    echo "现有 swap 已够，跳过"
else
    # 复用上一次留下的额外 swapfile（如果还能启用）
    if [[ -e "${SWAP_FILE_EXTRA}" ]]; then
        if sudo swapon "${SWAP_FILE_EXTRA}" 2>/dev/null; then
            echo "复用已存在的 ${SWAP_FILE_EXTRA}"
        else
            echo "清理无法启用的遗留文件 ${SWAP_FILE_EXTRA}"
            sudo rm -f "${SWAP_FILE_EXTRA}" || true
        fi
    fi

    ADD_MB=$(( NEED_MB - CUR_MB ))
    (( ADD_MB > 0 )) || ADD_MB=1024
    ADD_GB=$(( (ADD_MB + 1023) / 1024 ))
    echo "追加 ${ADD_GB}GB swapfile: ${SWAP_FILE_EXTRA}"

    CREATED=0
    if sudo fallocate -l "${ADD_GB}G" "${SWAP_FILE_EXTRA}" 2>/dev/null; then
        CREATED=1
    else
        # fallocate 不支持（某些文件系统）时退回 dd
        sudo rm -f "${SWAP_FILE_EXTRA}" || true
        if sudo dd if=/dev/zero of="${SWAP_FILE_EXTRA}" bs=1M count=$(( ADD_GB * 1024 )) status=none 2>/dev/null; then
            CREATED=1
        fi
    fi

    if (( CREATED == 1 )) \
       && sudo chmod 600 "${SWAP_FILE_EXTRA}" 2>/dev/null \
       && sudo mkswap "${SWAP_FILE_EXTRA}" >/dev/null 2>&1 \
       && sudo swapon "${SWAP_FILE_EXTRA}" 2>/dev/null; then
        echo "swap 已追加成功"
    else
        echo "[WARN] 追加 swap 失败，忽略（swap 只是内存兜底，不是必须；"
        echo "[WARN]   真内存不够会表现为进程被 Killed，届时再降 MAX_CONTEXT）"
    fi
fi

echo
echo "最终资源状况:"
command -v free >/dev/null 2>&1 && free -h || awk '/MemTotal|MemAvailable|SwapTotal|SwapFree/{printf "  %-14s %d MB\n", $1, int($2/1024)}' /proc/meminfo
df -h / | tail -1

# 明确成功返回：本脚本是尽力而为的环境准备，不该让 job 失败
exit 0
