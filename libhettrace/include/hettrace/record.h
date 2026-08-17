// libhettrace — 异构访存 trace 的记录格式。
//
// 三个产生者（gem5 host probe、Vortex MemSim tap、CoralNPU AXI master tap）
// 写同一种格式，每个源一个独立文件。归并留给下游 Python 工具，理由见
// docs/02-trace-format.md：单文件交织写入在多时钟域下无法保证 tick 单调，
// 而排序错误一旦写进文件就不可恢复。
//
// header-only。gem5 用 SCons、CoralNPU 用 bazel、Vortex 用 make——
// 三套构建系统各自 include 即可，无需产出库文件。

#ifndef HETTRACE_RECORD_H_
#define HETTRACE_RECORD_H_

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace hettrace {

// ---------------------------------------------------------------------------
// 文件头：64 字节定长
// ---------------------------------------------------------------------------

constexpr char     kMagic[8]      = {'H', 'E', 'T', 'T', 'R', 'C', '\0', '\1'};
constexpr uint32_t kFormatVersion = 1;
constexpr size_t   kHeaderSize    = 64;
constexpr size_t   kNameMax       = 28;

#pragma pack(push, 1)
struct FileHeader {
    char     magic[8];             // "HETTRC\0\1"
    uint32_t version;              // kFormatVersion
    uint32_t record_size;          // sizeof(Record) == 32
    uint64_t ticks_per_second;     // gem5 时间基准，1e12
    uint64_t clock_period_ticks;   // 本源一个时钟周期折算的 tick 数
    uint16_t src_id;               // 见 addrmap.h SrcId
    uint8_t  level;                // 见 addrmap.h TapLevel
    uint8_t  flags;                // bit0: 仅 DRAM 窗口（已过滤）
    char     name[kNameMax];       // 源名，NUL 补齐
};
#pragma pack(pop)

static_assert(sizeof(FileHeader) == kHeaderSize, "FileHeader 必须为 64 字节");

// 文件头 flags
constexpr uint8_t kHdrFilteredDram = 1u << 0;

// ---------------------------------------------------------------------------
// 记录：32 字节定长，小端
// ---------------------------------------------------------------------------

enum Op : uint8_t {
    kRead  = 0,
    kWrite = 1,
};

// 记录 flags
constexpr uint8_t kFlagBurstBeat = 1u << 0;  // AXI burst 的非首拍
constexpr uint8_t kFlagPrefetch  = 1u << 1;  // 预取/推测，非程序序访问
constexpr uint8_t kFlagUnmapped  = 1u << 2;  // 地址不属于任何已声明区域
constexpr uint8_t kFlagInstr     = 1u << 3;  // 取指流量（可与数据流量分开分析）
constexpr uint8_t kFlagDma       = 1u << 4;  // 搬运引擎发出的，不是核发出的。
                                             // Vortex 的 CP 在暂存区与设备缓冲之间
                                             // 中转字节走的就是这条路：它不经过任何
                                             // cache，但确实占 DRAM 带宽。分析核的
                                             // 访存行为时要把它排掉，算带宽时不能排

#pragma pack(push, 1)
struct Record {
    uint64_t tick;    // 全局 tick。唯一时间基准，不是源内 cycle 数。
    uint64_t addr;    // 统一物理地址（addrmap.json）
    uint32_t size;    // 字节数
    uint32_t ctx;     // 源内上下文：host=requestorId, vortex=hart_id, npu=AXI id
    uint32_t seq;     // 源内单调序号。用于稳定排序，并检测缓冲区溢出丢记录。
    uint16_t src_id;
    uint8_t  op;      // Op
    uint8_t  flags;
};
#pragma pack(pop)

static_assert(sizeof(Record) == 32, "Record 必须为 32 字节");

// ---------------------------------------------------------------------------
// 统计：随 trace 一起落盘为 <file>.meta.json，供下游校验
// ---------------------------------------------------------------------------

struct Stats {
    uint64_t emitted      = 0;  // 实际写出的记录数
    uint64_t filtered      = 0;  // 被过滤掉的访问数（如 TCM 命中）
    uint64_t unmapped      = 0;  // 落在所有已声明区域之外
    uint64_t non_monotonic = 0;  // tick 小于上一条 —— 说明时间基准接错了
    uint64_t bytes         = 0;  // 访问字节总数（不是文件大小）
    uint64_t first_tick    = 0;
    uint64_t last_tick     = 0;
};

}  // namespace hettrace

#endif  // HETTRACE_RECORD_H_
