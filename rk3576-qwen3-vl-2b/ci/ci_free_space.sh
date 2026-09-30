#!/usr/bin/env bash
# ============================================================================
#  ci_free_space.sh —— GitHub Actions runner 的磁盘/内存预处理
#
#  为什么需要：
#    * GitHub 托管的 ubuntu runner 只有 **14GB SSD**，而本转换需要
#      模型 4.3GB + conda 环境约 10GB + ONNX/RKNN/RKLLM 产物约 3GB。
#      默认 14GB 必然中途 "No space left on device"。
#    * runner 内存只有 16GB（公有仓库）/ 8GB（私有仓库），而
#      export_vision.py 要以 float32 加载整个 2B 模型，峰值 12-16GB。
#      不加 swap 很容易被 OOM Kill（日志里没有任何 Python 报错，直接 killed）。
#
# 用法（在转换步骤之前调用）:
#    SWAP_GB=12 bash ci/ci_free_space.sh
# ============================================================================
set -euo pipefail

SWAP_GB="${SWAP_GB:-12}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"

echo "==== 1. 清理 runner 预装 SDK ===="
df -h / | tail -1

# 这些都是 GitHub runner 预装、本转换完全用不到的组件
# （.NET / Android SDK / Haskell / CodeQL / Boost / Swift / Azure CLI / pipx）
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
        sudo rm -rf "${d}" || true
    fi
done
sudo apt-get clean || true
sudo rm -rf /var/lib/apt/lists/* || true

echo "清理后:"
df -h / | tail -1

FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
echo "可用空间: ${FREE_GB} GB"
if (( FREE_GB < MIN_FREE_GB )); then
    echo "[WARN] 可用空间只有 ${FREE_GB}GB，低于 ${MIN_FREE_GB}GB，后面可能写满磁盘" >&2
fi

echo
echo "==== 2. 增加 swap ===="
free -h
# 注意：不能只看 swapon 有没有输出就跳过 —— runner 可能带一个很小的 swap。
# 这里按总量判断，不足才补。
CUR_SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
NEED_MB=$(( SWAP_GB * 1024 ))
echo "当前 swap: ${CUR_SWAP_MB} MB，目标: ${NEED_MB} MB"
if (( CUR_SWAP_MB >= NEED_MB )); then
    echo "swap 已足够，跳过创建"
else
    echo "创建 ${SWAP_GB}GB swapfile ..."
    if ! sudo fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null; then
        echo "  fallocate 不支持，改用 dd（慢一些）"
        sudo dd if=/dev/zero of=/swapfile bs=1M count=$(( SWAP_GB * 1024 )) status=none
    fi
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
fi
free -h
echo "swap 就绪，内存峰值有兜底了"
