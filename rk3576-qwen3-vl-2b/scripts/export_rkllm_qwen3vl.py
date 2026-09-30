#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Qwen3-VL-2B  ->  RKLLM 转换脚本（针对 RK3576 定制）

与上游 examples/multimodal_model_demo/export/export_rkllm.py 的差异（都是必要的）：

  1. 显式传 max_context。
     上游脚本完全没传这个参数，于是用工具链的默认上下文（远小于 16K）。
     RKLLM 1.3.1 官方文档：build() 的 max_context「最大支持到 16384 且必须按 32 对齐」。
     英文版：The maximum context length, supported up to 16,384 and must be aligned to 32.
     ==> 你想要的 32K(32768) 在这个版本上做不到，脚本会直接拒绝 >16384 的输入。

  2. dataset 默认指向 data/llm_inputs.json。
     上游 data/make_input_embeds_for_quantize.py 写出的文件叫 data/llm_inputs.json，
     而上游 export_rkllm.py 读的是 data/inputs.json —— 两头文件名不一致，
     照 README 直接跑会报 "dataset not found"。这里统一到 llm_inputs.json。

  3. 参数化 + 前置校验（量化类型/核心数是否符合 RK3576 的限制）。

用法（务必在 examples/multimodal_model_demo 目录下执行，因为 dataset 路径是相对的）：
  python export_rkllm_qwen3vl.py \\
      --path /path/to/Qwen3-VL-2B-Instruct \\
      --target-platform rk3576 --num_npu_core 2 \\
      --quantized_dtype w4a16 --max_context 16384 \\
      --dataset data/llm_inputs.json \\
      --savepath ./output/qwen3-vl-2b-instruct_w4a16_rk3576.rkllm
