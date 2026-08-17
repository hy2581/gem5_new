# 异构系统 gem5 配置 —— host CPU + CoralNPU + Vortex，三方共享同一段物理内存。
#
#   HETTRACE_DIR=/tmp/t $GEM5_HOME/build/X86/gem5.opt \
#       $GEM5_HOME/configs/het/het_system.py \
#       --cmd   <host x86 可执行文件> \
#       --npu-library    <libcoralnpu-gem5.so> --npu-kernel <xx.elf> \
#       --vortex-library <libvortex-gem5.so>
#
# 两个加速器都是**可选**的：只给 --cmd 就是纯 host 系统（用来单独验 host tap），
# 加上 --npu-* 就是 host+NPU，再加 --vortex-* 才是完整三方。分阶段开是刻意的 ——
# 三个 trace 一起出问题时，能一条腿一条腿地关掉去定位。
#
# 与 coralnpu_only.py 的分工：那个没有 CPU，验的是"gem5 能不能自己把 NPU 跑起来"；
# 这个有 host，验的是"三方能不能看见同一段内存、三份 trace 能不能对齐到同一时间轴"。
#
# ---- 三个 tap 分别在哪 ----
#   host     configs 里的 system.monitor.trace (HetTraceProbe)，挂在 L2 与 membus
#            之间的 CommMonitor 上 —— 记的是穿过 LLC 打到内存的流量，与
#            addrmap.json 里 host 的 level=post_llc 对应。
#   vortex   在 libvortex-gem5.so 里面（Vortex 树里的 tap）。
#   coralnpu 在 libcoralnpu-gem5.so 里面（AXI master 回调处）。
# 三者的时间戳都来自 gem5 的 curTick()：host tap 直接调，两个设备库靠 gem5 注入的
# curTick trampoline。所以 hettrace merge 才能把它们排到一条轴上。

import argparse
import os
import shlex

import m5
from m5.objects import (
    AddrRange,
    AtomicSimpleCPU,
    Cache,
    CommMonitor,
    HetTraceProbe,
    L2XBar,
    Process,
    Root,
    SEWorkload,
    SimpleMemory,
    SrcClockDomain,
    System,
    SystemXBar,
    VoltageDomain,
)

# ---------------------------------------------------------------------------
# 地址映射：与 addrmap.json 逐字对应（(base, size)）。
#
# 这里写死而不去 import 本项目的 tools/hettrace/addrmap.py：配置脚本跑在 gem5 自带
# 的 python 解释器里，sys.path 和工作目录都不受本项目控制。对不上的后果是可观测的
# —— trace 里会出现 unmapped 记录，hettrace validate 直接报出来。
# ---------------------------------------------------------------------------
HOST_HEAP     = (0x80000000, 0x10000000)  # host 私有：代码/堆/栈的物理页都从这出
SHARED_BUFFER = (0x90000000, 0x10000000)  # 三方交接区
VORTEX_VRAM   = (0xA0000000, 0x10000000)  # Vortex 设备自己持有（BAR），不是 gem5 内存
NPU_WORK      = (0xB0000000, 0x10000000)  # NPU 工作区，host 预置权重
NPU_PIO       = (0x30000000, 0x00001000)  # CoralNPU SimObject 的寄存器窗口
VORTEX_CP     = (0x20000000, 0x00000200)  # Vortex CP 寄存器堆

PAGE = 0x1000

HOST_CLOCK   = "2GHz"    # = addrmap.json 里 host 的 clock_mhz 2000
VORTEX_CLOCK = "1GHz"    # = vortex 的 clock_mhz 1000
NPU_CLOCK    = "500MHz"  # = coralnpu 的 clock_mhz 500


# ---------------------------------------------------------------------------
# Cache 层次。gem5 没有自带这几个类，各家配置脚本都是自己定义的；这里给一份最小
# 的、够用的。数值不追求对标某颗真实芯片 —— 本项目要的是"有一层 LLC，其下的流量
# 可观测"，尺寸只影响 trace 的条数，不影响正确性。
# ---------------------------------------------------------------------------
class L1Cache(Cache):
    assoc = 8
    tag_latency = 1
    data_latency = 1
    response_latency = 1
    mshrs = 16
    tgts_per_mshr = 20


class L1ICache(L1Cache):
    size = "32KiB"
    is_read_only = True
    writeback_clean = True


class L1DCache(L1Cache):
    size = "32KiB"


