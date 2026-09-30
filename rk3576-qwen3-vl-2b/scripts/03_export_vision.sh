#!/usr/bin/env bash
# ============================================================================
#  03  视觉编码器: HF -> ONNX -> RKNN (${TARGET_PLATFORM})
#
#  产物:
#    ${MM_DIR}/onnx/qwen3-vl_vision.onnx
#    ${MM_DIR}/rknn/qwen3-vl_vision_${TARGET_PLATFORM}.rknn
#    ${OUTPUT_DIR}/qwen3-vl_vision_${TARGET_PLATFORM}.rknn   (汇总)
# ============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

banner "03 导出视觉编码器 ONNX + RKNN (${IMG_HEIGHT}x${IMG_WIDTH}, ${TARGET_PLATFORM})"
require_linux

[[ -f "${MODEL_DIR}/config.json" ]] || die "模型不存在: ${MODEL_DIR}，先跑 02_download_model.sh"

# Qwen3-VL 的 patch_size=16, merge_size=2：
#   --height/--width 必须是 32 的倍数，否则 grid_h//merge_size 会取整丢信息
if (( IMG_HEIGHT % 32 != 0 || IMG_WIDTH % 32 != 0 )); then
    die "IMG_HEIGHT/IMG_WIDTH 必须是 32 的倍数（当前 ${IMG_HEIGHT}x${IMG_WIDTH}）。推荐 448x448"
fi
c_info "视觉输入 ${IMG_HEIGHT}x${IMG_WIDTH} -> grid ${IMG_HEIGHT}/16 x ${IMG_WIDTH}/16 = $(( IMG_HEIGHT/16 ))x$(( IMG_WIDTH/16 )) patches"

activate_env "${RKNN_ENV}"
cd "${MM_DIR}"

# --- 1. 导出 ONNX ---------------------------------------------------------
banner "3.1  export_vision.py  (HF -> ONNX)"
c_warn "这一步以 float32 加载整个 Qwen3-VL-2B（约 9GB 权重 + 图开销），峰值内存可能 12-16GB"
python export/export_vision.py \
    --path="${MODEL_DIR}" \
    --model_name=qwen3-vl \
    --height="${IMG_HEIGHT}" \
    --width="${IMG_WIDTH}" \
    --batch_size="${IMG_BATCH}" \
    || die "ONNX 导出失败。常见原因：transformers 版本不对（需 ${RKNN_TRANSFORMERS}）、内存不足（OOM）"

ONNX_PATH="${MM_DIR}/onnx/qwen3-vl_vision.onnx"
[[ -f "${ONNX_PATH}" ]] || die "没有生成 ${ONNX_PATH}"
c_ok "ONNX: ${ONNX_PATH} ($(human_size "${ONNX_PATH}"))"

# --- 2. 归一化参数防呆 ------------------------------------------------------
# export_vision_rknn.py 用「文件名里有没有 qwen2」来选择 mean/std：
#   含 qwen2 -> CLIP 均值方差；否则 -> 0.5/0.5
# Qwen3-VL 的 preprocessor_config.json 是 image_mean=[0.5,0.5,0.5], image_std=[0.5,0.5,0.5]，
# 所以 ONNX 文件名里绝不能出现 qwen2，否则会静默用错归一化、精度崩掉。
if [[ "$(basename "${ONNX_PATH}" | tr 'A-Z' 'a-z')" == *qwen2* ]]; then
    die "ONNX 文件名包含 'qwen2'，会被误判为 Qwen2-VL 而套用 CLIP 归一化。请改名为 qwen3-vl_vision.onnx"
fi
c_ok "归一化参数将使用 mean=std=0.5（与 Qwen3-VL preprocessor_config.json 一致）"

# --- 3. ONNX -> RKNN ------------------------------------------------------
banner "3.2  export_vision_rknn.py  (ONNX -> RKNN)"
python export/export_vision_rknn.py \
    --path="${ONNX_PATH}" \
    --model_name=qwen3-vl \
    --target-platform="${TARGET_PLATFORM}" \
    --height="${IMG_HEIGHT}" \
    --width="${IMG_WIDTH}" \
    --batch_size="${IMG_BATCH}" \
    || die "RKNN 转换失败。常见原因：rknn-toolkit2 版本 < 2.3.2、ONNX 算子不支持"

RKNN_PATH="${MM_DIR}/rknn/qwen3-vl_vision_${TARGET_PLATFORM}.rknn"
[[ -f "${RKNN_PATH}" ]] || die "没有生成 ${RKNN_PATH}"
c_ok "RKNN: ${RKNN_PATH} ($(human_size "${RKNN_PATH}"))"

# --- 4. 汇总到 output ------------------------------------------------------
ensure_dir "${OUTPUT_DIR}"
cp -f "${RKNN_PATH}" "${OUTPUT_DIR}/"
{
    echo "artifact : $(basename "${RKNN_PATH}")"
    echo "bytes    : $(stat -c%s "${RKNN_PATH}")"
    echo "sha256   : $(sha256_of "${RKNN_PATH}")"
    echo "input    : pixel[${IMG_BATCH},3,${IMG_HEIGHT},${IMG_WIDTH}] + grid_thw[1,3]"
    echo "platform : ${TARGET_PLATFORM}"
    echo "mean/std : 0.5 / 0.5"
} > "${OUTPUT_DIR}/qwen3-vl_vision_${TARGET_PLATFORM}.rknn.info"
c_ok "已复制到 ${OUTPUT_DIR}/"

conda deactivate
echo
c_info "下一步:  bash scripts/04_export_llm.sh"
