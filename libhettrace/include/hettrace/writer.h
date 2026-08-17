// libhettrace — trace 写出器。header-only。
//
// 配置全部走环境变量，这样三个 tap 都不必把选项一路透传下来：
//
//   HETTRACE_DIR      输出目录。未设置 => 完全关闭，Emit() 退化为一次分支判断。
//   HETTRACE_FORMAT   bin(默认) | text
//   HETTRACE_FILTER   dram(默认) | all
//                     dram: 只记录落在 DRAM 窗口内的访问。NPU 的 TCM 命中、
//                     CP 寄存器读写等不是 DRAM 流量，混进来会让带宽统计虚高。
//   HETTRACE_BUFSZ    缓冲记录条数，默认 65536
//
// 线程安全：无。三个 tap 都在 gem5 事件循环线程上被调用（见
// vortex_gpgpu.h 的 "Concurrency" 注释），故不加锁。

#ifndef HETTRACE_WRITER_H_
#define HETTRACE_WRITER_H_

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "hettrace/addrmap.h"
#include "hettrace/record.h"

namespace hettrace {

class TraceWriter {
  public:
    TraceWriter() = default;

    ~TraceWriter() { Close(); }

    TraceWriter(const TraceWriter&)            = delete;
    TraceWriter& operator=(const TraceWriter&) = delete;

    // 若 HETTRACE_DIR 未设置则返回 false 且保持关闭状态——调用方应把它当作
    // "用户没要 trace"，不是错误。
    //
    // src_name 同时作为文件名: $HETTRACE_DIR/<src_name>.hettrace[.txt]
    bool Open(uint16_t src_id, const char* src_name, TapLevel level,
              uint64_t clock_period_ticks) {
        Close();

        const char* dir = std::getenv("HETTRACE_DIR");
        if (dir == nullptr || dir[0] == '\0') {
            return false;
        }

        const char* fmt = std::getenv("HETTRACE_FORMAT");
        text_ = (fmt != nullptr && std::strcmp(fmt, "text") == 0);

        const char* filt = std::getenv("HETTRACE_FILTER");
        dram_only_ = !(filt != nullptr && std::strcmp(filt, "all") == 0);

        const char* bufsz = std::getenv("HETTRACE_BUFSZ");
        size_t cap = 65536;
        if (bufsz != nullptr) {
            long v = std::strtol(bufsz, nullptr, 10);
            if (v > 0) cap = static_cast<size_t>(v);
        }

        path_ = std::string(dir) + "/" + src_name +
                (text_ ? ".hettrace.txt" : ".hettrace");
        fp_ = std::fopen(path_.c_str(), text_ ? "w" : "wb");
        if (fp_ == nullptr) {
            std::fprintf(stderr, "hettrace: 无法打开 %s\n", path_.c_str());
            return false;
        }

        src_id_             = src_id;
        src_name_           = src_name;
        level_              = level;
        clock_period_ticks_ = clock_period_ticks;
        stats_              = Stats();
        seq_                = 0;
        buf_.clear();
        buf_.reserve(cap);
        cap_ = cap;

        WriteHeader();
        open_ = true;
        return true;
    }

    void Close() {
        if (!open_) return;
        Flush();
        std::fclose(fp_);
        fp_ = nullptr;
        WriteMeta();
        open_ = false;
    }

    bool is_open() const { return open_; }

    const Stats& stats() const { return stats_; }

    const std::string& path() const { return path_; }

    // 热路径。关闭时只有一次分支。
    void Emit(uint64_t tick, uint64_t addr, uint32_t size, Op op, uint32_t ctx,
              uint8_t flags = 0) {
        if (!open_) return;

        if (dram_only_ && !IsDram(addr)) {
            ++stats_.filtered;
            return;
        }
        if (RegionOf(addr) == nullptr) {
            ++stats_.unmapped;
            flags |= kFlagUnmapped;
        }

        if (stats_.emitted == 0) {
            stats_.first_tick = tick;
        } else if (tick < stats_.last_tick) {
            ++stats_.non_monotonic;
        }
        stats_.last_tick = tick;
        ++stats_.emitted;
        stats_.bytes += size;

        Record r;
        r.tick   = tick;
        r.addr   = addr;
        r.size   = size;
        r.ctx    = ctx;
        r.seq    = seq_++;
        r.src_id = src_id_;
        r.op     = static_cast<uint8_t>(op);
        r.flags  = flags;

        buf_.push_back(r);
        if (buf_.size() >= cap_) Flush();
    }

    // AXI burst 展开：master 侧回调按拍触发，但 AxiAddr 携带的是整笔事务的
    // 首地址（见 hw_primitives.h AxiMasterWriteDriver::OnFallingEdge——每拍都
    // 用同一个 axi_addr_）。若直接按拍记首地址，会得到 N 条相同地址的记录，
    // 让局部性分析完全失真。这里按 AXI4 INCR 语义展开成 len+1 拍。
    void EmitBurst(uint64_t tick, uint64_t base_addr, uint8_t axi_len,
                   uint8_t axi_size, Op op, uint32_t ctx) {
        const uint32_t beat_bytes = 1u << axi_size;
        const uint32_t beats      = static_cast<uint32_t>(axi_len) + 1u;
        for (uint32_t i = 0; i < beats; ++i) {
            Emit(tick, base_addr + static_cast<uint64_t>(i) * beat_bytes,
                 beat_bytes, op, ctx, i == 0 ? 0 : kFlagBurstBeat);
        }
    }