class L2Cache(Cache):
    size = "1MiB"
    assoc = 16
    tag_latency = 10
    data_latency = 10
    response_latency = 10
    mshrs = 32
    tgts_per_mshr = 12
    write_buffers = 16


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cmd", required=True,
                    help="host 侧 x86 可执行文件（SE 模式，静态或动态都行）")
    ap.add_argument("--options", default="",
                    help="传给它的参数，按 shell 规则分词。值以 - 开头时必须写成"
                         " --options=-x 的形式，否则 argparse 把它当成新选项")
    ap.add_argument("--env", action="append", default=[],
                    help="KEY=VAL，可重复。被仿真进程的环境变量")

    ap.add_argument("--npu-library", default="",
                    help="libcoralnpu-gem5.so；不给就不实例化 CoralNPU")
    ap.add_argument("--npu-kernel", default="",
                    help="NPU 上跑的 RISC-V ELF。给了但不 --npu-auto-start 的话，"
                         "由 host 写 NPU_PIO+0x00 的 bit0 启动")
    ap.add_argument("--npu-auto-start", action="store_true",
                    help="startup() 里就启动 NPU，不等 host 按启动键")
    ap.add_argument("--npu-no-share", action="store_true",
                    help="反向对照用：让 NPU 的 AXI master 回落到设备库内部的私有 "
                         "DDR 数组。地址还是那些地址，但数据不再共享，协同负载的"
                         "校验和必须因此对不上。加这个开关就是为了能主动制造出"
                         "'共享是假的'那种情况，证明正向那一遍不是碰巧过的")

    ap.add_argument("--vortex-library", default="",
                    help="libvortex-gem5.so；不给就不实例化 VortexGPGPU")
    ap.add_argument("--vortex-kernel", default="",
                    help="预载到设备里的 .vxbin。走 host runtime 提交的话留空")
    ap.add_argument("--vortex-host-rt-dir", default="",
                    help="含 libvortex.so 与 libvortex-gem5-x86_64.so 的目录；"
                         "给了就自动补 LD_LIBRARY_PATH 与 VORTEX_DRIVER")

    ap.add_argument("--num-cpus", type=int, default=4,
                    help="CPU 线程上下文数。Vortex 的 host runtime 会起工作线程，"
                         "SE 模式下 clone() 需要空闲上下文，所以默认给 4")
    ap.add_argument("--max-ticks", type=int, default=int(1e11),
                    help="兜底上限（默认 100ms）。到了上限退出码非 0")
    ap.add_argument("--no-host-trace", action="store_true",
                    help="不装 host tap。用来分离'系统跑不起来'和'trace 写不出'")
    ap.add_argument("--host-trace-inst", action="store_true",
                    help="把 host 取指流量也记进 trace。默认不记：条数会翻好几倍，"
                         "而共享内存分析根本用不到它")
    return ap.parse_args()


def build_memories(system):
    """给 gem5 这边真正持有的三段 DRAM 各挂一个内存控制器。

    为什么分成三个而不是一段连续的 [0x80000000, 0xc0000000)：中间的
    vortex_vram (0xa0000000) 由 VortexGPGPU 设备自己持有（BAR 映射到设备内的
    simx::RAM），gem5 内存不能覆盖它，否则 xbar 会因为两个 responder 声明同一段
    地址而 fatal。

    conf_table_reported 是这里的关键开关，它决定一段内存是否进 SE 模式的物理页
    池（SEWorkload::setSystem -> MemPools::populate 只收 conf-reported 的段）。
    只有 host_heap 报上去，于是被仿真进程的代码/堆/栈物理页只可能落在
    [0x80000000, 0x90000000)，**永远不会**被分配到 shared_buffer 里去。不这么做的
    话，进程一多占几页就悄悄踩进交接区，而 trace 上看起来就只是"host 也访问了
    shared_buffer"，完全看不出是踩坏了。

    另外 MemPools::allocPhysPages 默认只用 pool 0，也就是地址最低的那段
    conf-reported 内存 —— host_heap 的 0x80000000 正好是最低的。

    用 SimpleMemory 而不是 MemCtrl+DDR3：本配置是 atomic 模式，DRAM 时序对结果
    没有影响，而 DDR3_1600_8x8 的器件容量对不上这里的区间大小会一直 warn。
    """
    system.host_mem = SimpleMemory(
        range=AddrRange(HOST_HEAP[0], size=HOST_HEAP[1]),
        conf_table_reported=True,
    )
    system.shared_mem = SimpleMemory(
        range=AddrRange(SHARED_BUFFER[0], size=SHARED_BUFFER[1]),
        conf_table_reported=False,
    )
    system.npu_work_mem = SimpleMemory(
        range=AddrRange(NPU_WORK[0], size=NPU_WORK[1]),
        conf_table_reported=False,
    )
    for mem in (system.host_mem, system.shared_mem, system.npu_work_mem):
        mem.port = system.membus.mem_side_ports

    # mem_ranges 在 SE 模式下是给别人看的说明；真正的路由靠每个 responder 自己
    # 声明的区间。这里只列 host_heap：SEWorkload 拿的是 physmem 的 conf 区间，
    # 不是这个列表，写全了反而容易让人以为改这里就能改页池。
    system.mem_ranges = [AddrRange(HOST_HEAP[0], size=HOST_HEAP[1])]


