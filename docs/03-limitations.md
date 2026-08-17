# 这些 trace 能用来回答什么，不能用来回答什么

本项目的目标是"把异构系统跑起来并产出访存 trace"，不是建一个时序精确的异构平台。三个
tap 都是**只读观察者**：装上它们不改变任何一个仿真器的行为，所以 trace 里的地址流是可
信的，而任何依赖"访存需要多久"的量都不是。

这一份文档比其余三份都重要。地址错了会被 `validate` 抓出来；把"零延迟功能访问"的时间戳
当成真实内存延迟用，则会安安静静地得出一个漂亮而错误的数字。

## 能回答的

* **地址流与 footprint**：每个源碰过哪些地址、多少条 cache line、读写比例。
* **共享行为**：哪些区域被多个源访问，同一条 line 被谁碰过、按什么顺序。这是本项目的
  主要产出，`hettrace stats` 的"两两共享"就是它。
* **跨源交织顺序**：三份 trace 用同一个 `curTick()`，归并后跨源的先后关系是真的。
* **下游 DRAM 模拟器的输入**：`hettrace convert` 出来的地址+读写序列可以喂给 ramulator
  之类的模型，由那个模型去算时序。这是本项目预期的用法 —— 时序在下游算，不在这里。

## 不能回答的

### 1. 内存延迟与带宽争用（最重要的一条）

CoralNPU 的 AXI master 经 gem5 的 `physProxy` 做**功能访问**：零仿真时间、不进 xbar、不
排队、不占带宽。这不是偷懒，是被 AXI 回调的语义逼出来的 —— 读回调必须在被调用的同一个
周期里返回数据，而 gem5 的时序访问要等若干 tick 之后才回来。要做成时序访问就得让 AXI 通
道能背压、让 NPU 能停等，那是"闭环时序耦合"，明确在本项目范围之外。

后果：

* NPU 的周期数是**乐观**的（内存永远命中、永远零延迟）；
* host 与 NPU 的访存**互相不争用**，trace 里两者时间上的重叠不代表真实的争用；
* 任何"如果内存慢一点会怎样"的问题，这批 trace 答不了。

同理，host 侧的 CPU 时序**不受** NPU / Vortex 流量影响。三条腿在时间上共享一把尺子，但
不共享一条排队的通道。

### 2. 单条访问在 trace 里的时刻 ≠ 程序里执行的时刻

host tap 挂在 LLC 与 membus 之间（`level = kLevelPostLlc`），看到的是过了 cache 的流量：

* **cacheable 区域**（`host_heap`）：只有 miss 和 writeback 可见。一条 store 在 trace 里
  出现的时刻是那条 line 被**换出**的时刻，可能比 store 晚很多；命中 L1 的访问完全不可
  见。所以 `host_heap` 那部分记录是"DRAM 流量"，不是"程序访存行为"。
* **uncacheable 区域**（`shared_buffer` 等，见 [01-address-map.md](01-address-map.md)）：
  每笔访问逐一穿过探针，所以是逐笔可见、时刻也准。

这就是为什么共享区必须 uncacheable：不光是为了 NPU 能读到 host 写的字节，也让共享区那部
分 trace 变成可以逐笔分析的。代价是 host 侧访问共享区比正常内存慢。

Vortex 侧的 tap 同样在 cache 之后，同一个现象在那里表现得更极端：`run_vortex.sh` 的内核
写 64 个字、读 64 个字，落出来的 67 条记录**全部是读**，一条写都没有。原因是 Vortex 的
dcache 是 writeback 且内核结束前没有 flush，脏行始终没被换出；而 write-allocate 让每次写
miss 先产生一次读 —— 于是 64 次写在 trace 里的形态是 64 条读。这不是 bug，但它说明为什么
不能拿这类 trace 直接算读写比。

### 3. 三个源的 tap 层级不同，条数不能直接比

| 源 | level | 看到的是 |
|---|---|---|
| host | 0 `kLevelPostLlc` | L2 之后的 miss/writeback 流（uncacheable 区除外，见上） |
| vortex | 0 `kLevelPostLlc` | Vortex 自己 cache 层级过滤后的 miss 流 |
| coralnpu | 2 `kLevelAxiMaster` | AXI master 上的每一拍；**TCM 命中完全不可见** |

host 与 vortex 恰好在同一层（LLC 之后），所以这两者是可比的。CoralNPU 不是：TCM 命中根本
不到 AXI 端口，所以它的条数只反映出核的流量。一次典型的协同跑里 host 上千条、NPU 一百多
条，这个悬殊比例是层级差异加 TCM 过滤的结果，不是"NPU 访存少"。要比较必须先说清楚在比哪
一层。

`level` 写在每份 trace 的头里，正是为了让这件事在数据里可见而不是靠记性。

### 4. 同 tick 的跨源顺序是人为的

`merge` 按 `(tick, src_id, seq)` 稳定排序。同一个 tick 上来自不同源的记录，真实硬件里没
有确定的先后，排序结果只是**可复现**，不是**真实**。做逐条因果分析时要注意；做窗口统计
则无影响。

### 5. SE 模式：没有操作系统

