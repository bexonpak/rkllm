#!/usr/bin/env bash
# ============================================================================
#  install_miniforge.sh —— 在 runner 上装一个确定的 miniforge3
#
#  为什么必须显式装：
#    GitHub 的 ubuntu 镜像里虽然预装了 Miniconda，但路径是 /usr/share/miniconda，
#    并不是本套件默认找的 $HOME/miniforge3。与其依赖镜像的具体布局，
#    不如自己装一个固定位置的 miniforge3，保证 CONDA_HOME 推导稳定、可复现。
#
#  用法:
#    bash ci/install_miniforge.sh
#  环境变量:
#    CONDA_HOME   安装位置，默认 $HOME/miniforge3
#    MINIFORGE_URL 自定义下载地址（默认先试国内镜像，失败回退官方 GitHub）
# ============================================================================
set -euo pipefail

CONDA_HOME="${CONDA_HOME:-$HOME/miniforge3}"
INSTALLER="/tmp/miniforge-installer.sh"

if [[ -f "${CONDA_HOME}/etc/profile.d/conda.sh" ]]; then
    echo "[miniforge] 已存在: ${CONDA_HOME}"
    "${CONDA_HOME}/bin/conda" --version
    exit 0
fi

# 按架构选安装包：x86_64 容器（Rosetta）用 x86_64 版，
# arm64 原生容器必须用 aarch64 版，装错了 miniforge 直接跑不起来。
case "$(uname -m)" in
    x86_64)          MF_ARCH="x86_64"  ;;
    aarch64|arm64)   MF_ARCH="aarch64" ;;
    *) echo "[miniforge][ERROR] 不支持的架构: $(uname -m)" >&2; exit 1 ;;
esac
echo "[miniforge] 架构: $(uname -m) -> 安装包 Miniforge3-Linux-${MF_ARCH}.sh"

# 依次尝试：国内镜像 -> 官方 GitHub release
URLS=()
if [[ -n "${MINIFORGE_URL:-}" ]]; then
    URLS+=("${MINIFORGE_URL}")
fi
URLS+=(
    "https://mirrors.bfsu.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-${MF_ARCH}.sh"
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${MF_ARCH}.sh"
)

ok=0
for u in "${URLS[@]}"; do
    echo "[miniforge] 尝试下载: ${u}"
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=60 -O "${INSTALLER}" "${u}" && ok=1 && break
    fi
    curl -fsSL --max-time 300 -o "${INSTALLER}" "${u}" && ok=1 && break
    echo "[miniforge]   失败，换下一个源"
done
(( ok == 1 )) || { echo "[miniforge][ERROR] 所有下载源都失败" >&2; exit 1; }

echo "[miniforge] 安装到 ${CONDA_HOME}"
# -b 批处理模式；-p 前缀。装完不修改 shell rc（我们每次都显式 source conda.sh）
bash "${INSTALLER}" -b -p "${CONDA_HOME}"
rm -f "${INSTALLER}"

"${CONDA_HOME}/bin/conda" --version
echo "[miniforge] 完成: ${CONDA_HOME}"