def build_cpus(system, args, process):
    system.cpu = [AtomicSimpleCPU(cpu_id=i) for i in range(args.num_cpus)]
    system.multi_thread = args.num_cpus > 1
    system.l2bus = L2XBar()

    for i, cpu in enumerate(system.cpu):
        cpu.icache = L1ICache()
        cpu.dcache = L1DCache()
        cpu.icache.cpu_side = cpu.icache_port
        cpu.dcache.cpu_side = cpu.dcache_port
        cpu.icache.mem_side = system.l2bus.cpu_side_ports
        cpu.dcache.mem_side = system.l2bus.cpu_side_ports

        cpu.createInterruptController()
        # x86 的 InterruptController 有自己的 pio/int_requestor/int_responder，
        # 不接到 membus 上 gem5 会在 instantiate() 阶段就报未连接的 port。
        cpu.interrupts[0].pio = system.membus.mem_side_ports
        cpu.interrupts[0].int_requestor = system.membus.cpu_side_ports
        cpu.interrupts[0].int_responder = system.membus.mem_side_ports

        # SE 模式下每个 CPU 都要有 workload；除 cpu[0] 外都停着，等 clone() 找上来。
        cpu.workload = process
        cpu.createThreads()

    system.l2cache = L2Cache()
    system.l2cache.cpu_side = system.l2bus.mem_side_ports

    # ---- host tap 的挂点 ----
    # CommMonitor 是 gem5 里唯一注册 "PktRequest" 探针点的对象（见
    # src/mem/comm_monitor.cc 里 ppPktReq），BaseMemProbe 的 probe_name 默认就是它。
    # 所以 tap 不是"挂在 cache 上"，而是插一个 monitor 在 L2 与 membus 之间，探针
    # 作为它的子对象 —— HetTraceProbe 的 manager 是 Parent.any，正好解析到 monitor。
    system.monitor = CommMonitor()
    system.l2cache.mem_side = system.monitor.cpu_side_port
    system.monitor.mem_side_port = system.membus.cpu_side_ports


def build_npu(system, args):
    from m5.objects import CoralNPU

    system.coralnpu = CoralNPU(
        library=args.npu_library,
        kernel=args.npu_kernel,
        pio_addr=NPU_PIO[0],
        # 让设备声明整整一页，而不是默认的 0x20 字节。host 是整页映射进来的，
        # 一次越界访问在 0x20 之后就会变成 xbar 的 "Unable to find destination"
        # fatal —— 那个错离现场很远。整页覆盖的话，设备自己会 warn 未知偏移。
        pio_size=NPU_PIO[1],
        clk_domain=SrcClockDomain(
            clock=NPU_CLOCK, voltage_domain=system.clk_domain.voltage_domain
        ),
        auto_start=args.npu_auto_start,
        # 不让 NPU 结束仿真：这套系统里是 host 说什么时候完事。NPU 跑完只是把
        # tick 链停下，host 轮询 REG_STATUS 的 halted 位就能看见。
        exit_on_complete=False,
        share_memory=not args.npu_no_share,
        trace_enable=True,
    )
    system.coralnpu.pio = system.membus.mem_side_ports


def build_vortex(system, args):
    from m5.objects import VortexGPGPU

    system.vortex = VortexGPGPU(
        library=args.vortex_library,
        kernel=args.vortex_kernel,
        pio_addr=VORTEX_CP[0],
        pio_size=VORTEX_CP[1],
        # pin_addr 的默认值是 0x100000000（4GiB 之上）。这里必须按 addrmap.json
        # 改成 0xa0000000：CoralNPU 的 AXI 地址是 32 位的，4GiB 以上的地址它根本
        # 表达不了，而三方共用一张地址图是本项目的前提。
        pin_addr=VORTEX_VRAM[0],
        pin_size=VORTEX_VRAM[1],
        clk_domain=SrcClockDomain(
            clock=VORTEX_CLOCK, voltage_domain=system.clk_domain.voltage_domain
        ),
        trace_enable=True,
    )
    system.vortex.pio = system.membus.mem_side_ports
    system.vortex.dma = system.membus.cpu_side_ports


def host_env(args):
    env = list(args.env)
    if args.vortex_host_rt_dir:
        # libvortex.so 会按 VORTEX_DRIVER 去 dlopen libvortex-<driver>.so；
        # 两个 .so 都在这个目录里，所以一并塞进 LD_LIBRARY_PATH。
        env.append(f"LD_LIBRARY_PATH={args.vortex_host_rt_dir}")
        if not any(e.startswith("VORTEX_DRIVER=") for e in env):
            env.append("VORTEX_DRIVER=gem5-x86_64")
    return env


