// 设计说明在 het_trace.hh。

#include "hettrace/het_trace.hh"

#include "base/logging.hh"
#include "hettrace/addrmap.h"
#include "mem/request.hh"
#include "params/HetTraceProbe.hh"
#include "sim/core.hh"
#include "sim/sim_exit.hh"

namespace gem5
{

HetTraceProbe::HetTraceProbe(const HetTraceProbeParams &p)
  : BaseMemProbe(p),
    srcName_(p.src_name),
    enable_(p.trace_enable),
    addrOffset_(p.trace_addr_offset),
    traceInstFetch_(p.trace_inst_fetch),
    active_(false)
{
}

HetTraceProbe::~HetTraceProbe()
{
    closeTrace();
}

void
HetTraceProbe::startup()
{
    BaseMemProbe::startup();

    if (!enable_) return;

    // clock_period_ticks 只是给下游把 tick 折算成周期用的元数据，不影响记录。
    // 默认取 addrmap.json 里 host 源的时钟，这样三个源的换算系数出自同一处。
    const uint64_t period = hettrace::kClockPeriodTicks_host;

    // 返回 false 的正常原因是 HETTRACE_DIR 没设 —— 不是错误。
    if (!writer_.Open(hettrace::kSrcHost, srcName_.c_str(),
                      hettrace::kLevelPostLlc, period)) {
        return;
    }
    active_ = true;
    inform("HetTraceProbe: host 访存 trace -> %s", writer_.path());

    // gem5 退出时不保证析构 SimObject。
    registerExitCallback([this]{ this->closeTrace(); });
}

void
HetTraceProbe::closeTrace()
{
    if (!active_) return;
    active_ = false;

    const hettrace::Stats s = writer_.stats();
    writer_.Close();
    inform("HetTraceProbe: host trace 关闭，%llu 条记录 "
           "(过滤 %llu, 越界 %llu)",
           static_cast<unsigned long long>(s.emitted),
           static_cast<unsigned long long>(s.filtered),
           static_cast<unsigned long long>(s.unmapped));

    // 时间戳回退在 host 侧不该发生：所有记录都取自同一个 curTick()，而 probe
    // 是在事件回调里同步调用的。真出现了说明 probe 被挂到了不止一个时间域上
    // （例如把两个跑在不同 EventQueue 的 manager 塞进了同一个 probe），
    // 那份 trace 的排序不可信。
    if (s.non_monotonic != 0) {
        warn("HetTraceProbe: %llu 条记录时间戳回退 —— 这份 trace 的顺序不可信",
             static_cast<unsigned long long>(s.non_monotonic));
    }
}

void
HetTraceProbe::handleRequest(const probing::PacketInfo &pkt_info)
{
    if (!active_) return;

    // 读写以外的命令（Upgrade、Invalidate、CleanEvict 之类）不搬数据，记进来只会
    // 把带宽统计做虚。isRead() 对 ReadExReq 这种"读+获取独占"也为真，所以先判写。
    hettrace::Op op;
    if (pkt_info.cmd.isWrite()) {
        op = hettrace::kWrite;
    } else if (pkt_info.cmd.isRead()) {
        op = hettrace::kRead;
    } else {
        return;
    }

    const bool inst = (pkt_info.flags & Request::INST_FETCH) != 0;
    if (inst && !traceInstFetch_) return;

    uint8_t flags = 0;
    if (inst) flags |= hettrace::kFlagInstr;
    // 预取不是程序序访问。不丢弃而是打标记：它是真实的 DRAM 流量，但做时间关联
    // （"host 写完 shared_buffer 之后 NPU 才读"）时必须能把它排除掉。
    if (pkt_info.cmd.isSWPrefetch() || pkt_info.cmd.isHWPrefetch() ||
        (pkt_info.flags & Request::PREFETCH) != 0) {
        flags |= hettrace::kFlagPrefetch;
    }

    writer_.Emit(static_cast<uint64_t>(curTick()),
                 static_cast<uint64_t>(pkt_info.addr + addrOffset_),
                 pkt_info.size, op,
                 // ctx = requestorId：多核时用它区分是哪个 CPU 发的。
                 static_cast<uint32_t>(pkt_info.id),
                 flags);
}

} // namespace gem5
