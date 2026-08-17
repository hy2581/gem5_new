# 统一物理地址空间

三个仿真器各有自己的一套地址概念：gem5 有真正的物理地址空间，Vortex SimX 里的
`simx::RAM` 是一块进程内数组，CoralNPU 的 Verilator 模型只认 32 位 AXI 地址。要让三
份 trace 能放在一起分析，必须先让这三套地址落在同一张图上 —— 这张图就是仓库根目录的
`addrmap.json`，本文件解释它为什么长这样。

## 真值源与生成物

```
addrmap.json                       <- 唯一手写的地方
  |
  +-- scripts/gen_addrmap.py
        |
        +-- libhettrace/include/hettrace/addrmap.h    (C++，三个 tap 都 include)
        +-- tools/hettrace/addrmap.py                 (Python，分析工具用)
```

改完 `addrmap.json` 必须重新生成，否则 C++ 侧和 Python 侧对"哪个地址属于哪个区域"的判
断会不一致：

```bash
python3 scripts/gen_addrmap.py            # 重新生成
python3 scripts/gen_addrmap.py --check    # 只校验是否过期，CI 用
```

配置脚本（`gem5int/configs/het/*.py`）里的地址是**手抄**的常量，不是 import 来的 ——
gem5 的配置脚本跑在 gem5 自带的 python 解释器里，`sys.path` 和工作目录都不受本项目控
制。抄错的后果是可观测的：trace 里会出现 `unmapped` 记录，`hettrace validate` 直接报
出来，而不是静默算错。

## 区域表

| 区域 | 基址 | 大小 | 类型 | 谁访问 | gem5 里谁持有 |
|---|---|---|---|---|---|
| `boot_rom` | `0x00000000` | 256 MiB | rom | — | 无（预留） |
| `npu_slave` | `0x10000000` | 256 MiB | mmio | host | 无（见下） |
| `vortex_cp` | `0x20000000` | 512 B | mmio | host | `VortexGPGPU.pio` |
| `npu_pio` | `0x30000000` | 4 KiB | mmio | host | `CoralNPU.pio` |
| `host_heap` | `0x80000000` | 256 MiB | dram | host | `system.host_mem` |
| `shared_buffer` | `0x90000000` | 256 MiB | dram | host + vortex + coralnpu | `system.shared_mem` |
| `vortex_vram` | `0xa0000000` | 256 MiB | dram | host + vortex | `VortexGPGPU`（BAR） |
| `npu_work` | `0xb0000000` | 256 MiB | dram | host + coralnpu | `system.npu_work_mem` |
| `npu_mailbox` | `0xc0000000` | 16 B | mmio | host + coralnpu | 无（见下） |

两个"gem5 里没人持有"的区域不是遗漏：

* `npu_slave` 是 CoralNPU 设备库**内部**的 AXI slave 窗口（host 经它写 TCM、置起始
  PC）。本项目不从 gem5 走这条路：内核由 `CoralNPU.kernel` 参数在 `startup()` 里用
  库自己的 `load_elf` 装进去，因为 AXI slave 路径是阻塞的、会自己推 CoralNPU 的时
  钟，仿真跑起来之后再用就会破坏"时钟只由 gem5 推"这条不变量。它留在地址图里是为了
  说明那块地址已经被占了，别拿去做别的用途。
* `npu_mailbox` 是 4×u32 寄存器，物理上在设备库里面。NPU 对它的 AXI 访问被 RTL 收进
  寄存器，压根没出核，所以 gem5 这边不需要内存去接。host 读它走的是 `npu_pio` 的
  `REG_MAILBOX0..3`。

## 三条硬约束

**1. 一切 NPU 会碰的地址必须在 4 GiB 以内。** CoralNPU 的 AXI 地址是 32 位的
（`hw_sim/hw_primitives.h` 里 `AxiAddr::addr_bits_addr` 是 `uint32_t`）。这条直接否掉了
Vortex `VortexGPGPU.py` 里 `pin_addr` 的默认值 `0x100000000` —— 上游把 VRAM 放到 4 GiB
之上是为了躲开被仿真进程的低位虚拟地址布局，但那样 NPU 连表达这个地址都做不到。所以
`het_system.py` 必须显式把 `pin_addr` 覆盖成 `0xa0000000`。

