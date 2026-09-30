# Qwen3-VL-2B → RK3576 转换与部署套件

把 `Qwen/Qwen3-VL-2B-Instruct` 转换成 RK3576 上可跑的 **双模型产物**，并给出板端部署与排错流程。

---

## 0. 先说结论（两条重要信息）

### ✅ 能做的

| 项目 | 取值 |
|---|---|
| 目标平台 | `rk3576` |
| 量化类型 | `w4a16`（RK3576 上最快、最省内存） |
| NPU 核心数 | `2`（RK3576 只有 2 个核） |
| 视觉编码器 | `qwen3-vl_vision_rk3576.rknn`，输入 448×448 |
| 语言模型 | `qwen3-vl-2b-instruct_w4a16_rk3576.rkllm` |

### ❌ 32K 上下文做不到（这是本次最重要的一条）

你要求的 **32K 上下文无法制作**。RKLLM 1.3.1 在转换接口上写死了上限：

> `context`: 上下文长度的上限值，**最大支持到 16384 且必须按 32 对齐**；
> The maximum context length, **supported up to 16,384 and must be aligned to 32**.
> —— `doc/Rockchip_RKLLM_SDK_CN_1.3.1.pdf` / `..._EN_1.3.1.pdf`，`rkllm.build()` 接口说明（Table 3-3）

注意：模型本身是支持 256K 的（`config.json` 里 `max_position_embeddings = 262144`），
**限制来自 Rockchip 的工具链，不是模型**。所以：

