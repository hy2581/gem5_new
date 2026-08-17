# gem5 + Vortex SimX + CoralNPU 异构访存 trace

把三个各自独立的仿真器放进**一个** gem5 进程里跑，让它们的访存落在同一张物理地址图上、
用同一个时间基准打时间戳，然后各自产出一份可归并的访存 trace。

```
                          gem5 进程（单线程事件队列，唯一时间基准 curTick()）
   ┌──────────────────────────────────────────────────────────────────────┐
   │  X86 TimingSimpleCPU ×N ── L1I/L1D ── L2 ──[CommMonitor]── membus    │
   │       (SE 模式 host)                          │ tap        │          │
   │                                               │      ┌─────┴─────┐    │
   │  CoralNPU (Verilator RTL)                     │      │ host_mem  │    │
   │    AXI master ──[tap]──> physProxy ───────────┼──────│ shared_mem│    │
   │    PIO 0x30000000 ────────────────────────────┤      │ npu_work  │    │
   │                                               │      └───────────┘    │
   │  VortexGPGPU (SimX)                           │                       │
   │    Memory pre_send ──[tap]──> 设备内 simx::RAM │                       │
   │    PIO 0x20000000 / BAR 0xa0000000 ───────────┘                       │
   └──────────────────────────────────────────────────────────────────────┘
                 │                  │                  │
          host.hettrace     vortex.hettrace     coralnpu.hettrace
                 └──────────────────┴──────────────────┘
                        python3 -m hettrace {validate,merge,stats,convert}
```

三个 tap 都是**只读观察者**：装上它们不改变任何一个仿真器的行为。这决定了这些 trace 能回
答什么、不能回答什么 —— 在动手分析之前请先读
[docs/03-limitations.md](docs/03-limitations.md)。

## 现在能跑到什么程度

| | host | CoralNPU | Vortex |
|---|---|---|---|
| 在 gem5 里跑起来、tap 产出记录 | ✅ | ✅ | ✅ |
| 时间戳来自同一个 `curTick()` | ✅ | ✅ | ✅ |
| 与 host **共享字节**（不只是共享地址） | — | ✅ 含反向对照 | ✅ 经 CP 中转，见下 |
| Vortex ↔ CoralNPU 直接共享 | | ❌ **结构性不可能** | |
| 三源同时跑、区间重叠、归并成一条流 | ✅ | | |

三个协同验收，逐层加码：

* `gem5int/tests/run_het.sh` —— host + CoralNPU，四步，最后一步是反向对照。
* `gem5int/tests/run_vortex_shared.sh` —— host + Vortex，五步，用 Vortex 上游的 `vecadd`
  回归测试走完整的 host runtime → CP → 核 路径。它的自检通过（`PASSED!`）本身就是字节共享
  的功能性证据；trace 层面量到 110 条共享 cache line。
* `gem5int/tests/run_three_source.sh` —— 两条腿**同时**在一个 gem5 进程里（14 秒跑完）。
  它验的是合起来才能验的那几条：三份 trace 出自同一个 `curTick()`、两个设备的活动区间真的
  重叠（NPU 那 1.7 us 整个落在 Vortex 那 148 us 里）、两个交接区各自量到共享
  （host↔NPU 8 条 line / host↔Vortex 106 条）、归并出的 19893 条单调流里三个源交错。
  负载是 `workloads/three_source/`：Vortex 的活异步提交完立刻启动 NPU，故意让区间重叠 ——
  串行链虽然更像真实应用，但那样归并流里永远不会出现两源夹在一起的片段。

两条腿的**交接形状不同**：CoralNPU 与 host 直接访问同一段 gem5 内存，Vortex 则是 host 写
BAR 顶部的暂存区、CP 再把字节搬进设备缓冲。所以 Vortex 的 trace 里必须有 CP 的 DMA 记录
（`kFlagDma`），否则两边足迹不相交、共享 line 数会是 0 —— 而计算是对的。这个坑和它的后果
写在 [docs/03-limitations.md](docs/03-limitations.md) 里。