    void Flush() {
        if (fp_ == nullptr || buf_.empty()) return;
        if (text_) {
            for (const Record& r : buf_) {
                std::fprintf(fp_, "%llu %u %s 0x%llx %u %u %u 0x%02x\n",
                             static_cast<unsigned long long>(r.tick),
                             static_cast<unsigned>(r.src_id),
                             r.op == kWrite ? "W" : "R",
                             static_cast<unsigned long long>(r.addr),
                             static_cast<unsigned>(r.size),
                             static_cast<unsigned>(r.ctx),
                             static_cast<unsigned>(r.seq),
                             static_cast<unsigned>(r.flags));
            }
        } else {
            std::fwrite(buf_.data(), sizeof(Record), buf_.size(), fp_);
        }
        buf_.clear();
    }

  private:
    void WriteHeader() {
        if (text_) {
            // 文本模式下头部写成注释，字段与二进制头一一对应，便于人读。
            std::fprintf(fp_, "# hettrace v%u text\n", kFormatVersion);
            std::fprintf(fp_, "# src_id=%u name=%s level=%u\n",
                         static_cast<unsigned>(src_id_), src_name_.c_str(),
                         static_cast<unsigned>(level_));
            std::fprintf(fp_, "# ticks_per_second=%llu clock_period_ticks=%llu\n",
                         static_cast<unsigned long long>(kTicksPerSecond),
                         static_cast<unsigned long long>(clock_period_ticks_));
            std::fprintf(fp_, "# filter=%s\n", dram_only_ ? "dram" : "all");
            std::fprintf(fp_, "# tick src op addr size ctx seq flags\n");
            return;
        }
        FileHeader h;
        std::memset(&h, 0, sizeof(h));
        std::memcpy(h.magic, kMagic, sizeof(kMagic));
        h.version            = kFormatVersion;
        h.record_size        = static_cast<uint32_t>(sizeof(Record));
        h.ticks_per_second   = kTicksPerSecond;
        h.clock_period_ticks = clock_period_ticks_;
        h.src_id             = src_id_;
        h.level              = static_cast<uint8_t>(level_);
        h.flags              = dram_only_ ? kHdrFilteredDram : 0;
        std::strncpy(h.name, src_name_.c_str(), kNameMax - 1);
        std::fwrite(&h, sizeof(h), 1, fp_);
    }

    // 侧车 meta 文件。下游 validate 用它交叉核对记录数——若 meta 说 emitted=N
    // 而文件里只有 M<N 条，说明进程被杀且缓冲未刷出，这种 trace 不能用。
    void WriteMeta() {
        const std::string mp = path_ + ".meta.json";
        FILE* mf = std::fopen(mp.c_str(), "w");
        if (mf == nullptr) return;
        std::fprintf(mf, "{\n");
        std::fprintf(mf, "  \"src_id\": %u,\n", static_cast<unsigned>(src_id_));
        std::fprintf(mf, "  \"name\": \"%s\",\n", src_name_.c_str());
        std::fprintf(mf, "  \"level\": %u,\n", static_cast<unsigned>(level_));
        std::fprintf(mf, "  \"format\": \"%s\",\n", text_ ? "text" : "bin");
        std::fprintf(mf, "  \"filter\": \"%s\",\n", dram_only_ ? "dram" : "all");
        std::fprintf(mf, "  \"ticks_per_second\": %llu,\n",
                     static_cast<unsigned long long>(kTicksPerSecond));
        std::fprintf(mf, "  \"clock_period_ticks\": %llu,\n",
                     static_cast<unsigned long long>(clock_period_ticks_));
        std::fprintf(mf, "  \"emitted\": %llu,\n",
                     static_cast<unsigned long long>(stats_.emitted));
        std::fprintf(mf, "  \"filtered\": %llu,\n",
                     static_cast<unsigned long long>(stats_.filtered));
        std::fprintf(mf, "  \"unmapped\": %llu,\n",
                     static_cast<unsigned long long>(stats_.unmapped));
        std::fprintf(mf, "  \"non_monotonic\": %llu,\n",
                     static_cast<unsigned long long>(stats_.non_monotonic));
        std::fprintf(mf, "  \"bytes\": %llu,\n",
                     static_cast<unsigned long long>(stats_.bytes));
        std::fprintf(mf, "  \"first_tick\": %llu,\n",
                     static_cast<unsigned long long>(stats_.first_tick));
        std::fprintf(mf, "  \"last_tick\": %llu\n",
                     static_cast<unsigned long long>(stats_.last_tick));
        std::fprintf(mf, "}\n");
        std::fclose(mf);
    }

    FILE*               fp_                 = nullptr;
    bool                open_               = false;
    bool                text_               = false;
    bool                dram_only_          = true;
    uint16_t            src_id_             = 0;
    TapLevel            level_              = kLevelPostLlc;
    uint64_t            clock_period_ticks_ = 0;
    uint32_t            seq_                = 0;
    size_t              cap_                = 65536;
    std::string         src_name_;
    std::string         path_;
    std::vector<Record> buf_;
    Stats               stats_;
};

}  // namespace hettrace

#endif  // HETTRACE_WRITER_H_
