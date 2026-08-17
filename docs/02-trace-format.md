# trace 格式与工具链

## 一句话

每个源写自己的一个文件，格式相同（64 字节头 + 32 字节定长记录），时间戳全部是
gem5 的 `curTick()`；归并、统计、格式转换全在离线的 Python 工具里做。

## 为什么每源一个文件，而不是一个交织的大文件

三个源跑在三个不同的时钟域上，并且在一次 gem5 事件里可能连续产出多条记录。如果三个
tap 往同一个 fd 里追加，写入顺序是"谁的回调先被调用"，而不是 tick 顺序 —— 得到的文件
会是"大体有序、局部乱序"，这是最难处理的一种数据：看起来能直接用，实际上任何按时间的
窗口统计都会偏。

而且这个错误是**不可恢复**的：一旦交织写进去，就没有信息能把它排回来（`seq` 只在源内
单调）。分成三个文件、由离线工具做稳定归并，则排序错误在任何时候都能重做。代价是多两
个文件和一次归并，很便宜。

## 二进制布局

`libhettrace/include/hettrace/record.h` 是真值源，下面是它的内容摘要。小端，
`#pragma pack(1)`，`static_assert` 钉住两个尺寸。

### 文件头（64 字节）

| 偏移 | 字段 | 类型 | 说明 |
|---|---|---|---|
| 0 | `magic` | `char[8]` | `"HETTRC\0\1"` |
| 8 | `version` | `u32` | 当前 1 |
| 12 | `record_size` | `u32` | 32；读侧据此拒绝不匹配的文件 |
| 16 | `ticks_per_second` | `u64` | `1e12`（gem5 的 Tick = 1 ps） |
| 24 | `clock_period_ticks` | `u64` | 本源一个时钟周期 = 多少 tick |
| 32 | `src_id` | `u16` | 见 `addrmap.h` 的 `SrcId` |
| 34 | `level` | `u8` | tap 挂的位置，见下 |
| 35 | `flags` | `u8` | bit0 = 只记了 DRAM 窗口（`kHdrFilteredDram`） |
| 36 | `name` | `char[28]` | 源名，NUL 补齐 |

把 `clock_period_ticks` 写进头里而不是让分析工具去查表，是为了让 trace **自描述**：一
份 trace 拿到任何地方都能自己换算成周期数，不需要同时拿到当初的配置脚本。这也给了测试
一个廉价的断言点 —— NPU 的这个字段必须是 2000，对不上就说明 `clk_domain` 没生效。

### 记录（32 字节）

| 偏移 | 字段 | 类型 | 说明 |
|---|---|---|---|
| 0 | `tick` | `u64` | 全局 tick，**不是**源内周期数 |
| 8 | `addr` | `u64` | 统一物理地址 |
| 16 | `size` | `u32` | 字节数 |
| 20 | `ctx` | `u32` | 源内上下文：host = `requestorId`，vortex = `hart_id`，npu = AXI id |
| 24 | `seq` | `u32` | 源内单调序号 |
| 28 | `src_id` | `u16` | 与头里相同，便于归并后单条记录仍可自识别 |
| 30 | `op` | `u8` | 0 = 读，1 = 写 |
| 31 | `flags` | `u8` | 见下 |

`seq` 有两个用途：归并时同 tick 的稳定排序，以及**检测丢记录** —— 侧车 meta 里的
`emitted` 与文件里实际条数、以及 `seq` 的连续性一起，能查出"进程被杀、缓冲没刷出"这种
悄悄截断的 trace。

记录 flags：

| 位 | 名字 | 意思 |
|---|---|---|
| 0 | `kFlagBurstBeat` | AXI burst 的非首拍（首拍不带此位） |
| 1 | `kFlagPrefetch` | 预取/推测访问，非程序序 |
| 2 | `kFlagUnmapped` | 地址不在 `addrmap.json` 任何区域内 |
| 3 | `kFlagInstr` | 取指流量 |
| 4 | `kFlagDma` | 搬运引擎发出的，不是核发出的 |

