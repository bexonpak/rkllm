# 在 GitHub Actions 上构建 Qwen3-VL-2B (RK3576)

**结论：可以。** GitHub 托管的 ubuntu runner 本身就是 **Linux x86_64**，
而 RKLLM 的量化/转换是**纯 CPU** 计算、完全不需要 NPU，
所以 CI runner 完全能当转换机用 —— 你不需要自己准备 Ubuntu 机器。

但默认 runner 有三个硬约束，这个 workflow 就是围绕它们设计的：

| 约束 | GitHub 默认值 | 本项目的需求 | 对策（已写进 workflow） |
|---|---|---|---|
| 磁盘 | **14 GB SSD** | 模型 4.3GB + conda 环境 ~10GB + 产物 ~3GB | `ci/ci_free_space.sh` 删预装 SDK，腾出 ~25GB |
| 内存 | **16 GB**（公有仓库）<br>**8 GB**（私有仓库） | 峰值 12-16GB（float32 加载整个 2B 模型） | 同脚本加 swap 兜底，避免无声 OOM Kill |
| artifact 配额 | **500 MB**（Free）<br>1GB(Pro) / 2GB(Team) | `.rkllm` ~1.5GB、`.rknn` ~0.6GB | 不走 artifact，改发 **Release 附件**（单文件上限 2GiB） |