"Vortex ↔ CoralNPU 直接共享"那一格不是待办：`vortex_bar` 必须落在 4 GiB 之上，CoralNPU 的
AXI 地址只有 32 位，连表达都做不到。要交换数据只能由 host 中转。

## 快速开始

```bash
# 0. 不需要任何仿真器的检查（addrmap 同步性 + 193 项自测）
make check

# 1. 装进三棵树（都幂等，都支持 --revert）
GEM5_HOME=$HOME/gem5                ./gem5int/install.sh
VORTEX_HOME=$HOME/vortex-gpu/vortex ./vortexint/install.sh
CORALNPU_HOME=$HOME/coralnpu        ./coralnpuint/install.sh
GEM5_HOME=$HOME/gem5 $VORTEX_HOME/sim/simx/gem5/install.sh   # 顺序不能反

# 2. 构建（细节和坑见 docs/04-integration.md）
scons -C $HOME/gem5 build/X86/gem5.opt -j$(nproc)
cd $HOME/coralnpu && bazel build //gem5int:libcoralnpu-gem5.so //gem5int:ddr_touch.elf

# 3. 主验收
GEM5_HOME=$HOME/gem5 CORALNPU_HOME=$HOME/coralnpu gem5int/tests/run_het.sh
```

跑通之后 trace 目录里会有 `host.hettrace` / `coralnpu.hettrace` 和各自的
`.meta.json` 侧车文件：

```bash
export PYTHONPATH=$PWD/tools
python3 -m hettrace validate $DIR    # 这批 trace 能不能用来分析
python3 -m hettrace stats    $DIR    # 带宽 / footprint / 共享 cache line 数
python3 -m hettrace dump     $DIR/host.hettrace -n 50
python3 -m hettrace convert  $DIR --preset readwrite -o ram.trace
```

## 目录

| 路径 | 是什么 |
|---|---|
| `addrmap.json` | 统一物理地址图。**唯一手写的真值源** |
| `scripts/gen_addrmap.py` | 由它生成 C++ 和 Python 两侧的地址表 |
| `libhettrace/` | trace 记录格式与写出器。header-only，三个 tap 共用 |
| `tools/hettrace/` | 离线分析：validate / merge / stats / dump / convert |
| `gem5int/` | gem5 侧：CoralNPU 设备、host probe、异构配置脚本、测试 |
| `vortexint/` | Vortex 侧：tap 与 5 个补丁 |
| `coralnpuint/` | CoralNPU 侧：设备库 ABI、tap、验证内核、2 个补丁 |
| `workloads/shared_buffer/` | host + NPU 协同负载（host 那一半） |
| `workloads/vortex_smoke/` | Vortex tap 验证用的裸机 rv32im 内核 |
| `workloads/three_source/` | 同时驱动两个设备的 host 负载，三源 trace 就是它产的 |
| `UPSTREAM.md` | 已验证的上游 commit、构建环境版本 |
| `docs/` | 设计文档，见下 |

三个 `*int/` 目录都是"装进上游树"的安装器，本仓库不 fork 任何一棵树。

## 文档

按这个顺序读：

1. [docs/01-address-map.md](docs/01-address-map.md) — 统一地址空间为什么长这样。三条硬约
   束，以及 SE 模式下 host 的物理页从哪来（最容易出事的一处）。
2. [docs/02-trace-format.md](docs/02-trace-format.md) — 记录格式、`level` 的含义、侧车
   meta、环境变量、分析工具。
3. [docs/03-limitations.md](docs/03-limitations.md) — **这些 trace 能回答什么、不能回答什
   么。** 三条腿各验证到哪一步。分析前必读。
4. [docs/04-integration.md](docs/04-integration.md) — 三棵树怎么接、补丁打不上怎么办、构
   建步骤与运行时的坑。

## 范围

做的：把异构系统跑起来，产出可归并的访存 trace。

不做的：闭环时序耦合（设备的访存延迟不反馈到 gem5，也不与 host 争用带宽）、DMA 背压、
cache 一致性、IOMMU。这些是有意划在外面的，不是待办事项 —— 时序留给下游的 DRAM 模拟器去
算，这也是 `hettrace convert` 存在的理由。

一句话版本的边界：**地址流可信，时间间隔不可信。**
