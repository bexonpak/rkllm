#!/bin/sh
# ============================================================================
#  板端运行脚本（RK3576）
#  放在模型目录下，与 demo_Linux_aarch64/ 同级：
#      ./
#      ├── demo_Linux_aarch64/{demo,imgenc,demo.jpg,lib/}
#      ├── qwen3-vl_vision_rk3576.rknn
#      ├── qwen3-vl-2b-instruct_w4a16_rk3576.rkllm
#      └── run_demo.sh
#
#  用法:
#      ./run_demo.sh [图片路径]
#      RKLLM_LOG_LEVEL=1 ./run_demo.sh            # 打印性能统计
#      MAX_CONTEXT=8192 ./run_demo.sh             # 临时改上下文
# ============================================================================
set -e

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="${APP_DIR}/demo_Linux_aarch64"

# 需要时用环境变量覆盖
RKNN_MODEL="${RKNN_MODEL:-${APP_DIR}/qwen3-vl_vision_rk3576.rknn}"
RKLLM_MODEL="${RKLLM_MODEL:-${APP_DIR}/qwen3-vl-2b-instruct_w4a16_rk3576.rkllm}"
IMAGE="${1:-${DEMO_DIR}/demo.jpg}"

MAX_NEW_TOKENS="${MAX_NEW_TOKENS:-2048}"
# RKLLM 1.3.1 上限 16384（且 32 对齐），32K 不可用
MAX_CONTEXT="${MAX_CONTEXT:-16384}"
# RK3576 只有 2 个 NPU 核心
RKNN_CORE_NUM="${RKNN_CORE_NUM:-2}"
PLATFORM="${PLATFORM:-rk3576}"

[ -x "${DEMO_DIR}/demo" ]      || { echo "ERROR: 找不到 ${DEMO_DIR}/demo"; exit 1; }
[ -f "${RKNN_MODEL}" ]         || { echo "ERROR: 找不到视觉模型 ${RKNN_MODEL}"; exit 1; }
[ -f "${RKLLM_MODEL}" ]        || { echo "ERROR: 找不到语言模型 ${RKLLM_MODEL}"; exit 1; }
[ -f "${IMAGE}" ]              || { echo "ERROR: 找不到图片 ${IMAGE}"; exit 1; }

echo "=============================================================="
echo " 视觉模型 : ${RKNN_MODEL}"
echo " 语言模型 : ${RKLLM_MODEL}"
echo " 图片     : ${IMAGE}"
echo " 生成上限 : ${MAX_NEW_TOKENS}   上下文: ${MAX_CONTEXT}   NPU核: ${RKNN_CORE_NUM}"
echo "=============================================================="
# 检查上下文是否够用（图片会产生 token，Qwen3-VL 448x448 约 196 个）
[ "${MAX_CONTEXT}" -gt 4096 ] || echo "[WARN] 上下文 ${MAX_CONTEXT} 偏小：图片 token + 生成长度容易被截断"

cd "${DEMO_DIR}"
export LD_LIBRARY_PATH="./lib:${LD_LIBRARY_PATH:-}"
export RKLLM_LOG_LEVEL="${RKLLM_LOG_LEVEL:-0}"

exec ./demo \
    "${IMAGE}" \
    "${RKNN_MODEL}" "" "" \
    "${RKLLM_MODEL}" \
    "${MAX_NEW_TOKENS}" "${MAX_CONTEXT}" "${RKNN_CORE_NUM}" "${PLATFORM}" \
    "<|vision_start|>" "<|vision_end|>" "<|image_pad|>"
