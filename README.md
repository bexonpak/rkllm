# rkllm — Qwen3-VL-2B → RK3576 模型构建

用 **GitHub Actions** 把 [`Qwen/Qwen3-VL-2B-Instruct`](https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct)
转换成 RK3576 开发板上可运行的两个文件，产物直接发到本仓库的 **Releases**。

| 产物 | 说明 |
|---|---|
| `qwen3-vl_vision_rk3576.rknn` | 视觉编码器（RKNN，输入 448×448） |
| `qwen3-vl-2b-instruct_w4a16_rk3576.rkllm` | 语言模型（RKLLM，w4a16，上下文 16384） |
| `demo_Linux_aarch64.tar.gz` | 板端可执行程序（含 imgenc / demo / 依赖库） |

## ⚠️ 先看这一条：32K 上下文做不到

RKLLM 1.3.1 的 `rkllm.build()` 接口文档写死了上限：

> **context: 上下文长度的上限值，最大支持到 16384 且必须按 32 对齐**
> The maximum context length, **supported up to 16,384 and must be aligned to 32**.
> —— `doc/Rockchip_RKLLM_SDK_CN_1.3.1.pdf` / `..._EN_1.3.1.pdf`，Table 3-3

模型本身支持 256K（`max_position_embeddings=262144`），**限制来自 Rockchip 工具链**。
所以本仓库按 **`max_context = 16384`** 构建；workflow 输入里填更大的值会被脚本直接拒绝。

## 怎么跑

1. **确认 workflow 权限**（只需一次）
   `Settings → Actions → General → Workflow permissions` → 选 **Read and write permissions**
   （否则构建成功后发不了 Release）

2. **手动触发**
   `Actions` → 左侧 **Build Qwen3-VL-2B (RK3576)** → **Run workflow**
   参数保持默认即可（`w4a16` / `16384` / `2`）

3. **拿产物**
   构建完成后到 **Releases** 页面下载。每个文件旁边有 `.sha256.txt` 可校验。

首次运行约 **40-90 分钟**。仓库应该设为 **public**：公有仓库的 runner 是
4 vCPU / 16GB 且**免费不限分钟**，私有仓库只有 2 vCPU / 8GB 且消耗每月额度。

> 如果遇到 `No space left on device`，把 `.github/workflows/build-qwen3-vl-2b-rk3576.yml`
> 里 `llm` job 的 `--only both` 改成 `--only rkllm`（省约 5GB）。

## 构建结果（2026-09-30 实测）

三个产物均已构建成功并发布到 [Releases](../../releases/tag/qwen3-vl-2b-rk3576)：

| 产物 | 大小 | 关键参数 | sha256 |
|---|---|---|---|
| `qwen3-vl_vision_rk3576.rknn` | 873.5 MB | 输入 `pixel[1,3,448,448] + grid_thw[1,3]`，mean/std=0.5 | `06ae8e05…c9996` |
| `qwen3-vl-2b-instruct_w4a16_rk3576.rkllm` | 1859.1 MB | `max_context=16384`、`w4a16`、`num_npu_core=2` | `983066fb…31e1e` |
| `demo_Linux_aarch64.tar.gz` | 11.1 MB | 板端 demo（含 librknnrt/librkllmrt） | `29bef91d…2f6dbd` |

每个产物旁边都有完整的 `.sha256.txt`，下载后可直接校验：

```bash
sha256sum -c qwen3-vl_vision_rk3576.rknn.sha256.txt
```

构建耗时：约 20-30 分钟（三个 job 并行；模型缓存命中后更快）。

### 踩过的坑（都已修在套件里）

这些问题的修法都写进了脚本注释，供以后再遇到时参考：

| 现象 | 真因 |
|---|---|
| job 一开始就失败，`dd: /swapfile: Text file busy` | runner 镜像自带 3GB swap 就在 `/swapfile` 且正在使用；改为另建 `/swap-extra`，并让环境准备 fail-soft |
| pip 下载慢到离谱（766MB 要 76 分钟） | 阿里云镜像在海外 runner 上极慢；改用官方源，并修正「先装 CPU torch 再装 wheel」的顺序（省掉 766MB + 2.5GB nvidia 依赖） |
| `ModuleNotFoundError: onnxscript` | torch 2.6 的 `torch.onnx.export` 无条件 import 它；补装并加前置检查 |
| `hf download` 报成功却下了 0 个文件 | `huggingface_hub` 1.33.0 的 `--exclude` 只收一个值，其余被当成文件名；改用 Python API `snapshot_download(ignore_patterns=[...])` |
| `GuardOnDataDependentSymNode` | 未固定的 torchvision 把 torch 升到 2.14（默认 dynamo 导出器）；锁死 torch 2.4.0 + torchvision 0.19.0，并加版本断言 |
| `ModuleNotFoundError: pkg_resources` | setuptools ≥82 移除了它，而 rknn-toolkit2 需要；按需降级 `setuptools<82` |

---

## 板端部署

```bash
adb push demo_Linux_aarch64.tar.gz /data/ && adb shell
cd /data && tar xzf demo_Linux_aarch64.tar.gz && cd demo_Linux_aarch64
# 把 .rknn / .rkllm 放进上一级目录，然后：
export LD_LIBRARY_PATH=./lib:$LD_LIBRARY_PATH
./demo demo.jpg ../qwen3-vl_vision_rk3576.rknn "" "" \
       ../qwen3-vl-2b-instruct_w4a16_rk3576.rkllm \
       2048 16384 2 rk3576 \
       "<|vision_start|>" "<|vision_end|>" "<|image_pad|>"
```

（第 3、4 个参数是音频占位，没有音频时传空串；参数顺序在 RKLLM 1.3.1 里加入了音频参数。）

## 仓库结构

```
.
├── .github/workflows/
│   └── build-qwen3-vl-2b-rk3576.yml   # GitHub Actions 构建流程
└── rk3576-qwen3-vl-2b/                # 完整转换套件
    ├── README.md                      # ★ 详细文档：限制、内存预算、分步操作、排错
    ├── config.env                     # ★ 唯一需要改的配置
    ├── ci/README.md                   # ★ 在 GitHub 上构建的完整说明
    ├── scripts/                       # 转换脚本（本地 Ubuntu 上也能跑）
    └── docker/                        # 备选：本机 Docker + Rosetta
```

上游源码（`airockchip/rknn-llm`）**不需要放进本仓库**：workflow 会在 CI 里浅克隆
`release-v1.3.1`，再把套件拷进去自动拼出可用的源码树。

## 更多

- 详细转换/部署/排错文档：[`rk3576-qwen3-vl-2b/README.md`](rk3576-qwen3-vl-2b/README.md)
- GitHub Actions 说明：[`rk3576-qwen3-vl-2b/ci/README.md`](rk3576-qwen3-vl-2b/ci/README.md)
- 本机 Docker（Rosetta）备选方案：[`rk3576-qwen3-vl-2b/docker/README.md`](rk3576-qwen3-vl-2b/docker/README.md)

基于 [airockchip/rknn-llm](https://github.com/airockchip/rknn-llm) v1.3.1。