`kFlagUnmapped` 是**保留记录并打标**，不是丢弃。地址算错是配置问题，把证据留在 trace
里比静默丢掉有用得多；`validate` 会把它变成一条 ERROR。

`kFlagDma` 目前只有 Vortex 那一路在用（CP 在暂存区与设备缓冲之间的中转，见
[03-limitations.md](03-limitations.md)）。它必须能被分出来，因为两类分析对它的处置正好
相反：分析**核的访存行为**（局部性、cache 效果、per-hart 足迹）要把它排掉，它不经过任何
cache、也不属于任何 hart；算**DRAM 带宽**则不能排，它是真实占用的流量，一次 vecadd 里
它比核自己出的流量还多一个量级。带这个位的记录 `ctx` 固定为 `0xffffffff`（Vortex 侧的
`kDmaCtx`）而不是 0 —— 用 0 会让 DMA 混进 hart 0 的足迹里。

### AXI burst 的展开

CoralNPU 的 master 回调按拍触发，但每拍携带的 `AxiAddr` 都是整笔事务的**首地址**
（`hw_primitives.h` 里 `AxiMasterWriteDriver::OnFallingEdge` 每拍都用同一个
`axi_addr_`）。直接按拍记就会得到 N 条同地址记录，局部性统计彻底失真。
`TraceWriter::EmitBurst()` 按 AXI4 INCR 语义展开成 `len+1` 拍，首拍地址为 base、其余
`base + i*(1<<size)`，非首拍打上 `kFlagBurstBeat`。想只看事务不看拍，过滤掉带这个位的
记录即可 —— 信息两边都在。

## 源与挂载层级（`src_id` / `level`）

`addrmap.h` 里的两个枚举，是这两个字段的真值源：

| `src_id` | 源 | | `level` | 层级 |
|---|---|---|---|---|
| 0 | `kSrcHost` | | 0 | `kLevelPostLlc` |
| 1 | `kSrcVortex` | | 1 | `kLevelPreCache` |
| 2 | `kSrcCoralnpu` | | 2 | `kLevelAxiMaster` |

三个 tap 实际用的是：

| 源 | src_id | level | 挂点 |
|---|---|---|---|
| host | 0 | 0 `kLevelPostLlc` | L2 与 membus 之间的 `CommMonitor` |
| vortex | 1 | 0 `kLevelPostLlc` | `vortex::Memory` 的 `pre_send_hook`（核出核的流量）**加上** `CommandProcessor::Hooks::dram_{read,write}`（CP 的 DMA，打 `kFlagDma`） |
| coralnpu | 2 | 2 `kLevelAxiMaster` | 设备的 AXI master 端口 |

host 与 vortex 恰好都是"LLC 之后、DRAM 之前"，所以两者的记录是可比的。CoralNPU 不同：
AXI master 是设备端口，TCM 命中根本不到那里，所以它的条数与另外两个源不在一个量纲上。
把 level 写进文件头，是为了让这件事在数据里就能看出来，而不是靠读文档记住。具体后果见
[03-limitations.md](03-limitations.md)。

## 文本模式

`HETTRACE_FORMAT=text` 写出人读格式，字段与二进制一一对应：

```
# hettrace v1 text
# src_id=0 name=host level=0
# ticks_per_second=1000000000000 clock_period_ticks=500
# filter=dram
# tick src op addr size ctx seq flags
2000 0 W 0x90000000 64 0 0 0x00
```

调试时用它，正式跑用二进制 —— 文本大约是二进制的 1.5 倍且解析慢，但更重要的是文本模式
下 `size`/`flags` 的十六进制/十进制混排容易看错，不适合做定量分析的输入。

## 侧车 meta.json

每份 trace 关闭时写一个 `<file>.meta.json`，内容是 `Stats` 的全部字段加上头里的元信息：

```json
{
  "src_id": 2, "name": "coralnpu", "level": 2,
  "format": "bin", "filter": "dram",
  "ticks_per_second": 1000000000000, "clock_period_ticks": 2000,
  "emitted": 128, "filtered": 0, "unmapped": 0, "non_monotonic": 0,
  "bytes": 8192, "first_tick": 145734000, "last_tick": 147392000
}
```

