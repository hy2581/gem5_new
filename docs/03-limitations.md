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
| 与 host **共享字节**（不只是共享地址） | — | ✅ 含反向对照 | ✅ 见下 |
| 三源同时跑一遍、归并成一条流 | ✅ 见下 | | |

### host + CoralNPU：完整闭环，已验证

`gem5int/tests/run_het.sh` 四步全过。关键数字（一次实测）：host 1111 条记录（919 条
`host_heap` / 192 条 `shared_buffer`）、coralnpu 128 条（100% `shared_buffer`）、共享
cache line 8 条（`in[256B]` 4 条 + `out[256B]` 4 条）；NPU 的区间
`[145734000, 147392000]` 套在 host 的 `[2000, 152893000]` 里面，证明两边同一个
`curTick()`。反向对照 `--npu-no-share` 如期失败。

### host + Vortex：已验证，但走的是"中转"而不是"直接共享"

两个测试：

* `gem5int/tests/run_vortex.sh` —— 无 CPU 的单设备配置，验 tap 本身。5 个补丁干净地打
  进 Vortex 树，`libvortex-gem5.so` 带 tap 编得出来，三个 `vortex_gem5_trace_*` ABI 符号
  都在导出表里；gem5 能 dlopen 它、构造 `VortexGPGPU`、从事件队列推它的 `cycle()`；内核
  跑完并正常终止，tap 落出 **67 条记录**，`clock_period_ticks=1000`、`unmapped=0`、
  `non_monotonic=0`、`first_tick=70000`。
* `gem5int/tests/run_vortex_shared.sh` —— host + Vortex 的异构验收，用 Vortex 上游的
  `vecadd` 回归测试（`-n64`）。它走完整的 host runtime → CP → 核 路径，自检全部 64 个
  结果，所以 `PASSED!` 这一行本身就是字节真的共享了的功能性证据。一次实测：host 19422
  条（10134 `host_heap` / 9288 `vortex_bar`）、vortex 287 条（100% `vortex_bar`，其中
  CP DMA 268 条 + 核 19 条）、共享 cache line **110 条**，两源 `unmapped=0`、
  `non_monotonic=0`。

**但交接的形状与 CoralNPU 那条腿不一样**，这一点必须写清楚，否则会照着 CoralNPU 的直觉
去读 Vortex 的 trace：

CoralNPU 与 host 是**直接**共享 —— 两边访问同一段 gem5 内存（`shared_buffer`）里的同一
批字节。Vortex 不是。Vortex 的内存是设备内的 `simx::RAM`，host 只能经 BAR 摸到它，而且
host runtime 只往 BAR 顶部一个 **64 MiB 的暂存区**里写（`sw/runtime/gem5/vortex.cpp` 的
`GEM5_HOST_BASE = PIN_REGION_SIZE - GEM5_HOST_APERTURE`，即设备地址 `0xfc000000`）：命令
环、完成槽、以及每次 `mem_copy` 的数据都在那里。而内核用的缓冲由设备侧的分配器从
`ALLOC_BASE_ADDR` 往上发（实测在设备地址 `0x10000` 一带），`.vxbin` 装在 `0x80000000`。

**是 CP 把字节从暂存区搬到缓冲的。** 所以 host 的足迹和核的足迹本来就不相交 —— 把两边接
起来的是中间那一次搬运。

这件事踩过一次，值得记下来：CP 的 DMA 直接读写 `simx::RAM`，既不过 Vortex 的 cache 层级
也不过 `vortex::Memory`，所以挂在 `pre_send_hook` 上的 tap **完全看不见它**。当时的结果
是：计算正确（`PASSED!`）、trace 干净（`unmapped=0`、`non_monotonic=0`）、两份文件都在，
但共享 cache line = **0**。一份看起来毫无问题的 trace，会让下游得出"host 与 Vortex 没有
共享"的结论，而字节其实是共享的。补法是在 `CommandProcessor::Hooks::dram_{read,write}` 上
另接一路，打 `kFlagDma`（见 [02-trace-format.md](02-trace-format.md)）。这一路同时也补回
了设备内存流量里最大的一块：一次 vecadd 里 CP 搬了 17152 字节，核自己只出了 1216 字节。

顺带一个结构性结论：**Vortex 与 CoralNPU 之间不可能直接共享字节。** `vortex_bar` 必须落在
4 GiB 之上，而 CoralNPU 的 AXI 地址只有 32 位，连表达那个地址都做不到。要让它们交换数据，
只能由 host 做中转（读回 Vortex 的结果、再写进 `npu_work`）。理由见
[01-address-map.md](01-address-map.md) 的硬约束 1。

### 三源同时跑：已验证，但"并发度"这个词要小心

`gem5int/tests/run_three_source.sh` 五步全过，用的负载是
`workloads/three_source/host_main.cpp` —— 一个 host 程序同时驱动两个设备：先把 Vortex 的
活异步提交下去（**不等**），紧接着写 `NPU_CTRL` 启动 NPU。一次实测（整跑 14 秒）：