host 跑在 gem5 的 SE 模式下，系统调用是仿真器模拟的，所以 trace 里**没有**内核代码、页
错误处理、TLB miss 引发的页表遍历、驱动程序的 MMIO 序列。真实系统里这些流量不小。选 SE
的理由是 FS 模式要引入内核、驱动和设备树，而本项目的问题（共享区上的数据交接）不需要它
们。

### 6. 没有 cache 一致性，共享靠约定

host 的 cache 与两个设备之间没有任何一致性协议。共享区靠"映射成 uncacheable"绕开问题。
所以：

* 这批 trace 里**不会**出现一致性流量（invalidate、snoop、share/upgrade）；
* 换成 cacheable 共享区不是"慢一点"而是**会算错**，这是配置的硬约束，不是调优选项。

### 7. 没有 IOMMU / 地址翻译

设备用的是物理地址，host 侧靠恒等映射（VA == PA）看到同一段。真实平台上会有 IOMMU 翻译
和相应的页表流量，这里一概没有。

## 三条腿各验证到了哪一步

这一节说清楚每条腿"验到哪儿"，因为三条腿的成熟度不一样，混着说会误导。

| | host | CoralNPU | Vortex |
|---|---|---|---|
| 库/设备能在 gem5 里构造 | ✅ | ✅ | ✅ |
| tap 产出记录、时间戳来自 `curTick()` | ✅ | ✅ | ✅ |
| `clock_period_ticks` 与配置一致 | ✅ 500 | ✅ 2000 | ✅ 1000 |
| `unmapped` / `non_monotonic` 为 0 | ✅ | ✅ | ✅ |
| 与 host **共享字节**（不只是共享地址） | — | ✅ 含反向对照 | ❌ 未验证 |
| 三源同时跑一遍 | ❌ 未验证 | | |

### host + CoralNPU：完整闭环，已验证

`gem5int/tests/run_het.sh` 四步全过。关键数字（一次实测）：host 1111 条记录（919 条
`host_heap` / 192 条 `shared_buffer`）、coralnpu 128 条（100% `shared_buffer`）、共享
cache line 8 条（`in[256B]` 4 条 + `out[256B]` 4 条）；NPU 的区间
`[145734000, 147392000]` 套在 host 的 `[2000, 152893000]` 里面，证明两边同一个
`curTick()`。反向对照 `--npu-no-share` 如期失败。

### Vortex：tap 已通电，协同未验证

已验证（`gem5int/tests/run_vortex.sh`，无 CPU 的单设备配置）：

* 5 个补丁干净地打进 Vortex 树，`libvortex-gem5.so` 带 tap 编得出来，三个
  `vortex_gem5_trace_*` ABI 符号都在导出表里；
* gem5 能 dlopen 它、构造 `VortexGPGPU`、从事件队列推它的 `cycle()`；
* 内核跑完并正常终止，tap 落出 **67 条记录**，`clock_period_ticks=1000`、
  `unmapped=0`、`non_monotonic=0`、`first_tick=70000`，时间戳确实来自 gem5。

**未验证**：host 与 Vortex 之间的字节共享。原因是本机没有 Vortex 的 LLVM 工具链
（`llvm-vortex` + `libc32` + `libcrt32`），编不出正常的 `.vxbin`；而 host ↔ Vortex 的数据
交接必须走 CP 的 `mem_upload` + `CMD_DCR_*` 路径，那条路要求真正的 `.vxbin` 内核。
`run_vortex.sh` 用的是手写的裸机 rv32im 平坦镜像（`workloads/vortex_smoke/kernel.S`），
它只在设备内部地址空间里读写，够验证 tap，不够验证共享。

于是 Vortex 腿在 `het_system.py` 里的接线（`pin_addr` 覆盖成 `0xa0000000`、pio 与 dma 都
接到 membus）是**代码完备但未跑过**的。补齐的路径见
[04-integration.md](04-integration.md)："装 Vortex 工具链"那一节。

### 三源同时跑：未做

现有的两个测试是"host + CoralNPU"和"Vortex 单跑"。三个源在同一次仿真里同时产 trace 没有
跑过。归并工具本身不关心源的个数（`validate` / `stats` 都按目录里发现的文件工作），所以
这更像是差一个能同时喂三条腿的负载，而不是差机制。

## 反向对照：为什么正向跑通不算证据

`run_het.sh` 的第 4 步是本项目里最值得复用的一条方法论。

`--npu-no-share` 让 NPU 的 AXI master 回落到设备库内部的私有 DDR 数组。这时候：地址一模
一样、trace 照样产出、条数区域分布全都正常、`validate` 通过 —— 看起来完全对。唯一不对的
是 host 校验和：NPU 读的是另一块内存里的零。

也就是说，正向那一遍单独看，**无法区分**"真的共享了字节"和"两边各自碰了同样的地址"。只
有让共享故意失效、并确认 host 的自检**真的失败**，正向那一遍的结论才成立。测试还进一步
要求失败原因必须是数据不符（`host: 错误 —— NPU 算的校验和` 或 `out[...]`），而不是崩了
或别的什么 —— 否则就是换了个理由通过，等于没测。

同样的思路也用在单设备验收 `run_gem5_npu.sh` 的最后一步：把 `shared_buffer` 的内存控制
器从配置里挪走，gem5 必须 fatal —— 这证明 NPU 的访存真的落在 gem5 的内存上，而不是被别
的什么东西接了。两个测试里的反向对照针对的是两种不同的假通过，都不能省。