计数器的值本身就是判据，测试脚本读它而不是 grep 报告文本：

* `emitted == 0` → tap 没接上；
* `unmapped > 0` → 配置脚本里的地址和 `addrmap.json` 不一致；
* `non_monotonic > 0` → 时间基准接错了（比如设备库自己数周期而没用 `curTick()`）；
* `filtered` 大而 `emitted` 小 → 流量基本没出核（NPU 全打在 TCM 上）。

`first_tick` / `last_tick` 还支撑一条只有异构系统里才成立的断言：NPU 是 host 写
`REG_CTRL` 之后才启动、host 一直轮询到它停下，所以 NPU 的整个区间必须**套在** host 的
区间里面。`run_het.sh` 检查这一条，它是"两边用的是同一个 `curTick()`"的直接证据。

## 环境变量

写出行为全部由环境变量控制，配置脚本里不出现输出路径 —— 三个 tap 分属三套构建系统，让
它们各自透传一路选项不现实。

| 变量 | 默认 | 说明 |
|---|---|---|
| `HETTRACE_DIR` | 未设置 | 输出目录。**未设置 = 完全关闭**，不是错误 |
| `HETTRACE_FORMAT` | `bin` | `bin` \| `text` |
| `HETTRACE_FILTER` | `dram` | `dram` 只留 `trace_windows` 里的地址；`all` 全留 |
| `HETTRACE_BUFSZ` | `65536` | 缓冲记录条数 |

`dram` 这个名字是历史的，判据是 `IsTraced()` 而**不是** `IsDram()`：窗口是
`dram_window` ∪ `vortex_bar`，比 CoralNPU 的 DDR 判定区间多一段。为什么要多这一段、以及
少了它会静默丢掉什么，见 [01-address-map.md](01-address-map.md) 的"过滤窗口"一节。

"未设置就关闭"这条约定让 tap 可以永远编进去：`trace_enable` 这类参数只决定**要不要
装** tap，装了也不一定产文件。于是一个没有 hettrace 的旧设备库、和一个没设
`HETTRACE_DIR` 的正常跑，行为一致 —— 都是安静地不产 trace。

## 工具

```bash
export PYTHONPATH=/path/to/zhongxing/tools

python3 -m hettrace validate $DIR          # 这批 trace 能不能用来分析
python3 -m hettrace stats    $DIR          # 带宽 / footprint / 共享度
python3 -m hettrace merge    $DIR -o all.txt
python3 -m hettrace dump     $DIR/host.hettrace -n 50
python3 -m hettrace convert  $DIR --preset readwrite -o ram.trace
```

`validate` 分三档输出：**ERROR** = 不可用于分析，必须修；**WARN** = 可用但结论有边界，
必须写进报告；**INFO** = 值得注意的观察（比如"共享区 shared_buffer 被 host, coralnpu 共
同访问"）。退出码非 0 只在有 ERROR 时。这个三分法是有意的 —— 把"结论受限"和"数据不可
用"混成一个布尔值，会逼着人要么忽略警告要么无法交付。

`stats` 里的**共享 line 数**是"协同真的发生了"的定量证据：同一条 64 B line 被两个源都
碰过。`--line` 可以改 line 大小，`--window` 改带宽统计窗口（默认 1e6 tick = 1 µs）。

`convert` 的目标格式随下游模拟器版本变，所以给了预设加自由 `--template`（可用字段
`tick/addr/size/ctx/seq/src/rw/op`）：

| 预设 | 样例 | 备注 |
|---|---|---|
| `readwrite` | `0x90000040 R` | 十六进制地址 + R/W，无时间戳 |
| `dec_readwrite` | `2415919168 R` | 十进制地址 + R/W，无时间戳 |
| `timed` | `1000 1 R 0x90000040 64` | 带 tick 与源 id，信息无损 |

用 `readwrite` 这类无时间戳格式时，注意跨源的**交织顺序**保留了（顺序来自按全局 tick 的
归并），但**间隔**丢了 —— 下游模拟器会按自己的节奏发请求。这一点连同
[03-limitations.md](03-limitations.md) 里的反馈缺失，共同构成结论的适用边界。