| 源 | 记录 | 字节 | 区间 (tick) | 区域 |
|---|---|---|---|---|
| host | 19486 | 717248 | `[1500, 2374683000]` | 51.5% `host_heap` / 47.5% `vortex_bar` / 1.0% `shared_buffer` |
| vortex | 279 | 17856 | `[2175760000, 2324172000]` | 100% `vortex_bar` |
| coralnpu | 128 | 1280 | `[2292498000, 2294156000]` | 100% `shared_buffer` |

两个交接同时成立：host ↔ coralnpu 共享 8 条 line（`shared_buffer` 里的 `in[]`+`out[]`），
host ↔ vortex 共享 106 条（`vortex_bar` 里 CP 搬运的那批）。coralnpu ↔ vortex 是 **0**，
而且测试把这个 0 当成**期望值**来判 —— 理由见下一段。归并出来是 19893 条按 tick 单调的单
流，源切换 76 次；NPU 那 1658000 tick 的活动期里三个源都有记录（coralnpu 128 / host 40 /
vortex 10），也就是说交错是真的交错，不是三段首尾相接。

**为什么要费劲让两个设备的区间重叠**：本项目的 trace 是喂给下游 DRAM 模拟器的输入。串成
`host -> Vortex -> host -> NPU` 一条链固然更像真实应用，但那样两个设备的区间必然不相交，
归并出来的流里永远不存在两源夹在一起的片段 —— 下游连"两个 master 同时压一个控制器"这件事
都构造不出来。`validate` 会把这个形状报成 WARN，它报得对。

**代价**：这个负载没有演示"Vortex 的结果流给 NPU"。那不是遗漏 —— 见上一节的结构性结论，
两个设备之间只能由 host 中转，而 host 中转就是那条串行链。两者不可兼得。

**"并发度"要看清楚是什么**：`stats` 会打一行"多源并发窗口 22 / 2375 (0.9%)"。这个比例低
不是负载没做到重叠，而是三件事叠出来的：

* NPU 只干 943 个 500MHz 周期（1.7 us），Vortex 那次 launch 是 148 us —— 两个设备本身的规
  模差了两个数量级，重叠区间最多也就是 NPU 那 1.7 us；
* host 等 NPU 的那段是在轮询 `npu_pio`，而 PIO 不在 trace 窗口里（见
  [02-trace-format.md](02-trace-format.md) 的 `trace_windows`），所以 host 在这段时间里
  "没有访存"；
* 窗口宽度默认 1 us，1.7 us 的重叠最多落进两个窗。

所以"三源同时跑"这件事成立（区间重叠、归并流里三源交错），但**不要**把 0.9% 当成"这套系
统的并发能力"。要提高这个数只有加大 NPU 侧的工作量，那要改 `ddr_touch.cc` 的内核，而它同
时是 `run_het.sh` 的判据内核，不该为了一个统计数字去动。

还有一条老限制在这里照旧成立：三个源共享一把时间尺子，但**不共享一条排队的通道**（本文档
第 1 条）。所以重叠区间里的"同时"是"同时发生"，不是"同时争用"。争用要下游模拟器去算。

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

### 两个看着像反向对照、其实不能用的（Vortex 腿）

都真跑过。记在这里，免得后人重走，也因为它们说明了一个更一般的问题。

**`--vortex-bar-skew 0x10000000`** —— 把设备声明的 BAR 区间挪开。因果上有效：host 拿不
到设备，跑到 `max_ticks` 也不会 `PASSED`。但**不能**拿共享 line 数当判据。host 访问的物
理地址是 `PIN_BASE + dev_addr`，由 `driver.h` 的 `constexpr` 决定，与 skew 无关；而 tap
记的是 `dev_addr' + PIN_BASE`，其中 `dev_addr'` 是 CP 从命令环里读到的设备地址，也与 skew
无关。两个数**数值上照样相等** —— 实测共享 line 数一点没降，尽管两边碰的根本不是同一批
字节。

**`--vortex-trace-dev-view`** —— 关掉 tap 的地址偏移，让它记设备内地址。用它判共享 line
数同样会被骗：设备内的 `.vxbin` 代码段在 `0x80000000`，正好撞上 host 私有堆 `host_heap`
的基址，于是量出 65 条"共享"，全是假的。所以 `run_vortex_shared.sh` 只用它判**区域归
属**（关掉偏移后记录必须跑进 `host_heap`、`vortex_bar` 里必须一条不剩），不判共享。

一般的结论：**两个源的地址集重合度，只有在两边都换算到同一个物理空间之后才有意义。**
"地址相等"和"字节相同"在多地址空间的系统里是两件事，而 footprint 这类指标分不出来 —— 它
看到的只是数。这就是 `het_system.py` 把 BAR 视角设成默认、而不是留给用户选的原因；也是
Vortex 腿的最终判据落在 `vecadd` 的自检（`PASSED!`）而不是落在共享 line 数上的原因。共享
line 数在那里是**辅助证据**，不是主证据。
