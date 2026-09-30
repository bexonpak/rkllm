#!/usr/bin/env bash
# ============================================================================
#  run_all.sh  —— 一条命令跑完整条链路
#
#    bash scripts/run_all.sh              # 00..05
#    bash scripts/run_all.sh --skip-env   # 跳过已装好的环境（01）
#    bash scripts/run_all.sh --push       # 额外执行 06 推送到板子
# ============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

SKIP_ENV=0
DO_PUSH=0
for a in "$@"; do
    case "$a" in
        --skip-env) SKIP_ENV=1 ;;
        --push)     DO_PUSH=1 ;;
        -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
        *) die "未知参数: $a（可用: --skip-env --push）" ;;
    esac
done

# aarch64 宿主机跑不了完整链路（rkllm-toolkit 只有 x86_64 wheel），
# 与其跑到 01 才失败，不如现在就讲清楚该走哪条路。
HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" == "aarch64" || "${HOST_ARCH}" == "arm64" ]]; then
    c_err "当前是 aarch64 宿主机，完整链路（含 RKLLM 构建）跑不了。"
    c_info "原因：rkllm-toolkit 只发布 linux_x86_64 的 wheel。"
    c_info "可选方案："
    c_info "  A) bash docker/local_build.sh    # 自动做 arm64 原生 + Rosetta x86_64 混合构建"
    c_info "  B) 用 GitHub Actions             # 见 ci/README.md（真 x86_64，最省事）"
    c_info "  C) 只跑能原生跑的部分："
    c_info "       bash scripts/01_env_setup.sh --only rknn"
    c_info "       bash scripts/02_download_model.sh"
    c_info "       bash scripts/03_export_vision.sh"
    c_info "       bash scripts/04_export_llm.sh --phase calib"
    c_info "       bash scripts/05_build_demo.sh"
    c_info "     然后把 RKLLM 构建那一步拿到 x86_64 机器上跑 --phase build"
    c_info "确要继续（会在 01 失败）请设置 FORCE_FULL_PIPELINE=1"
    [[ "${FORCE_FULL_PIPELINE:-0}" == "1" ]] || exit 1
fi

STEP_DIR="${KIT_DIR}/scripts"
START_TS="$(date +%s)"

run_step() {
    local label="$1"; shift
    banner "${label}"
    local t0 t1
    t0="$(date +%s)"
    bash "$@" || die "步骤失败: $*"
    t1="$(date +%s)"
    c_ok "${label} 完成，用时 $(( t1 - t0 )) 秒"
}

run_step "00 环境自检"        "${STEP_DIR}/00_check_env.sh"
if (( SKIP_ENV == 0 )); then
    run_step "01 安装工具链环境" "${STEP_DIR}/01_env_setup.sh"
else
    c_info "--skip-env: 跳过 01"
fi
run_step "02 下载模型"        "${STEP_DIR}/02_download_model.sh"
run_step "03 视觉编码器"      "${STEP_DIR}/03_export_vision.sh"
run_step "04 LLM RKLLM"       "${STEP_DIR}/04_export_llm.sh"
run_step "05 编译板端 demo"   "${STEP_DIR}/05_build_demo.sh"
if (( DO_PUSH == 1 )); then
    run_step "06 推送到开发板" "${STEP_DIR}/06_push_to_board.sh"
fi

END_TS="$(date +%s)"
banner "全部完成，总用时 $(( (END_TS - START_TS) / 60 )) 分 $(( (END_TS - START_TS) % 60 )) 秒"
echo "产物目录 ${OUTPUT_DIR}:"
ls -lh "${OUTPUT_DIR}" 2>/dev/null | sed 's/^/    /'
if (( DO_PUSH == 0 )); then
    echo
    c_info "下一步: bash scripts/06_push_to_board.sh   （或重跑加 --push）"
fi