"""

import argparse
import hashlib
import os
import sys

# --- RK3576 的硬性约束（来源：doc/Rockchip_RKLLM_SDK_*_1.3.1.pdf, build() 接口说明） ---
RK3576_QUANT_DTYPES = {
    "w4a16", "w4a16_g32", "w4a16_g64", "w4a16_g128", "w8a8",
}
RK3576_NPU_CORES = (1, 2)
MAX_CONTEXT_LIMIT = 16384
CONTEXT_ALIGN = 32


def parse_args():
    p = argparse.ArgumentParser(description="Qwen3-VL-2B -> RKLLM (RK3576)")
    p.add_argument("--path", required=True, help="HF 模型目录（绝对路径）")
    p.add_argument("--target-platform", default="rk3576",
                   help="目标平台: rk3576 / rk3588 / rk3562 / rv1126b")
    p.add_argument("--num_npu_core", type=int, default=2,
                   help="NPU 核心数；RK3576 只能是 1 或 2")
    p.add_argument("--quantized_dtype", default="w4a16",
                   help="RK3576 支持: w4a16 / w4a16_g32 / w4a16_g64 / w4a16_g128 / w8a8")
    p.add_argument("--quantized_algorithm", default="normal",
                   choices=["normal", "grq"],
                   help="normal 通用；grq 精度更好但需要 CUDA GPU")
    p.add_argument("--optimization_level", type=int, default=1, choices=[0, 1],
                   help="1=精度优化（默认）；0=推理性能优化（官方 benchmark 用 0）")
    p.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    p.add_argument("--max_context", type=int, default=16384,
                   help="上下文长度上限，最大 16384 且 32 对齐")
    p.add_argument("--dataset", default="data/llm_inputs.json",
                   help="量化校准集（make_input_embeds_for_quantize.py 的产物）")
    p.add_argument("--savepath", default=None, help="输出的 .rkllm 路径")
    p.add_argument("--extra_qparams", default=None,
                   help="复用 grq 生成的 *.qparams 缓存文件（可选）")
    p.add_argument("--hybrid_rate", type=float, default=0.0,
                   help="混合量化比例 [0,1)，0 表示不混合")
    return p.parse_args()


def fail(msg):
    print("[ERROR] " + msg, file=sys.stderr)
    sys.exit(1)


def main():
    args = parse_args()

    # ---------------- 参数校验 ----------------
    if args.max_context > MAX_CONTEXT_LIMIT:
        fail(
            "max_context=%d 超过 RKLLM 1.3.1 的官方上限 %d。\n"
            "        官方文档原文：\"context: 上下文长度的上限值，最大支持到 16384 且必须按 32 对齐\"\n"
            "        所以 32K(32768) 在当前 SDK 上无法制作，请改用 <= 16384 的值。"
            % (args.max_context, MAX_CONTEXT_LIMIT)
        )
    if args.max_context % CONTEXT_ALIGN != 0:
        fail("max_context=%d 必须按 %d 对齐" % (args.max_context, CONTEXT_ALIGN))

    platform = args.target_platform.lower()
    if platform == "rk3576":
        if args.quantized_dtype not in RK3576_QUANT_DTYPES:
            fail("RK3576 不支持量化类型 '%s'。可选: %s\n"
                 "        （w8a8_g128 / w8a8_g256 / w8a8_g512 是 RK3588 专属）"
                 % (args.quantized_dtype, ", ".join(sorted(RK3576_QUANT_DTYPES))))
        if args.num_npu_core not in RK3576_NPU_CORES:
            fail("RK3576 的 NPU 核心数只能是 %s，当前为 %d（3 是 RK3588 的值）"
                 % (RK3576_NPU_CORES, args.num_npu_core))
    if args.quantized_algorithm == "grq" and args.device != "cuda":
        fail("quantized_algorithm=grq 需要 GPU：请加 --device cuda，或改用 --quantized_algorithm normal")

    if not os.path.isdir(args.path):
        fail("模型目录不存在: %s" % args.path)
    if not os.path.isfile(os.path.join(args.path, "config.json")):
        fail("模型目录里没有 config.json: %s" % args.path)

    dataset = args.dataset
    if not os.path.isfile(dataset):
        fail(
            "量化校准集不存在: %s（相对当前目录 %s）\n"
            "        请先运行:\n"
            "          python data/make_input_embeds_for_quantize.py --path %s --model_type qwen3vl\n"
            "        注意上游脚本产出的是 data/llm_inputs.json，不是 inputs.json。"
            % (dataset, os.getcwd(), args.path)
        )
    if args.extra_qparams and not os.path.isfile(args.extra_qparams):
        fail("extra_qparams 文件不存在: %s" % args.extra_qparams)

    savepath = args.savepath
    if savepath is None:
        savepath = os.path.join(
            "rkllm",
            "%s_%s_%s.rkllm" % (os.path.basename(args.path).lower(),
                                args.quantized_dtype, platform),
        )
    os.makedirs(os.path.dirname(os.path.abspath(savepath)), exist_ok=True)

    # ---------------- 打印配置 ----------------
    print("=" * 70)
    print("  Qwen3-VL -> RKLLM")
    print("=" * 70)
    for k, v in [
        ("model", args.path),
        ("target_platform", platform),
        ("num_npu_core", args.num_npu_core),
        ("quantized_dtype", args.quantized_dtype),
        ("quantized_algorithm", args.quantized_algorithm),
        ("optimization_level", args.optimization_level),
        ("device", args.device),
        ("max_context", args.max_context),
        ("dataset", dataset),
        ("savepath", savepath),
    ]:
        print("  %-20s: %s" % (k, v))
    print("=" * 70)

    from rkllm.api import RKLLM
    try:
        import rkllm
        print("  rkllm-toolkit version:", getattr(rkllm, "__version__", "unknown"))
    except Exception:
        pass

    llm = RKLLM()

    # ---------------- 加载 ----------------
    # 与上游 multimodal/export_rkllm.py 完全一致的调用方式（不传 dtype，用工具链默认）
    ret = llm.load_huggingface(model=args.path, device=args.device)
    if ret != 0:
        fail("load_huggingface 失败 (ret=%s)。若报内存错误，请加大内存/swap 或改用 --device cuda" % ret)
    print("[OK] 模型加载完成")

    # ---------------- 构建 / 量化 ----------------
    ret = llm.build(
        do_quantization=True,
        optimization_level=args.optimization_level,
        quantized_dtype=args.quantized_dtype,
        quantized_algorithm=args.quantized_algorithm,
        target_platform=platform,
        num_npu_core=args.num_npu_core,
        extra_qparams=args.extra_qparams,
        dataset=dataset,
        hybrid_rate=args.hybrid_rate,
        max_context=args.max_context,
    )
    if ret != 0:
        fail("build 失败 (ret=%s)。请检查量化类型/核心数是否符合 RK3576 限制、校准集是否正常" % ret)
    print("[OK] build + 量化完成")

    # ---------------- 导出 ----------------
    ret = llm.export_rkllm(savepath)
    if ret != 0:
        fail("export_rkllm 失败 (ret=%s)" % ret)

    # ---------------- 摘要 ----------------
    size = os.path.getsize(savepath)
    h = hashlib.sha256()
    with open(savepath, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    print("=" * 70)
    print("[OK] 导出成功")
    print("  file      : %s" % savepath)
    print("  size      : %.2f GB (%d bytes)" % (size / 1e9, size))
    print("  sha256    : %s" % h.hexdigest())
    print("  max_context: %d" % args.max_context)
    print("=" * 70)


if __name__ == "__main__":
    main()