def map_device_windows(process, args):
    """把设备持有的物理区间按 VA==PA 映射进被仿真进程。

    必须在 m5.instantiate() 之后调用。host 侧于是可以像普通内存一样读写这些窗口，
    路由由 membus 按 responder 声明的区间完成。

    cacheable=False 不是保险起见，是必需的：
      - MMIO 窗口（NPU_PIO / VORTEX_CP）本来就不能进 cache；
      - shared_buffer 里 host 写完之后，NPU 是经 physProxy（functional 访问）读
        的，而 functional 访问不保证能把 CPU cache 里的脏行捞出来。留在 cache 里
        的新数据 NPU 看不见 —— 现象是 NPU 读到旧值，而 host trace 上"写"明明发生
        过。设成 uncacheable 就绕开了整个问题，代价是 host 侧慢一点。
    """
    regions = [("shared_buffer", SHARED_BUFFER), ("npu_work", NPU_WORK)]
    if args.npu_library:
        regions.append(("npu_pio", NPU_PIO))
    if args.vortex_library:
        # CP 窗口只有 0x200 字节，映射得按页对齐，所以给整页。
        regions.append(("vortex_cp", (VORTEX_CP[0], PAGE)))
        regions.append(("vortex_vram", VORTEX_VRAM))

    for name, (base, size) in regions:
        process.map(base, base, size, cacheable=False)
        print(f"  map {name:<14} VA=PA=0x{base:08x} +0x{size:x} uncacheable")


def main():
    args = parse_args()

    checks = [(args.cmd, "cmd")]
    if args.npu_library:
        checks.append((args.npu_library, "npu-library"))
    if args.npu_kernel:
        checks.append((args.npu_kernel, "npu-kernel"))
    if args.vortex_library:
        checks.append((args.vortex_library, "vortex-library"))
    if args.vortex_kernel:
        checks.append((args.vortex_kernel, "vortex-kernel"))
    for path, what in checks:
        if not os.path.isfile(path):
            raise SystemExit(f"错误: --{what} 指向的文件不存在: {path}")
    if args.npu_kernel and not args.npu_library:
        raise SystemExit("错误: 给了 --npu-kernel 却没给 --npu-library")
    if args.vortex_kernel and not args.vortex_library:
        raise SystemExit("错误: 给了 --vortex-kernel 却没给 --vortex-library")

    system = System()
    system.clk_domain = SrcClockDomain(
        clock=HOST_CLOCK, voltage_domain=VoltageDomain()
    )
    # atomic：两个设备的访存都不是时序请求（NPU 走 physProxy，Vortex 走设备内的
    # RAM），换成 timing 只会让 host 侧变慢，trace 的内容不变。本项目要的是访存
    # 序列，不是周期精确的 DRAM 时序。
    system.mem_mode = "atomic"

    system.membus = SystemXBar()
    # 必须连。physProxy 挂在 system_port 上，CoralNPU 的 AXI master 就是经它读写
    # gem5 内存的；不连的话第一次 readBlob 就挂，而且报的错离现场很远。
    system.system_port = system.membus.cpu_side_ports

    build_memories(system)

    argv = [args.cmd] + shlex.split(args.options)
    process = Process(pid=100, cmd=argv, executable=args.cmd, env=host_env(args))
    system.workload = SEWorkload.init_compatible(args.cmd)

    build_cpus(system, args, process)

    if not args.no_host_trace:
        # 探针作为 monitor 的子对象挂上去，manager=Parent.any 才解析得到它。
        system.monitor.trace = HetTraceProbe(
            src_name="host",
            trace_enable=True,
            trace_inst_fetch=args.host_trace_inst,
        )

    if args.npu_library:
        build_npu(system, args)
    if args.vortex_library:
        build_vortex(system, args)

    root = Root(full_system=False, system=system)
    m5.instantiate()

    print("---- 地址窗口 ----")
    map_device_windows(system.cpu[0].workload[0], args)

    legs = ["host"]
    if args.npu_library:
        legs.append("coralnpu")
    if args.vortex_library:
        legs.append("vortex")
    print(f"---- 开跑: {' + '.join(legs)}, max_ticks={args.max_ticks} ----")
    print(f"     cmd: {' '.join(argv)}")

    event = m5.simulate(args.max_ticks)
    print(f"---- 结束: {event.getCause()} @ tick {m5.curTick()} ----")

    if "simulate() limit reached" in event.getCause():
        print("错误: 到达 tick 上限 —— host 或某个设备没有停下来")
        raise SystemExit(1)
    # host 进程的退出码要透出来，否则 workload 里的自检失败在 gem5 这一层是静默的
    # —— gem5 自己无论 host 程序 return 几都是 0 退出。
    if event.getCode() != 0:
        print(f"错误: host 进程退出码 {event.getCode()}")
        raise SystemExit(1)


main()
