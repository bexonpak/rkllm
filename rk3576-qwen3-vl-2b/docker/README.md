# 在本地 Docker 里构建（macOS + Rosetta）

## 0. 先纠正一个常见误解

**"Rosetta 能让 macOS 直接跑 Linux 的 x86_64 程序" —— 不行。**

Rosetta 2 只翻译 **macOS 的 x86_64 Mach-O** 二进制。而
`rkllm_toolkit-*-linux_x86_64.whl` 里面是 **Linux ELF** 的 `.so`，
它需要 Linux 内核 + glibc，Rosetta 翻译不了它。实测：

```console
$ arch -x86_64 /usr/bin/true          # macOS x86_64 二进制
  ✓ 可以运行（Rosetta 可用）

$ ./some-linux-x86_64-binary          # Linux ELF
  bash: ./some-linux-x86_64-binary: cannot execute binary file
```

**但"Rosetta for Linux"可以** —— 也就是在一台 Linux 虚拟机里跑 amd64 容器。
Docker Desktop 有这个能力，官方设置项写着：

> **Use Rosetta for x86_64/amd64 emulation on Apple Silicon**
> *(Available with the Apple Virtualization framework VMM)*
> Accelerate x86/AMD64 binary emulation on Apple Silicon. — **Disabled**（默认关闭）

