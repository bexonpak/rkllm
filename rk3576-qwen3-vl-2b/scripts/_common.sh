#!/usr/bin/env bash
# ============================================================================
#  公共函数：日志、配置加载、conda 激活、前置检查
#  用法（在其它脚本里）：  source "$(dirname "$0")/_common.sh"
# ============================================================================
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_DIR
# shellcheck source=../config.env
source "${KIT_DIR}/config.env"

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
c_info() { printf '\033[1;34m[INFO ]\033[0m %s\n' "$*"; }
c_ok()   { printf '\033[1;32m[ OK  ]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

banner() {
    printf '\n\033[1;36m==============================================================\n'
    printf '  %s\n' "$*"
    printf '==============================================================\033[0m\n'
}

# ---------------------------------------------------------------------------
# 前置检查：必须是 Linux x86_64
#   rkllm-toolkit 只提供 linux_x86_64 的 wheel；rknn-toolkit2 只有 Linux。
#   macOS / arm64 主机无法运行，所以这里默认硬失败。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 前置检查
#
#   require_linux          —— 只要 Linux 就行（x86_64 或 aarch64）
#       02 下载模型 / 03 视觉导出 / 05 编译 demo 在 arm64 上都能跑：
#       rknn-toolkit2 有 aarch64 的 manylinux wheel，板子本身就是 aarch64，
#       所以 arm64 宿主机（含 Docker Desktop 的 arm64 容器）原生就能干活。
#
#   require_linux_x86_64   —— 真的只能用 x86_64
#       只有 rkllm-toolkit：仓库/官方只发布 linux_x86_64 的 wheel。
#       所以 01（装 rkllm 环境）和 04 的 build 阶段必须卡这一条。
# ---------------------------------------------------------------------------
_is_linux() {
    [[ "$(uname -s 2>/dev/null || echo unknown)" == "Linux" ]]
}

require_linux() {
    local os arch
    os="$(uname -s 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"
    if [[ "${os}" == "Linux" ]]; then
        c_ok "主机是 Linux/${arch}"
        return 0
    fi
    c_warn "当前主机: ${os}/${arch}，不是 Linux。"
    c_warn "本套件依赖 Linux 工具链（rkllm-toolkit 的 wheel 与 rknn-toolkit2 都只有 Linux 版）。"
    c_warn "macOS 上请用 GitHub Actions（ci/README.md）或 Docker（docker/README.md）。"
    if [[ "${ALLOW_UNSUPPORTED_HOST}" == "1" ]]; then
        c_warn "ALLOW_UNSUPPORTED_HOST=1，继续执行（预计会失败）。"
        return 0
    fi
    die "请在 Linux（x86_64 或 aarch64）上运行；确要继续请设置 ALLOW_UNSUPPORTED_HOST=1"
}

require_linux_x86_64() {
    local os arch
    os="$(uname -s 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"
    if [[ "${os}" == "Linux" && "${arch}" == "x86_64" ]]; then
        c_ok "主机是 Linux x86_64"
        return 0
    fi
    c_warn "当前主机: ${os}/${arch}，不是 Linux/x86_64。"
    c_warn "rkllm-toolkit 只发布 linux_x86_64 的 wheel，这一步必须是 x86_64。"
    if [[ "${ALLOW_UNSUPPORTED_HOST}" == "1" ]]; then
        c_warn "ALLOW_UNSUPPORTED_HOST=1，继续执行（预计会失败）。"
        return 0
    fi
    die "请在 Linux x86_64 上运行这一步（或用 Docker Desktop 的 Rosetta amd64 容器）；确要继续请设置 ALLOW_UNSUPPORTED_HOST=1"
}

# ---------------------------------------------------------------------------
# conda
# ---------------------------------------------------------------------------
_find_conda_sh() {
    local candidates=(
        "${CONDA_HOME}/etc/profile.d/conda.sh"
        "${HOME}/miniforge3/etc/profile.d/conda.sh"
        "${HOME}/mambaforge/etc/profile.d/conda.sh"
        "${HOME}/miniconda3/etc/profile.d/conda.sh"
        "${HOME}/anaconda3/etc/profile.d/conda.sh"
        "/opt/conda/etc/profile.d/conda.sh"
        # GitHub Actions 的 ubuntu 镜像预装 Miniconda 在 /usr/share/miniconda
        "${CONDA:-/nonexistent}/etc/profile.d/conda.sh"
        "/usr/share/miniconda/etc/profile.d/conda.sh"
        "/usr/local/miniconda3/etc/profile.d/conda.sh"
    )
    local p
    for p in "${candidates[@]}"; do
        [[ -f "${p}" ]] && { echo "${p}"; return 0; }
    done
    return 1
}

conda_init() {
    # 幂等：已经初始化过就直接复用，避免重复 source
    if [[ -n "${CONDA_SH:-}" && -f "${CONDA_SH}" ]]; then
        # shellcheck disable=SC1090
        source "${CONDA_SH}"
        return 0
    fi

    local sh
    if ! sh="$(_find_conda_sh)"; then
        die "找不到 conda.sh。请安装 miniforge3，或设置 CONDA_HOME=/path/to/miniforge3"
    fi

    # 从 <conda_root>/etc/profile.d/conda.sh 反推 conda 根目录。
    # 注意必须剥掉 "etc/profile.d/conda.sh" 三层：
    #   dirname x1 -> profile.d    dirname x2 -> etc    dirname x3 才是 conda 根
    # 之前只 dirname 了两次，得到的是 <root>/etc，
    # 于是 activate_env 里再拼 "${CONDA_HOME}/etc/profile.d/conda.sh" 就成了
    # <root>/etc/etc/... —— source 不存在的文件，set -e 下直接终止脚本。
    case "${sh}" in
        */etc/profile.d/conda.sh) CONDA_HOME="${sh%/etc/profile.d/conda.sh}" ;;
        *)                        CONDA_HOME="$(dirname "$(dirname "$(dirname "${sh}")")")" ;;
    esac
    CONDA_SH="${sh}"
    export CONDA_HOME CONDA_SH

    # shellcheck disable=SC1090
    source "${CONDA_SH}"
}

# activate_env <env-name>
activate_env() {
    conda_init
    local env_name="$1"
    if ! env_exists "${env_name}"; then
        die "conda 环境 '${env_name}' 不存在，请先运行 bash scripts/01_env_setup.sh"
    fi
    # conda_init 已经把 conda.sh source 过了，这里不用再拼路径 source 一遍
    conda activate "${env_name}"
    c_info "已激活 conda 环境: ${env_name} ($(command -v python))"
    python -c 'import sys; print("       python", sys.version.split()[0])'
}

# env_exists <env-name> —— 只判断存在与否，不存在就返回 1，不退出
env_exists() {
    conda_init
    conda env list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1 （$2）"
}

ensure_dir() { mkdir -p "$1"; }

human_size() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

check_ram_gb() {
    local kb
    kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    echo $(( kb / 1024 / 1024 ))
}
