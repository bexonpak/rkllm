#!/usr/bin/env bash
# ============================================================================
#  smoke_test.sh —— 在投入几十 GB 磁盘和几个小时之前，先花几分钟验证可行性
#
#  要回答的核心问题只有一个：
#      rkllm-toolkit 的 linux_x86_64 原生库，能不能在 Rosetta 翻译下正常加载？
#  如果答案是否，"本地 Rosetta 构建"这条路直接不成立，只能走 GitHub Actions。
#
#  测试内容：
#    A) 起一个 amd64 容器，把 rkllm-toolkit wheel 里的 .so 全部 dlopen 一遍
#       —— 静态初始化阶段的非法指令会在这里立刻暴露
#    B) 可选（FULL=1）：真装 torch 跑 matmul，量化 Rosetta 的实际性能开销
#
#  用法:
#    bash docker/smoke_test.sh
#    FULL=1 bash docker/smoke_test.sh      # 额外测 torch 性能（多花 1-3 分钟）
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
KIT_DIR="$(cd "${HERE}/.." && pwd -P)"
# shellcheck source=../config.env
source "${KIT_DIR}/config.env"

X86_PLATFORM="${X86_PLATFORM:-linux/amd64}"
FULL="${FULL:-0}"
SMOKE_IMAGE="${SMOKE_IMAGE:-ubuntu:22.04}"

c_info() { printf '\033[1;34m[INFO ]\033[0m %s\n' "$*"; }
c_ok()   { printf '\033[1;32m[ OK  ]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 || { c_err "没装 docker。macOS 上请先装 Docker Desktop 并启动"; exit 1; }
docker info >/dev/null 2>&1 || { c_err "docker 守护进程没起来（Docker Desktop 是不是没启动？）"; exit 1; }

shopt -s nullglob
WHEELS=("${RKLLM_TOOLKIT_PKGS}"/rkllm_toolkit-*-cp${RKLLM_PY_TAG}-cp${RKLLM_PY_TAG}-linux_x86_64.whl)
shopt -u nullglob
(( ${#WHEELS[@]} > 0 )) || { c_err "找不到 rkllm-toolkit wheel: ${RKLLM_TOOLKIT_PKGS}"; exit 1; }

echo "=============================================================="
echo " Rosetta 可行性测试"
echo "   平台     : ${X86_PLATFORM}"
echo "   基础镜像 : ${SMOKE_IMAGE}"
echo "   wheel    : $(basename "${WHEELS[0]}")"
echo "=============================================================="
echo

# --- 把检查脚本写成文件再挂进去，避免多层引号嵌套出问题 ---------------------
CHECK="$(mktemp /tmp/rkllm_so_check.XXXXXX.py)"
trap 'rm -f "${CHECK}"' EXIT
cat > "${CHECK}" <<'PY'
"""把所有 .so 依次 dlopen 一遍：Rosetta 不支持的指令会在加载时暴露。"""
import ctypes
import glob
import os
import sys
import zipfile

whls = sorted(glob.glob("/wheels/rkllm_toolkit-*.whl"))
if not whls:
    print("  [ERROR] /wheels 下没有 wheel")
    sys.exit(2)
whl = whls[0]
print("  解包:", os.path.basename(whl))

dest = "/tmp/whl"
with zipfile.ZipFile(whl) as z:
    z.extractall(dest)

sos = []
for root, _dirs, files in os.walk(dest):
    for f in files:
        if ".so" in f:
            sos.append(os.path.join(root, f))
print("  找到 .so 文件:", len(sos))
if not sos:
    print("  [WARN] wheel 里没有 .so，可能是纯 python 包")

bad = 0
for s in sorted(sos):
    rel = os.path.relpath(s, dest)
    try:
        ctypes.CDLL(s)
        print("    OK    ", rel)
    except OSError as e:
        print("    FAIL  ", rel, "->", e)
        bad += 1

print()
if bad:
    print("  结论: %d 个 .so 加载失败 -> Rosetta 跑不了 rkllm-toolkit" % bad)
    sys.exit(1)
print("  结论: 全部 .so 加载成功 -> Rosetta 至少能让 rkllm-toolkit 跑起来")
PY

c_info "A) 在 ${X86_PLATFORM} 容器里 dlopen rkllm-toolkit 的全部 .so"
c_warn "若报 Illegal instruction / cannot open shared object file，说明 Rosetta 跑不了这个工具链"

set +e
docker run --rm --platform "${X86_PLATFORM}" \
    -v "${RKLLM_TOOLKIT_PKGS}":/wheels:ro \
    -v "${CHECK}":/so_check.py:ro \
    "${SMOKE_IMAGE}" \
    bash -c '
        set -e
        echo "  容器内架构: $(uname -m)"
        if [ "$(uname -m)" != "x86_64" ]; then
            echo "  [ERROR] 没按 amd64 跑起来（Docker Desktop 的 amd64 支持没生效？）"
            exit 2
        fi
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq python3 libgomp1 libstdc++6 >/dev/null 2>&1
        python3 /so_check.py
    '
RC=$?
set -e

echo
if (( RC == 0 )); then
    c_ok "测试 A 通过：rkllm-toolkit 的原生库在 Rosetta 下可以加载"
else
    c_err "测试 A 失败（exit=${RC}）"
    c_err "本地 Rosetta 路线大概率走不通。建议改用 GitHub Actions（ci/README.md）——"
    c_err "它跑在真正的 x86_64 机器上，完全没有翻译开销。"
    exit "${RC}"
fi

# ---------------------------------------------------------------------------
if [[ "${FULL}" == "1" ]]; then
    echo
    c_info "B) 装 CPU 版 torch，量化 Rosetta 的性能开销（FULL=1）"
    c_warn "要下 ~200MB，约 1-3 分钟"
    docker run --rm --platform "${X86_PLATFORM}" "${SMOKE_IMAGE}" bash -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq python3 python3-pip >/dev/null 2>&1
        python3 -m pip install --quiet --upgrade pip >/dev/null 2>&1
        python3 -m pip install --quiet torch==2.6.0 --index-url https://download.pytorch.org/whl/cpu
        python3 - <<PY
import time, torch
print("  torch:", torch.__version__, "| 默认线程数:", torch.get_num_threads())
a = torch.randn(2048, 2048); b = torch.randn(2048, 2048)
a @ b
t = time.time()
for _ in range(20):
    a @ b
dt = time.time() - t
print("  20 x [2048x2048 matmul] = %.2f s" % dt)
print("  参考: 原生 x86_64 约 1-3s；远大于 10s 说明翻译开销很大")
PY
    '
    c_ok "测试 B 完成（把这个数字和真 x86_64 / GitHub Actions 对比）"
fi

echo
echo "=============================================================="
c_ok "Rosetta 可行性测试结束"
cat <<'EOF'

如果通过，下一步：
    bash docker/local_build.sh

两个必须先在 Docker Desktop 里改的设置：
  * Settings -> General -> 勾选
      "Use Rosetta for x86_64/amd64 emulation on Apple Silicon"
    （官方文档里这个选项默认是 Disabled）
  * Settings -> Resources -> Memory 调到 >= 16GB
    （float32 加载 2B 模型峰值 12-16GB，VM 内存不够会 OOM）

性价比提醒：GitHub Actions 路线通常更快（真 x86_64、免费不限分钟、不占本地磁盘），
详见 ci/README.md。
EOF