- 本套件按 **`max_context = 16384`** 生成（官方上限，仍然是 32 的倍数）。
- `scripts/00_check_env.sh` 和 `scripts/export_rkllm_qwen3vl.py` 都会在 `MAX_CONTEXT > 16384` 时**直接报错退出**，避免你白等几小时才发现转换失败。
- 如果你确实需要处理超过 16K 的输入，见 [第 4 节：超长文本怎么办](#4-超长文本怎么办32k-的替代方案)。

---

## 1. 你会得到什么

跑完之后 `rk3576-qwen3-vl-2b/output/` 下会有：

```
output/
├── qwen3-vl_vision_rk3576.rknn                    # 视觉编码器（RKNN）
├── qwen3-vl_vision_rk3576.rknn.info               # 体积/sha256/输入规格
├── qwen3-vl-2b-instruct_w4a16_rk3576.rkllm        # 语言模型（RKLLM，max_context=16384）
├── qwen3-vl-2b-instruct_w4a16_rk3576.rkllm.info   # 体积/sha256/量化参数
└── demo_Linux_aarch64/                            # 板端可执行程序
    ├── demo, imgenc, audioenc, demo.jpg
    └── lib/{librknnrt.so, librkllmrt.so}
```

**为什么是两个文件**：多模态推理是"视觉走 RKNN、语言走 RKLLM"两段流水线——
`imgenc` 把图片编码成特征向量（image_embeds），再喂给 RKLLM 和文本 token 一起做推理。
板端的 `demo` 已经把这两步串起来了。

---

## 2. 本机（macOS）为什么不能直接做

当前工作机是 **macOS 27.2 / Apple M4 (arm64)**，而：

| 工具 | 可用平台 | 结论 |
|---|---|---|
| `rkllm-toolkit` | 只有 `linux_x86_64` 的 whl（PyPI 上没有，仅在本仓库 `rkllm-toolkit/packages/` 和官方 SDK 包里） | **必须 Linux x86_64** |
| `rknn-toolkit2` | PyPI 上只有 `manylinux x86_64` 和 `manylinux aarch64` | **必须 Linux**（x86_64 或 aarch64） |
| `RKLLM-Runtime` | 板端 aarch64 动态库（本仓库已带） | 板子上跑 |

所以整条链路要求一台 **Ubuntu x86_64** 机器（物理机 / 云主机 / Docker 容器都行）。
本套件就是为这台机器准备的一键脚本包。

---

## 3. 硬性约束速查

这些数字全部来自官方文档/官方代码，填错了会直接失败或精度崩掉：

| 约束 | 值 | 来源 |
|---|---|---|
| `max_context` 上限 | **16384，且 32 对齐** | RKLLM 1.3.1 文档 `build()` |
| RK3576 NPU 核心数 | **1 或 2**（3 是 RK3588） | RKLLM 1.3.1 文档 `build()` |
| RK3576 支持的量化 | `w4a16` `w4a16_g32` `w4a16_g64` `w4a16_g128` `w8a8` | 同上（`w8a8_g128/g256/g512` 是 RK3588 专属） |
| 校准集样本数 | 本仓库自带 20 条图文样本 | `data/datasets.json` |
| 视觉输入尺寸 | 448×448（**必须是 32 的倍数**） | `patch_size=16 × merge_size=2` |
| 归一化 mean/std | 0.5 / 0.5 | `preprocessor_config.json` |
| 单图 token 数 | 448×448 → 28×28 patches → 196 tokens | `(448/16/2)² = 196` |
| transformers（视觉侧） | **4.57.0** | 上游 README Qwen3-VL 章节 |
| transformers（RKLLM 侧） | **5.8.0** | `rkllm-toolkit/packages/requirements.txt` |
| rknn-toolkit2 | **>= 2.3.2** | 上游 README |

> `transformers` 两个版本互相冲突（4.57.0 vs 5.8.0），所以套件会建 **两个 conda 环境**，
> 分别负责视觉导出和 RKLLM 导出。这不是多余设计，是必须的。

---

## 4. 超长文本怎么办（32K 的替代方案）

既然 16K 是硬上限，处理长文档只有三条路：

1. **接受 16384 上限**（本套件默认）。16K ≈ 1.2 万汉字，绝大多数单图问答/文档摘要在其中。
2. **KV cache 滑窗（上下文滚动）**。`rkllm.h` 里 `RKLLMParam.n_keep`
   （*number of kv cache to keep at the beginning when shifting context window*）
   允许在超出 `max_context_len` 时丢掉中间部分、保留开头若干 token。
   代价是**中间内容会静默丢失**，回答质量下降——适合"只需要开头指令 + 最近几轮"的聊天场景，
   不适合"全文总结"。用法：在 `deploy/src/main.cpp` 里加一行
   ```cpp
   param.n_keep = 512;   // 按需调整
   ```
   然后重新 `05_build_demo.sh`。
3. **RAG / 分段处理**：把长文切段，逐段问，或者用检索只喂相关片段。这是质量最稳的做法。

> 想要真正的 32K，只能等 Rockchip 放开 `max_context` 上限，或者换用支持更长上下文的推理框架——
> 当前 RKLLM 1.3.1 上没有开关可以绕过。

---

## 5. 内存预算（16K 上下文）

### 板上内存

W4A16 权重 + KV cache。KV cache 大小可以按模型结构精算：

```
每 token KV = 2(K,V) × 28层 × 8个KV头 × 128 head_dim = 57,344 个数/token
```

| 上下文 | KV @ int8 (56 KiB/token) | KV @ fp16 (112 KiB/token) |
|---|---|---|
| 4096 | ≈ 224 MiB | ≈ 448 MiB |
| 8192 | ≈ 448 MiB | ≈ 896 MiB |
| **16384** | **≈ 896 MiB** | **≈ 1.75 GiB** |

> 上表是**按 `config.json` 结构算出来的估算值**（KV cache 的实际存储位宽由 RKLLM 内部决定，
> 没有在文档里公开），不是实测值。官方 `benchmark.md` 里 Qwen3-VL-2B w4a16 在 RK3576、
> seqlen=128 时的实测内存是 **1058.56 MB**——那是短上下文，长上下文要在此基础上再加 KV。

**建议**：

- **8GB RAM 的板子**：w4a16 + 16384 上下文可以跑，比较稳妥。
- **4GB RAM 的板子**：建议先把 `MAX_CONTEXT` 降到 8192 验证链路，再逐步往上试；
  w8a8（1876MB 起步）在 4GB 上基本没戏。
- 实测方法：板端 `RKLLM_LOG_LEVEL=1 ./run_demo.sh`，日志会打印 TTFT / tokens/s / **内存占用**。

### 构建机内存

转换过程比推理更吃内存，**强烈建议 >= 32GB**：

- `export_vision.py` 以 **float32** 加载整个 2B 模型 → 约 9GB 权重 + ONNX 图开销，峰值 12-16GB。
- `load_huggingface()` 同样把权重读进内存。

内存不够的典型症状是进程被 `Killed`（OOM），日志里没有 Python 报错。对策：加 swap、换机器、或跳过视觉导出。

---

## 6. 构建机要求

| 项 | 要求 |
|---|---|
| 系统 | Ubuntu 20.04 / 22.04 / 24.04，**x86_64** |
| CPU/内存 | 8 vCPU / **32GB RAM**（最低 16GB + 大 swap） |
| 磁盘 | ≥ 60GB（模型 4.3GB + torch/依赖约 8GB + ONNX/RKNN + conda 环境） |
| 网络 | 能访问 HuggingFace（国内可用 `HF_ENDPOINT=https://hf-mirror.com`） |
| 可选 | CUDA GPU（仅 `w4a16` + `grq` 量化算法需要，能提升 w4a16 精度） |
| 其他 | `adb`（推文件到板子）、aarch64 交叉编译器（编译 demo） |

### 不想自己准备机器？用 GitHub Actions

**可以。** GitHub 托管的 ubuntu runner 就是 **Linux x86_64**，而转换过程是**纯 CPU** 的
（不需要 NPU），所以 CI 完全能当转换机用。套件里已经准备好整套 workflow：

```bash
# 在你的 GitHub 仓库根目录（仓库里只要有 rk3576-qwen3-vl-2b/ 这个目录即可）
bash rk3576-qwen3-vl-2b/ci/install_workflow.sh
git add .github && git commit -m "ci: build workflow" && git push
# 然后 Actions 页面手动 Run workflow，产物直接从 Releases 下载
```

需要注意 runner 的三个硬约束（workflow 里已经全部处理掉了）：
**磁盘**（实测 runner 有 87GB 可用，脚本还会删预装 SDK 再腾出 ~23GB）、
**16GB 内存**（公有仓库；脚本会加 swap 兜底）、
**artifact 配额只有 500MB**（所以产物走 Release 附件，单文件上限 2GiB，超了自动分卷）。

**强烈建议用一个 public 仓库**：公有仓库是 4 vCPU / 16GB / **免费不限分钟**，
私有仓库只有 2 vCPU / **8GB** 且要消耗每月额度。
完整说明（含常见失败对照表）见 [`ci/README.md`](ci/README.md)。

### 想在本机跑？Docker + Rosetta 可以，但别误解 Rosetta

**Rosetta 不能直接让 macOS 跑 Linux 程序。** Rosetta 2 只翻译 macOS 的 x86_64 Mach-O；
而 `rkllm_toolkit-*-linux_x86_64.whl` 里是 **Linux ELF** 的 `.so`，需要 Linux 内核 + glibc。
实测：`arch -x86_64 /usr/bin/true` 能跑（Rosetta 可用），而 Linux ELF 直接
`cannot execute binary file`。

可行的是 **"Rosetta for Linux"**：Docker Desktop 在 Apple Silicon 上用 Apple 虚拟化框架跑
Linux VM，并可选开启
*Settings → General → "Use Rosetta for x86_64/amd64 emulation on Apple Silicon"*
（官方文档里这个选项**默认是 Disabled**）。这时 amd64 容器里的 Linux x86_64 二进制就能跑了。

套件里的 `docker/` 把这套流程做好了，并且**尽量少用翻译**：
`rknn-toolkit2` 有 aarch64 wheel，所以视觉导出、校准集、板端 demo 全部走 **arm64 原生**，
只有 `rkllm-toolkit`（只有 x86_64 wheel）那一步走 amd64 + Rosetta。

```bash
bash rk3576-qwen3-vl-2b/docker/smoke_test.sh     # ★ 先花几分钟验证 Rosetta 能否加载工具链
bash rk3576-qwen3-vl-2b/docker/local_build.sh    # 通过后再跑完整转换
```

前提：Docker Desktop（需管理员权限安装）、VM 内存调到 ≥16GB、磁盘 ≥45GB。
详见 [`docker/README.md`](docker/README.md)。

> 性价比上 **GitHub Actions 通常更优**：CI 跑在真 x86_64 上，没有翻译开销、不占本地磁盘、
> 公有仓库还免费不限分钟。本地 Docker 的价值在于"完全不依赖远端"。

---

## 7. 快速开始

```bash
# 0) 把本仓库放到构建机上
git clone https://github.com/airockchip/rknn-llm.git
cd rknn-llm/rk3576-qwen3-vl-2b

# 1) 按需修改配置（工作区路径、镜像、量化类型…）
vim config.env

# 2) 一键跑完：环境 → 下载 → 视觉 → RKLLM → 编译 demo
bash scripts/run_all.sh

# 3) 推送到板子并运行
bash scripts/06_push_to_board.sh
```

首次完整跑一遍大约需要 **1.5-3 小时**（主要花在 pip 下载、模型下载、ONNX 导出和量化上）。

### 目录结构

```
rk3576-qwen3-vl-2b/
├── README.md                  # 本文档
├── config.env                 # ★ 唯一需要改的地方（路径/量化/上下文）
├── Dockerfile                 # 可选的容器化构建环境
├── board/
│   └── run_demo.sh            # 板端运行脚本（会一起推到板子）
├── docker/                    # 本机 Docker 构建（arm64 原生 + Rosetta amd64）
│   ├── README.md              # ★ Rosetta 到底行不行、怎么配
│   ├── Dockerfile             # 同一份文件用 --platform 区分 arm64/amd64
│   ├── smoke_test.sh          # ★ 先跑这个验证可行性（dlopen 工具链的 .so）
│   └── local_build.sh         # 主驱动：混合 arm64/amd64 跑完整流程
├── ci/                        # GitHub Actions 云端构建
│   ├── README.md              # ★ 在 GitHub 上编译的完整说明
│   ├── build-qwen3-vl-2b-rk3576.yml  # workflow 模板（用 install_workflow.sh 安装）
│   ├── install_workflow.sh    # 把模板放到仓库的 .github/workflows/
│   ├── install_miniforge.sh   # runner 上装固定位置的 miniforge3
│   ├── prepare_tree.sh        # CI 里拼出「上游源码 + 本套件」的源码树
│   ├── ci_free_space.sh       # 腾磁盘 + 补 swap（实测 16GB RAM / 自带 3GB swap）
│   └── publish_assets.sh      # 产物发到 Release（自动处理 2GiB 分卷）
├── scripts/
│   ├── _common.sh             # 公共函数（日志/conda/自检）
│   ├── 00_check_env.sh        # 环境自检（不改任何东西）
│   ├── 01_env_setup.sh        # 建 conda 环境（--only both|rknn|rkllm）
│   ├── 02_download_model.sh   # 拉 Qwen3-VL-2B-Instruct
│   ├── 03_export_vision.sh    # HF → ONNX → RKNN
│   ├── 04_export_llm.sh       # 校准集 + RKLLM（max_context=16384）
│   ├── 05_build_demo.sh       # 交叉编译板端 demo
│   ├── 06_push_to_board.sh    # adb 推送 + 打印运行命令
│   ├── export_rkllm_qwen3vl.py # ★ 修正过上游 3 个问题的 RKLLM 导出脚本
│   └── run_all.sh             # 串起 00..05
└── output/                    # ★ 最终产物
```

---

## 8. 分步详解

### 00 环境自检

```bash
bash scripts/00_check_env.sh
```

只做检查、不修改任何东西。会校验：主机是否 Linux x86_64、`MAX_CONTEXT` 是否越界、
量化类型/核心数是否符合 RK3576、内存磁盘、conda 环境、仓库结构、模型是否就位。

### 01 安装工具链环境（只做一次）

```bash
bash scripts/01_env_setup.sh
```

- 建两个 conda 环境：`rkllm-toolkit`（transformers 5.8.0）、`rknn-toolkit2`（transformers 4.57.0）。
- torch 优先从 PyTorch CPU 索引装，避免被拖进 ~2.5GB 的 `nvidia-*` CUDA 依赖。
- `auto_gptq` 需要 CUDA 编译，装不上会自动过滤掉（Qwen3-VL 用不到 GPTQ）。
- 结束时两个环境都会 `import` 一次做验证。

若没有 conda，脚本会打印 miniforge 的安装命令。

### 02 下载模型

```bash
bash scripts/02_download_model.sh
```

- 下载 `Qwen/Qwen3-VL-2B-Instruct`（约 4.26GB，单个 `model.safetensors`）。
- 国内加速：`HF_ENDPOINT=https://hf-mirror.com bash scripts/02_download_model.sh`
- 校验权重体积 > 4GB，并打印模型结构（层数/头数/`max_position_embeddings`）。
- 已下好会自动跳过。

### 03 视觉编码器：HF → ONNX → RKNN

```bash
bash scripts/03_export_vision.sh
```

1. `export/export_vision.py --model_name=qwen3-vl --height=448 --width=448` → `onnx/qwen3-vl_vision.onnx`
2. `export/export_vision_rknn.py --target-platform=rk3576 --height=448 --width=448` → `rknn/qwen3-vl_vision_rk3576.rknn`

> **Qwen3-VL 的视觉模型是多输出的**：除了主特征，还会带 `deepstack_visual_indexes=[5,11,17]`
> 对应 3 路 deepstack 特征（通常共 4 路输出）。板端 `imgenc`/`demo` 会把它们按 token 交错拼进
> image_embeds 再喂给 LLM（见 `deploy/src/image_enc.cc`）。运行时会打印 `model input num / output num`，
> Qwen3-VL 的 `output num` 应该 > 1；如果只有 1，多半是 `--model_name` 传错或视觉模型导出不对。

脚本里加了一个**防呆检查**：上游用"ONNX 文件名里有没有 `qwen2`"来决定归一化参数
（含 `qwen2` → CLIP 均值方差；否则 → 0.5/0.5）。Qwen3-VL 的 `preprocessor_config.json`
确实是 `mean=std=0.5`，所以文件名里一旦出现 `qwen2` 就会**静默用错归一化、精度崩掉**。
本套件的 ONNX 固定叫 `qwen3-vl_vision.onnx`，并会断言文件名不含 `qwen2`。

### 04 语言模型：RKLLM

```bash
bash scripts/04_export_llm.sh
```

**4.1 生成量化校准集**（`data/llm_inputs.json` + `data/llm_inputs/`）

```bash
python data/make_input_embeds_for_quantize.py \
    --path /path/to/Qwen3-VL-2B-Instruct --model_type qwen3vl
```

> ⚠️ `--model_type qwen3vl` 是**必填**的。网上不少教程（基于 v1.2.x）漏了这个参数，
> 在 v1.3.1 上会直接报错。

脚本会先在 `rkllm-toolkit` 环境里做；如果该环境的 transformers 版本不兼容 Qwen3-VL
（报 `Qwen3VLForConditionalGeneration` 或 processor 相关的错），会自动改用
`rknn-toolkit2` 环境（transformers 4.57.0，官方针对 Qwen3-VL 验证过的版本）重试。

**4.2 构建并导出 RKLLM**（`export_rkllm_qwen3vl.py`）

```bash
python scripts/export_rkllm_qwen3vl.py \
    --path /path/to/Qwen3-VL-2B-Instruct \
    --target-platform rk3576 --num_npu_core 2 \
    --quantized_dtype w4a16 --max_context 16384 \
    --dataset data/llm_inputs.json \
    --savepath output/qwen3-vl-2b-instruct_w4a16_rk3576.rkllm
```

### 05 交叉编译板端 demo

```bash
bash scripts/05_build_demo.sh
```

- 自动寻找交叉编译器：优先 `~/opts/gcc-arm-10.2-2020.11-x86_64-aarch64-none-linux-gnu`，
  找不到就退回 apt 的 `aarch64-linux-gnu-g++`。
- 产物 `deploy/install/demo_Linux_aarch64/`，会带上 `librknnrt.so`、`librkllmrt.so`，
  并尽力把 `libgomp.so.1` 一起复制进 `lib/`（板子上最容易缺这个）。
- 会 `file` 检查一次 `demo` 确实是 aarch64。

### 06 推送到板子

```bash
bash scripts/06_push_to_board.sh
```

`adb push` 到 `BOARD_APP_DIR`（默认 `/home/linaro/qwen3-vl-2b`，在 `config.env` 里改），
然后打印两种运行方式。

---

## 9. 板端运行

```bash
adb shell
cd /home/linaro/qwen3-vl-2b
./run_demo.sh                      # 用自带的 demo.jpg
./run_demo.sh /path/to/your.jpg    # 换成自己的图
RKLLM_LOG_LEVEL=1 ./run_demo.sh    # 输出 TTFT / tokens/s / 内存占用
```

等价的完整命令（参数顺序在 v1.3.1 里加入了音频占位参数，**必须写 `"" ""`**）：

```bash
cd /home/linaro/qwen3-vl-2b/demo_Linux_aarch64
export LD_LIBRARY_PATH=./lib:$LD_LIBRARY_PATH
./demo demo.jpg ../qwen3-vl_vision_rk3576.rknn "" "" \
       ../qwen3-vl-2b-instruct_w4a16_rk3576.rkllm \
       2048 16384 2 rk3576 \
       "<|vision_start|>" "<|vision_end|>" "<|image_pad|>"
```

| 位置 | 含义 | 本次取值 |
|---|---|---|
| 1 | 图片路径 | `demo.jpg` |
| 2 | 视觉模型 | `qwen3-vl_vision_rk3576.rknn` |
| 3,4 | 音频路径 + 音频模型（无音频则都传 `""`） | `"" ""` |
| 5 | 语言模型 | `qwen3-vl-2b-instruct_w4a16_rk3576.rkllm` |
| 6 | `max_new_tokens` | 2048 |
| 7 | `max_context_len` | **16384** |
| 8 | `rknn_core_num` | **2** |
| 9 | `platform` | **rk3576** |
| 10-12 | 图像特殊 token | `<\|vision_start\|>` `<\|vision_end\|>` `<\|image_pad\|>` |

> `max_context_len` 必须 **大于** 文本 token + 图像 token(196) + `max_new_tokens`，否则推理会被截断。

**纯文本问答**（不用图片）：把位置 1、2 也传空串：

```bash
./demo "" "" "" "" ../qwen3-vl-2b-instruct_w4a16_rk3576.rkllm 2048 16384 2 rk3576
```

---

## 10. 常见问题排查

### 转换阶段

| 现象 | 原因 / 解决 |
|---|---|
| `ModuleNotFoundError: rkllm` | 忘了 `conda activate rkllm-toolkit`；或用错环境（视觉侧在 `rknn-toolkit2` 环境） |
| `dataset not found: data/inputs.json` | 上游文件名不一致：`make_input_embeds...` 产出的是 `llm_inputs.json`，而 `export_rkllm.py` 读 `inputs.json`。**用本套件的 `export_rkllm_qwen3vl.py`**（已修正），或手动 `--dataset data/llm_inputs.json` |
| `ImportError: cannot import name 'Qwen3VLForConditionalGeneration'` | transformers 版本不对：视觉/校准集侧要 4.57.0，RKLLM 侧要 5.8.0。别把两个环境混用 |
| `TypeError: build() got an unexpected keyword argument 'max_context'` | rkllm-toolkit 版本过旧（< 1.2.0）。本仓库自带的是 1.3.1，重新 `01_env_setup.sh` |
| `build` 返回 `-1` | 量化类型/核心数不符合 RK3576，或校准集损坏。核对第 3 节表格 |
| 进程无报错直接 `Killed` | OOM。加 swap 或换 ≥32GB 机器 |
| ONNX 导出报 `grid_h//merge_size` 之类维度错 | `--height/--width` 不是 32 的倍数。用 448 |
| `auto_gptq` 编译失败 | 只有转换 GPTQ 模型才需要，忽略即可（脚本已容错） |
| rknn-toolkit2 报 `libGL.so.1: cannot open shared object file` | `sudo apt-get install -y libgl1 libglib2.0-0 libsm6 libxext6` |

### 板端阶段

| 现象 | 原因 / 解决 |
|---|---|
| `error while loading shared libraries: libgomp.so.1` | 把交叉工具链里的 `libgomp.so.1` 拷到 `demo_Linux_aarch64/lib/`（`05_build_demo.sh` 已尽力自动处理）；或 `apt install libgomp1` |
| `librknnrt.so: version mismatch` / `rknn_init fail` | 板端 NPU 驱动与库版本不匹配。用板子系统自带的 `/usr/lib/librknnrt.so` 覆盖 `lib/librknnrt.so` |
| `rkllm_init` 失败 / 核心数报错 | `rknn_core_num` 必须是 1 或 2；`platform` 必须是 `rk3576` |
| 输出乱码 / 答非所问 | 特殊 token 传错。Qwen3-VL 是 `<\|vision_start\|>` `<\|vision_end\|>` `<\|image_pad\|>` |
| 板端 `output num: 1`（Qwen3-VL 应为多路） | 视觉模型导出不对：`--model_name` 必须是 `qwen3-vl`，别用 `qwen2_5-vl-3b` |
| 图像相关的回答明显不准 | 归一化参数错（ONNX 文件名含 `qwen2` 会触发）或视觉模型与语言模型不配套 |
| 回答被截断 | `max_context_len` 不够大，或 `max_new_tokens` 太小 |
| 内存不足 / 被 OOM Kill | 降 `MAX_CONTEXT` 到 8192 或 4096，改回 `w4a16`，或换 8GB 板子 |
| 速度慢（< 5 tokens/s） | 板端 root 身份跑仓库根目录的 `scripts/fix_freq_rk3576.sh`（需先推到板子）锁定 CPU/NPU 最高频；再确认 `optimization_level` |

### 性能参考（官方 `benchmark.md`，Qwen3-VL-2B / RK3576 / seqlen=128 / 64 new tokens）

| 量化 | TTFT | 生成速度 | 内存 |
|---|---|---|---|
| `w4a16` | 802.94 ms | **12.68 tokens/s** | **1058.56 MB** |
| `w4a16_g128` | 983.20 ms | 11.42 tokens/s | 1146.77 MB |
| `w8a8` | 785.79 ms | 7.62 tokens/s | 1876.62 MB |

> 这是**短上下文**的数据；16K 上下文下 TTFT 会明显变长、内存会明显变大。

---

## 11. 参数速查（`config.env`）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `WORKSPACE` | `~/rkllm-workspace` | 模型与中间产物目录 |
| `MODEL_DIR` | `$WORKSPACE/Qwen3-VL-2B-Instruct` | 本地模型路径 |
| `TARGET_PLATFORM` | `rk3576` | 目标平台 |
| `QUANTIZED_DTYPE` | `w4a16` | 见第 3 节可选值 |
| `QUANTIZED_ALGORITHM` | `normal` | `grq` 精度更好但需要 CUDA GPU |
| `OPTIMIZATION_LEVEL` | `1` | `1`=精度优先；`0`=性能优先（官方 benchmark 用 0） |
| `NUM_NPU_CORE` | `2` | RK3576 只能 1 或 2 |
| `MAX_CONTEXT` | `16384` | **上限 16384，32 对齐**，改大直接报错 |
| `IMG_HEIGHT` / `IMG_WIDTH` | `448` / `448` | 必须是 32 的倍数 |
| `BOARD_APP_DIR` | `/home/linaro/qwen3-vl-2b` | 板端目录 |
| `HF_ENDPOINT` | 空 | 国内设 `https://hf-mirror.com` |
| `GCC_COMPILER` | `~/opts/gcc-arm-10.2-...` | 交叉工具链，找不到会自动退回 apt 版 |

---

## 12. 附录：本套件相对上游改了 3 个地方（都必须改）

上游 `examples/multimodal_model_demo/export/export_rkllm.py` 直接拿来做 Qwen3-VL-2B + RK3576 会踩坑：

1. **没有传 `max_context`** → 用工具链默认值（远小于 16K）。
   本套件的 `export_rkllm_qwen3vl.py` 显式传 `max_context=16384` 并做越界校验。
2. **校准集文件名不一致** → `make_input_embeds_for_quantize.py` 写 `data/llm_inputs.json`，
   `export_rkllm.py` 读 `data/inputs.json`，照 README 跑会报找不到数据集。
   本套件统一到 `data/llm_inputs.json`，并在生成后逐个校验样本文件存在。
3. **`--model_type` 必填** → v1.3.1 的校准集脚本要求 `--model_type qwen3vl`，
   老教程普遍漏掉。本套件固定传入，并在失败时自动切换 conda 环境重试。

另外 `RK3576` 的 `num_npu_core` 只能是 1/2（官方 README 的示例用的是 RK3588 的 `3`），
本套件在 `00_check_env.sh` 和 Python 脚本里都做了拦截。

---

## 13. 参考来源

- 仓库内文档：`doc/Rockchip_RKLLM_SDK_CN_1.3.1.pdf`、`doc/Rockchip_RKLLM_SDK_EN_1.3.1.pdf`
  （`rkllm.build()` 接口说明 / Table 3-3 给出了 `max_context` 上限与 RK3576 的量化、核心数限制）
- 仓库内示例：`examples/multimodal_model_demo/README.md`、`benchmark.md`、`CHANGELOG.md`
- 上游仓库：<https://github.com/airockchip/rknn-llm>
- 模型：<https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct>
- 泰山派3-RK3576 的 Qwen3-VL 部署实践（v1.2.3，可对照参考）：
  <https://wiki.lckfb.com/zh-hans/tspi-3-rk3576/ai/qwen3-vl-2b-deploy.html>

---

## 14. 交付前自检清单

转换完成后，逐条确认再上板：

- [ ] `output/qwen3-vl_vision_rk3576.rknn` 存在，`.info` 里 sha256 有值，体积在几百 MB 量级
- [ ] `output/qwen3-vl-2b-instruct_w4a16_rk3576.rkllm` 存在，`.info` 里 `max_context: 16384`
- [ ] `.rkllm` 体积合理：w4a16 应在 **1.2-1.6 GB** 量级（明显偏小说明量化异常，偏大可能没量化成功）
- [ ] `output/demo_Linux_aarch64/` 里有 `demo`、`imgenc`、`demo.jpg`、`lib/librknnrt.so`、`lib/librkllmrt.so`
- [ ] `file output/demo_Linux_aarch64/demo` 显示 `ARM aarch64`
- [ ] 板端跑起来后日志里 `output num` > 1（Qwen3-VL deepstack 多路输出）
- [ ] `RKLLM_LOG_LEVEL=1` 下内存占用留有余量，没有频繁触发 OOM
- [ ] 用一张有明确答案的图（例如带文字的截图）验证：识别正确、回答完整没被截断

> 关于 `.rkllm` 体积的估算：2B 参数按 4bit 存约 1.0-1.1GB，加上 tokenizer/embedding 等约 1.2-1.6GB。
> 这只是量级参考，不是精确值——以 `.info` 里记录的实际字节数为准。
