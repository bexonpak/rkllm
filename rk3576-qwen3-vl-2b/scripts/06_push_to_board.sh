#!/usr/bin/env bash
# ============================================================================
#  06  把产物推到 RK3576 开发板
#
#  板端目录结构:
#    ${BOARD_APP_DIR}/
#      ├── demo_Linux_aarch64/{demo,imgenc,audioenc,demo.jpg,lib/}
#      ├── qwen3-vl_vision_${TARGET_PLATFORM}.rknn
#      ├── ${MODEL_TAG}_${QUANTIZED_DTYPE}_${TARGET_PLATFORM}.rkllm
#      └── run_demo.sh
# ============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

banner "06 推送到开发板: ${BOARD_APP_DIR}"

need_cmd adb "sudo apt-get install -y android-tools-adb"

MODEL_TAG="$(basename "${MODEL_DIR}" | tr 'A-Z' 'a-z')"
RKNN_FILE="${OUTPUT_DIR}/qwen3-vl_vision_${TARGET_PLATFORM}.rknn"
RKLLM_FILE="${OUTPUT_DIR}/${MODEL_TAG}_${QUANTIZED_DTYPE}_${TARGET_PLATFORM}.rkllm"
DEMO_DIR="${OUTPUT_DIR}/demo_Linux_aarch64"

for f in "${RKNN_FILE}" "${RKLLM_FILE}"; do
    [[ -f "${f}" ]] || die "缺少产物 ${f}，请先跑 03/04 脚本"
done
[[ -x "${DEMO_DIR}/demo" ]] || die "缺少 ${DEMO_DIR}/demo，请先跑 05_build_demo.sh"

# --- 设备 ---
c_info "adb devices:"
adb devices | sed 's/^/    /'
if ! adb devices | awk 'NR>1 && $2=="device"' | grep -q .; then
    die "没有处于 device 状态的 adb 设备。请确认:
    - 开发板已上电且 USB/OTG 线接到 PC
    - 板端已开启 adbd（RK3576 官方 Debian 镜像默认开启）
    - 首次连接需要在板端确认 RSA 指纹，或 adb kill-server && adb start-server"
fi
c_ok "设备已连接"

# --- 推送 ---
adb shell "mkdir -p '${BOARD_APP_DIR}'" || die "无法在板端创建目录 ${BOARD_APP_DIR}"

c_info "推送 demo 目录 ..."
adb push "${DEMO_DIR}" "${BOARD_APP_DIR}/" || die "push demo 失败"

c_info "推送视觉模型 $(basename "${RKNN_FILE}") ..."
adb push "${RKNN_FILE}" "${BOARD_APP_DIR}/" || die "push rknn 失败"

c_info "推送语言模型 $(basename "${RKLLM_FILE}") ..."
adb push "${RKLLM_FILE}" "${BOARD_APP_DIR}/" || die "push rkllm 失败"

c_info "推送板端运行脚本 run_demo.sh ..."
adb push "${KIT_DIR}/board/run_demo.sh" "${BOARD_APP_DIR}/" || die "push run_demo.sh 失败"
adb shell "chmod +x '${BOARD_APP_DIR}/run_demo.sh' '${BOARD_APP_DIR}/demo_Linux_aarch64/demo' 2>/dev/null || true"

c_ok "推送完成"

banner "板端运行方式"
cat <<EOF
方式 A（推荐，用附带的脚本）：

  adb shell
  cd ${BOARD_APP_DIR}
  ./run_demo.sh                       # 用 demo_Linux_aarch64/demo.jpg
  ./run_demo.sh /path/to/your.jpg     # 换成自己的图
  RKLLM_LOG_LEVEL=1 ./run_demo.sh     # 打开性能日志（TTFT/tokens/s/内存）

方式 B（手敲，参数顺序见下）：

  adb shell
  cd ${BOARD_APP_DIR}/demo_Linux_aarch64
  export LD_LIBRARY_PATH=./lib:\$LD_LIBRARY_PATH
  ./demo demo.jpg ../$(basename "${RKNN_FILE}") "" "" ../$(basename "${RKLLM_FILE}") \\
      ${MAX_NEW_TOKENS} ${MAX_CONTEXT} ${RKNN_CORE_NUM} ${TARGET_PLATFORM} \\
      "<|vision_start|>" "<|vision_end|>" "<|image_pad|>"

参数顺序（v1.3.1 起加入了音频参数，必须占位）：
  image_path img_encoder_model_path audio_path aud_encoder_model_path \\
  llm_model_path max_new_tokens max_context_len rknn_core_num platform \\
  [img_start] [img_end] [img_content] [audio_start] [audio_end] [audio_content]

注意：
  * max_context_len(${MAX_CONTEXT}) 必须 > 文本token数 + 图像token数 + max_new_tokens
  * RK3576 的 rknn_core_num 只能是 1 或 2
  * 纯文本问答：把 image_path 和 img_encoder_model_path 都传空串 ""
EOF
