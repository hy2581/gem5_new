# Python SimObject binding for the host-side hettrace probe.
#
# 由 gem5int/install.sh 装进 $GEM5_HOME/src/hettrace/。

from m5.objects.BaseMemProbe import BaseMemProbe
from m5.params import *


class HetTraceProbe(BaseMemProbe):
    type = "HetTraceProbe"
    cxx_header = "hettrace/het_trace.hh"
    cxx_class = "gem5::HetTraceProbe"

    # 与 addrmap.json 的 sources[0].name 一致，同时决定文件名
    # ($HETTRACE_DIR/<src_name>.hettrace)。改了这里下游 validate 会认不出源。
    src_name = Param.String("host", "trace 里的源名，同时是输出文件名")

    # 与另外两个源同样的分工：这个参数只决定"要不要装 tap"，真正决定有没有文件
    # 的是 HETTRACE_DIR 环境变量（在 libhettrace 的 writer 里读）。这样输出目录
    # 不必出现在配置脚本里 —— 三个源必须写进同一个目录，让它们各自从环境变量拿
    # 是唯一不会写歪的做法。
    trace_enable = Param.Bool(
        True,
        "装 tap（HETTRACE_DIR 未设置时自动退化为无操作）",
    )

    # 记录前加到地址上的偏移。统一物理地址空间下应当为 0；留着是为了应付
    # host 与设备看到的物理地址不一致的配置。
    trace_addr_offset = Param.Int64(0, "记录前加到地址上的偏移")

    # 取指流量。默认**不**记，与 het_system.py 的 --host-trace-inst 保持一致
    # （那个开关默认关）—— 两处默认值不一致的话，直接 HetTraceProbe() 建出来的
    # 探针会比本项目跑出来的所有 trace 多好几倍记录，而条数对不上是最难查的一
    # 类差异。
    #
    # 取指确实是真实 DRAM 流量，记进来并不错，而且记录带 kFlagInstr 标记，下游
    # 随时能分开看。默认关掉纯粹是因为它把记录数翻好几倍，而本项目要回答的问题
    # （三个源有没有碰同一段数据）用不到它。
    trace_inst_fetch = Param.Bool(False, "把取指流量也记进 trace")

    # BaseMemProbe 的 probe_name 默认是 "PktRequest"，正是我们要的：
    # 内存控制器/末级 cache 的 mem_side 发出的请求。这里不覆盖它。