**2. 四段 dram 区域必须落在 `[0x80000000, 0xc0000000)` 里。** 这是 CoralNPU 参考实现
`IsDdrAddress()` 的判定区间；落在里面的 AXI master 访问才会被路由到 DDR（也就是本项目
接到 gem5 内存上的那条路），落在外面的会被当作 mailbox 寄存器访问。`npu_mailbox` 被放
在 `0xc0000000`（区间的上界，即区间之外）不是巧合，就是为了让"窗口外"这个条件自然成立
而不用改 RTL。

**3. `vortex_vram` 不能被 gem5 的内存控制器覆盖。** 那段地址由 `VortexGPGPU` 设备自己
声明（BAR 映射到设备内的 `simx::RAM`）。如果 gem5 也挂一个内存控制器上去，xbar 会因为
两个 responder 声明同一段地址而 fatal。这就是 `het_system.py` 里挂了三个独立
`SimpleMemory` 而不是一段连续 1 GiB 的原因 —— 中间那 256 MiB 必须留给设备。

## SE 模式下 host 的物理页从哪来

这是最容易出事的一处，值得单独说。

gem5 SE 模式下被仿真进程的物理页由 `SEWorkload` 的页池分配。页池不是从
`system.mem_ranges` 来的，而是从**所有 `conf_table_reported=True` 的内存**来的
（`SEWorkload::setSystem` → `PhysicalMemory::getConfAddrRanges` →
`MemPools::populate`），并且 `allocPhysPages` 默认只用 pool 0，也就是地址最低的那段。

所以 `het_system.py` 里：

```python
system.host_mem     = SimpleMemory(range=..., conf_table_reported=True)   # 唯一进页池的
system.shared_mem   = SimpleMemory(range=..., conf_table_reported=False)
system.npu_work_mem = SimpleMemory(range=..., conf_table_reported=False)
```

于是进程的代码/堆/栈只可能落在 `[0x80000000, 0x90000000)`，**永远不会**被分配到
`shared_buffer` 里去。不这么做的话，进程多占几页就会悄悄踩进交接区，而 trace 上看起来
只是"host 也访问了 shared_buffer"，完全看不出是踩坏了 —— 一个能出正确数字的错误配置，
比一个跑不起来的配置危险得多。

host 访问共享区靠的是显式的恒等映射，与页池无关：

```python
process.map(0x90000000, 0x90000000, size, cacheable=False)   # VA == PA
```

`cacheable=False` 不是保守，是必需的。NPU 经 `physProxy`（functional 访问）读共享区，而
functional 访问不保证能把 CPU cache 里的脏行捞出来；host 写的新值留在 cache 里，NPU 读
到的就是旧值。设成 uncacheable 直接绕开整个问题，代价是 host 侧慢一点。副作用是好的：
uncacheable 的写会逐笔穿过 LLC 之下的探针，于是 host 对共享区的每一次写都出现在 trace
里 —— 见 [03-limitations.md](03-limitations.md) 里关于"写记录只在换出时出现"的那一节。

## 时钟

| 源 | 频率 | tick/周期 | 在哪配 |
|---|---|---|---|
| host | 2 GHz | 500 | `het_system.py` 的 `HOST_CLOCK` |
| vortex | 1 GHz | 1000 | `het_system.py` 的 `VORTEX_CLOCK` |
| coralnpu | 500 MHz | 2000 | `het_system.py` 的 `NPU_CLOCK` |

gem5 的 Tick 是 1 ps（`ticks_per_second = 1e12`），三个频率都写在 `addrmap.json` 的
`sources[].clock_mhz` 里，由 `gen_addrmap.py` 折算成 `kClockPeriodTicks_*` 供各 tap 写
进 trace 头。测试脚本会核对这个数（比如 NPU 必须是 2000）：对不上说明设备的
`clk_domain` 没生效，或者一次 gem5 事件推了不止一个设备周期。