来源：[Docker Desktop settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/)、
[GitHub-hosted runners 规格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

所以结论是：**要先把 Docker Desktop 装好并打开那个开关**，Rosetta 才有意义。

---

## 1. 核心思路：能用原生就用原生

| 组件 | 有没有 aarch64 版 | 那就…… |
|---|---|---|
| `rknn-toolkit2` | ✅ PyPI 上有 `manylinux_2_17_aarch64` wheel（2.3.2 共 7 个 aarch64 wheel） | **arm64 原生**跑，全速 |
| `rkllm-toolkit` | ❌ 仓库/官方只有 `linux_x86_64` | 只能 **amd64 + Rosetta** |
| `torch` | ✅ `manylinux_2_28_aarch64` | arm64 原生 |

所以本方案把整条链路拆开：

```
arm64 原生容器                       amd64(Rosetta) 容器
─────────────────────               ─────────────────────
02 下载模型
03 视觉编码器 → .rknn
04 --phase calib（量化校准集）
05 编译板端 demo（原生 aarch64）
                                    01 装 rkllm-toolkit
                                    04 --phase build → .rkllm
```

**Rosetta 只承担一步**（RKLLM 构建），其余全速。
两个容器共享同一个工作区挂载，所以模型只下载一次、产物集中在一处。

> 与"全都在 amd64 下跑"相比，这个拆法的收益是：视觉导出（float32 加载 2B 模型，
> 最重的一步）和 demo 编译都跑在原生 arm64 上，不付翻译税。

---

## 2. 前提条件

| 项 | 要求 |
|---|---|
| Docker Desktop | Apple Silicon 版（**需要管理员权限安装**） |
| Rosetta 开关 | Settings → General → 勾选 *Use Rosetta for x86_64/amd64 emulation on Apple Silicon*（默认是关的） |
| VM 内存 | Settings → Resources → Memory **≥ 16GB**（float32 加载 2B 模型峰值 12-16GB） |
| 磁盘 | **≥ 45GB**（Docker 镜像 ~2GB + arm64 环境 ~6GB + amd64 环境 ~6GB + 模型 4.3GB + 中间产物 ~4GB + pip 缓存） |
| 网络 | 能访问 PyPI / HuggingFace（国内可设 `HF_ENDPOINT=https://hf-mirror.com`） |

> 本机实测：24GB 内存 / 10 核 / 剩余磁盘 70GB —— **内存和磁盘都够**，
> 但 Docker Desktop 的 VM 内存必须手动调上去（默认值偏低）。

---

## 3. 用法

```bash
cd <rknn-llm 仓库根>          # 或任何含 rk3576-qwen3-vl-2b/ 的目录

# 第 1 步：先花几分钟验证 Rosetta 到底行不行（★ 强烈建议）
bash rk3576-qwen3-vl-2b/docker/smoke_test.sh
# 想顺便测一下 Rosetta 的性能损失（多下 200MB）：
FULL=1 bash rk3576-qwen3-vl-2b/docker/smoke_test.sh

# 第 2 步：通过后再跑完整转换
bash rk3576-qwen3-vl-2b/docker/local_build.sh
```

常用变体：

```bash
ONLY=vision bash docker/local_build.sh        # 只做视觉 + 校准集
ONLY=llm    bash docker/local_build.sh        # 只做 RKLLM 构建（需已有校准集）
ONLY=demo   bash docker/local_build.sh        # 只编板端 demo（几分钟）
VISION_ON=amd64 bash docker/local_build.sh    # 视觉也走 amd64（见第 5 节）
MEMORY_LIMIT=16g bash docker/local_build.sh   # 显式限制容器内存
MAX_CONTEXT=8192 bash docker/local_build.sh   # 换上下文长度
```

产物：`<源码树>/rk3576-qwen3-vl-2b/output/`
（`local_build.sh` 结束时会打印完整路径和板端推送命令）

---

## 4. 为什么先跑 smoke_test.sh

它只回答一个决定性问题：

> `rkllm-toolkit` 的 x86_64 原生 `.so`，能不能在 Rosetta 下加载？

做法是把 wheel 里的 `.so` 全部 `dlopen` 一遍 —— 如果里面用了 Rosetta 不支持的指令，
**加载阶段就会暴露**（`Illegal instruction`），不用等几小时后的量化步骤。

- **通过** → 本地路线可行，继续 `local_build.sh`
- **失败** → 本地 Rosetta 路线直接作废，请走 GitHub Actions（[`../ci/README.md`](../ci/README.md)）
- **报 `cannot open shared object file`** → 是缺系统库（`libgomp1`/`libstdc++6`），不是 Rosetta 问题，
  smoke test 里已经先装了这些库；若仍报错把完整报错发我

> ⚠️ 诚实说明：这个测试是**必要条件，不是充分条件**。`dlopen` 能过、但某个
> 深层函数里用了不支持的指令，依然可能在真正量化时才崩。真到那一步，报错通常是
> `Illegal instruction (core dumped)`，那就只能用 GitHub Actions 了。

---

## 5. 已知风险与对策

| 风险 | 说明 | 对策 |
|---|---|---|
| `rkllm-toolkit` 在 Rosetta 下崩 | 只有 x86_64 wheel，无法绕开翻译 | 先跑 smoke test；不行就走 CI |
| `rknn-toolkit2` 的 aarch64 wheel 不能**转换** | PyPI 上确实有 aarch64 wheel，但 Rockchip 文档默认按 x86_64 写，转换功能在 aarch64 上未被我验证 | `VISION_ON=amd64 bash docker/local_build.sh` 一键切到 amd64 |
| OOM（进程无报错被杀） | VM 内存 < 峰值 12-16GB | Docker Desktop → Resources → Memory 调到 16GB；或降 `MAX_CONTEXT` |
| 磁盘写满 | 4 个环境 + 模型 + 中间产物 | `ONLY=` 分步跑，跑完一步删掉不再需要的中间产物；`docker system prune` |
| Rosetta 太慢 | 翻译后的 torch 数值计算明显慢于原生 | 只有 RKLLM 那一步受影响；若整条都慢，说明 `VISION_ON` 被设成了 amd64 |
| Linux 上挂载目录变成 root 所有 | 容器以 root 运行 | macOS（VirtioFS）会自动映射回你的用户，无此问题 |
| `docker` 守护进程没起 | Docker Desktop 未启动 | `docker info` 能过再跑脚本 |

---

## 6. 本地 Docker vs GitHub Actions

| | 本地 Docker (Rosetta) | GitHub Actions |
|---|---|---|
| 前置 | 装 Docker Desktop（管理员权限）+ 改两个设置 | 只需 push 代码 |
| 架构 | arm64 原生 + 一步 Rosetta 翻译 | **真 x86_64，零翻译开销** |
| 耗时 | 视觉部分快，RKLLM 那步慢（Rosetta） | 约 40-90 分钟 |
| 磁盘 | 占用本地 45GB+ | 不占本地 |
| 成本 | 免费（但费你的机器和时间） | 公有仓库免费不限分钟 |
| 隐私 | 完全本地 | 代码要推到 GitHub（模型本身是 Apache-2.0） |
| 适合 | 不想用 CI / GitHub 网络不稳 | 想省事、想要最快路径 |

两条路**产物完全一致**（同一批脚本、同样的参数），只是执行环境不同。

---

## 7. 目录里各文件

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 构建镜像（同一份文件用 `--platform` 区分 arm64/amd64），**不预装 conda** |
| `smoke_test.sh` | ★ 可行性验证：dlopen rkllm-toolkit 的 `.so`，可选测 torch 性能 |
| `local_build.sh` | 主驱动：拼源码树 → 建镜像 → arm64/amd64 混合跑各步骤 → 汇总产物 |

设计上的两个取舍，写出来便于你判断：

1. **镜像里不装 conda 环境**，conda 和两个环境都装在挂载进来的工作区
   （`conda-arm64/` 与 `conda-amd64/` 分开，避免两种架构的环境互相污染）。
   好处：镜像构建只要 2-3 分钟、改依赖不用重建镜像、重跑不用重新下 torch。
2. **工作区持久化在宿主**（`~/rkllm-workspace`），所以模型只下一次，
   重跑某个阶段用 `ONLY=...` 即可。