参考：[GitHub-hosted runners 规格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) ·
[Actions 用量限制](https://docs.github.com/en/actions/reference/limits)

---

## 1. 强烈建议：用一个 public 仓库

| | 公有仓库 | 私有仓库 |
|---|---|---|
| runner | 4 vCPU / **16 GB** / 14 GB | 2 vCPU / **8 GB** / 14 GB |
| 分钟数 | **免费且不限** | 消耗额度（Free 2000 分钟/月） |
| 本次构建耗时 | 约 40-90 分钟 | 更慢（内存不足会大量走 swap） |
| 配额消耗 | 0 | 约 180-360 分钟/次 |

私有仓库只有 8GB 内存，float32 加载 2B 模型会大量换页，**同一个 workflow 可能要跑 3 小时以上**，
而且 Free 计划一个月只够跑 5-10 次。所以：**开一个 public 仓库专门跑这个转换**，
产物发到 Release 再下载即可。

> 这只是"用 CI 当构建机"，仓库里不需要放任何敏感内容；模型本身是 Apache-2.0。

---

## 2. 安装步骤

假设你已经把 `rk3576-qwen3-vl-2b/` 这个目录放进了你的仓库根目录：

```bash
# 你的仓库根目录
bash rk3576-qwen3-vl-2b/ci/install_workflow.sh

git add .github/workflows/build-qwen3-vl-2b-rk3576.yml
git commit -m "ci: build Qwen3-VL-2B for RK3576"
git push
```

然后：

1. 打开仓库 **Settings → Actions → General → Workflow permissions**，
   选 **Read and write permissions**（否则发不了 Release）。
2. 打开 **Actions** 页面 → 左侧选 **Build Qwen3-VL-2B (RK3576)** → **Run workflow**。
3. 参数保持默认即可（`w4a16` / `16384` / `2`），点绿色按钮。
4. 等 40-90 分钟，产物会出现在 **Releases** 页面。

### 仓库里需要有什么

```
你的仓库/
├── .github/workflows/build-qwen3-vl-2b-rk3576.yml   # install_workflow.sh 放进去的
└── rk3576-qwen3-vl-2b/                              # 本套件整个目录
    ├── config.env
    ├── scripts/
    └── ci/
```

上游源码（`examples/multimodal_model_demo`、`rkllm-toolkit/packages/*.whl`）**不需要**你放进来：
`ci/prepare_tree.sh` 会在 CI 里浅克隆 `airockchip/rknn-llm` 的 `release-v1.3.1` tag，
再把套件拷进去，自动拼出一棵可用的源码树。

> 如果你干脆 fork 了整个 `rknn-llm` 并把套件放进去，`prepare_tree.sh` 也会识别（"形态 A"），
> 不会重复克隆。两种仓库形态都支持。

---

## 3. 三个 job 与产物

| job | 做什么 | 产物 |
|---|---|---|
| **vision** | 装 miniforge → `01 --only rknn` → 下模型 → ONNX → RKNN | `qwen3-vl_vision_rk3576.rknn` + `.info` |
| **llm** | 装 miniforge → `01 --only both` → 下模型 → 校准集 → RKLLM | `qwen3-vl-2b-instruct_w4a16_rk3576.rkllm` + `.info` |
| **demo** | 交叉编译板端 demo（很轻，几分钟） | `demo_Linux_aarch64.tar.gz` |

`ci/` 目录里各文件的职责：

| 文件 | 作用 |
|---|---|
| `build-qwen3-vl-2b-rk3576.yml` | workflow 模板（要装到仓库根的 `.github/workflows/`） |
| `install_workflow.sh` | 把模板装到正确位置，并检查套件是否在仓库根 |
| `install_miniforge.sh` | 在 runner 上装**固定位置**的 miniforge3（镜像自带的 Miniconda 路径不确定，不能依赖） |
| `prepare_tree.sh` | 浅克隆上游 + 把套件拷进去，拼出可用的源码树 |
| `ci_free_space.sh` | 删预装 SDK 腾磁盘 + 加 swap 兜住内存峰值 |
| `publish_assets.sh` | 产物发到 Release，超过 2GiB 自动分卷 + 生成 sha256 |

> `llm` job 装 `--only both` 是**保险**：`04_export_llm.sh` 生成量化校准集时会先试 rkllm 环境
> （transformers 5.8.0），失败则自动回退到 rknn 环境（transformers 4.57.0，官方针对 Qwen3-VL 验证的版本）。
> 这多花几分钟和约 5GB 磁盘，换一次跑通的把握。磁盘紧张时改成 `--only rkllm` 即可。

三个 job 并行跑，所以总耗时 ≈ 最慢那个 job（约 40-90 分钟）。
最后一个 `summary` job 会把结果写进 Actions 的 Summary 页面。

---

## 4. 拿产物：Release，不是 Artifact

构建完成后到 **Releases** 页面，tag 就是你填的 `release_tag`（默认 `qwen3-vl-2b-rk3576`）。
每个文件旁边都有一个 `.sha256.txt`，下载后校验：

```bash
sha256sum -c qwen3-vl_vision_rk3576.rknn.sha256.txt
```

### 如果看到 `.part-00 / .part-01 / ...`

说明原文件超过了 Release 的 **2GiB 单文件上限**（`w8a8` 量化时很可能触发），
脚本自动按 1800MB 分卷了。合并 + 校验：

```bash
cat qwen3-vl-2b-instruct_w8a8_rk3576.rkllm.part-* > qwen3-vl-2b-instruct_w8a8_rk3576.rkllm
sha256sum -c qwen3-vl-2b-instruct_w8a8_rk3576.rkllm.parts.sha256.txt
```

`w4a16` 的 `.rkllm` 约 1.2-1.6GB，不会分卷；`w8a8` 约 2.2GB，会分卷。

---

## 5. 缓存与重跑

workflow 缓存了两样东西（`actions/cache`，仓库上限 10GB）：

| 缓存 | key | 大小 | 作用 |
|---|---|---|---|
| 模型权重 | `qwen3vl-2b-instruct-model-v1` | 4.3GB | 第二次起不用重新下 4.3GB |
| pip 缓存 | `pip-linux-<job>-v1` | 1-2GB | conda 环境安装快很多 |

注意：**conda 环境本身没有缓存**（两个环境加起来接近 10GB，会把模型缓存挤掉）。
如果你要频繁重跑，可以把 `~/miniforge3/envs` 也加进缓存，但要接受模型缓存被淘汰的风险。

**只想重跑失败的那个 job**：在 Actions 页面该次运行里点 **Re-run failed jobs**，
不要点 "Re-run all jobs"（否则三个 job 全部重来）。

**改了量化类型/上下文后**：文件名会变，Release 里会同时保留新旧产物（同名会覆盖）。

**缓存要怎么清**：Actions → Caches（左侧）→ 删除对应条目。

---

## 6. 常见失败与对策

| 现象 | 原因 | 对策 |
|---|---|---|
| `No space left on device` | 14GB 不够，或 swap 把磁盘吃满 | ①把 job 里 `SWAP_GB` 调小（vision 12→6，llm 8→4）；②看日志里 `df -h /` 确认 `ci_free_space.sh` 真的释放了空间；③**最有效的一招**：把 `llm` job 的 `--only both` 改成 `--only rkllm`，少装一个 conda 环境，省约 5GB（代价：校准集在 rkllm 环境里生成失败时没有回退环境） |
| 进程被 `Killed`，Python 没有任何报错 | OOM | 加大 `SWAP_GB`；或改用 public 仓库（16GB 而非 8GB） |
| `Resource not accessible by integration` / 上传附件 403 | workflow 没有写权限 | Settings → Actions → General → Workflow permissions 改成 Read and write |
| `上传附件失败` 且文件接近 2GB | 超过 Release 单文件上限 | 已自动分卷；若仍失败，把 `SPLIT_THRESHOLD_MB` 调到 1500 |
| `在 ... 下找不到 rk3576-qwen3-vl-2b/config.env` | 套件没放在仓库根目录 | 把 `rk3576-qwen3-vl-2b/` 移到仓库根再 push |
| `克隆上游失败` | tag 名不对 / 网络问题 | 检查 `upstream_ref`，默认 `release-v1.3.1`；也可换成 `main` |
| `build() got an unexpected keyword argument 'max_context'` | 上游 tag 太旧 | 用 `release-v1.3.1` 或更新的 tag |
| `max_context=... 超过 RKLLM 1.3.1 的官方上限 16384` | 输入填了 32K | **这是预期行为**：32K 在当前 SDK 上做不到，改成 ≤16384 且 32 的倍数 |
| 想自动触发 | 默认只有手动触发 | 在 workflow 的 `on:` 下加 `push: { branches: [main] }`，但注意每次 push 都会跑 ~1 小时 |

---

## 7. 关于"32K 上下文"

workflow 输入里 `max_context` 默认 `16384`，**填 32000 之类会被套件脚本直接拒绝并给出文档原文**。
原因见 `../README.md` 第 0 节：RKLLM 1.3.1 的 `rkllm.build()` 文档写明
"上下文长度的上限值，最大支持到 16384 且必须按 32 对齐"。
这是 SDK 限制，不是 runner 或 CI 的限制 —— 换到任何机器上跑都是一样的结果。

---

## 8. 本地跑 vs CI 跑

| | 本地 Ubuntu x86_64 | GitHub Actions |
|---|---|---|
| 准备成本 | 装 miniforge + 两个环境 | push 代码即可 |
| 内存 | 你自己决定（建议 32GB） | 16GB(public) / 8GB(private) + swap |
| 耗时 | 1.5-3 小时（4 核） | 40-90 分钟（CI 机器通常更快） |
| 产物取回 | 本地 `output/` | Release 下载 |
| 适合 | 反复调试、改脚本 | 一次成型、不想配环境 |

两条路产物完全一致 —— CI 只是换了一台 Ubuntu x86_64 去执行同一批脚本。
