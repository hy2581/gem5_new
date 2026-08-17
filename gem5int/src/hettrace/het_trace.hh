// HetTraceProbe — host CPU 侧的 hettrace tap。
//
// 装在 $GEM5_HOME/src/hettrace/ 由 gem5int/install.sh 拷入；真值源在本项目树。
//
// 放在自己的新目录而不是塞进 src/mem/probes/：那个目录是 gem5 自带的，往它的
// SConscript 里加两行就意味着要覆盖一个上游文件，上游一改就冲突。新目录下
// gem5 的 SConstruct 会自动递归到我们自己的 SConscript，上游一行都不用动 ——
// CoralNPU 设备那边（src/dev/coralnpu/）是同一个理由。libhettrace 的头也装在
// 这个目录，所以 #include "hettrace/writer.h" 与本文件是邻居关系。
//
// 为什么不用 gem5 自带的 MemTraceProbe：
//
// 1. 时间基准与格式必须与另外两个源一致。MemTraceProbe 写的是 protobuf
//    (packet.proto)，字段是 tick/cmd/addr/size/pc/flags，没有 src_id 也没有
//    区域概念，归并时要先转一遍格式；转换本身不难，难的是转换代码会变成第四份
//    "格式定义"，与 record.h 慢慢漂移。三个源写同一种记录是本项目唯一的抓手。
// 2. MemTraceProbe 需要 protobuf（见 src/mem/probes/SConscript 里的
//    HAVE_PROTOBUF 判断），本 probe 不需要，一个 header-only 的 writer 就够。
//
// 复用的部分：BaseMemProbe。它已经解决了"一个 probe 挂多个 ProbeManager"这件事
// （多通道内存控制器、多个 LLC 各有自己的 manager），而 ProbeListenerObject
// 只能挂一个。挂载点选 post-LLC（内存控制器或最后一级 cache 的 mem_side），
// 与 Vortex tap 的层级对齐 —— 两边都记"真正打到 DRAM 的流量"，否则 cache 命中
// 率的差异会让两个源的记录数没有可比性。
//
// 只读：probe 不修改 Packet，也不影响时序。这是本项目的既定范围（观察流量，
// 不建模耦合时序）。

#ifndef __HETTRACE_HET_TRACE_HH__
#define __HETTRACE_HET_TRACE_HH__

#include "hettrace/writer.h"
#include "mem/probes/base.hh"

namespace gem5
{

struct HetTraceProbeParams;

class HetTraceProbe : public BaseMemProbe
{
  public:
    HetTraceProbe(const HetTraceProbeParams &params);
    ~HetTraceProbe() override;

    void startup() override;

  protected:
    void handleRequest(const probing::PacketInfo &pkt_info) override;

  private:
    // 同 CoralNPU 设备：gem5 不保证退出时析构 SimObject，没有这一步侧车文件和
    // 缓冲尾部都不会落盘，而下游的截断检测正是靠侧车文件里的 emitted 计数。
    void closeTrace();

    hettrace::TraceWriter writer_;

    const std::string srcName_;
    const bool        enable_;
    const int64_t     addrOffset_;
    // 取指流量。默认记：host 的取指同样会打到 DRAM，是真实带宽的一部分。
    // 关掉它是为了和只看数据流量的分析对齐。
    const bool        traceInstFetch_;
    bool              active_;
};

} // namespace gem5

#endif // __HETTRACE_HET_TRACE_HH__
