// 本文件由 scripts/gen_addrmap.py 从 addrmap.json 生成，请勿手改。
//
// 统一物理地址空间。三个 trace 产生者共用。

#ifndef HETTRACE_ADDRMAP_H_
#define HETTRACE_ADDRMAP_H_

#include <cstdint>
#include <cstddef>

namespace hettrace {

constexpr int      kAddrBits       = 32;
constexpr uint64_t kTicksPerSecond = 1000000000000ull;

// ---- 源 ID ----
enum SrcId : uint16_t {
    kSrcHost = 0,
    kSrcVortex = 1,
    kSrcCoralnpu = 2,
    kSrcCount = 3,
};

// tap 挂载层级。同一条 trace 里混用不同层级是无意义的，
// 因此每个源在文件头中显式声明自己的层级。
enum TapLevel : uint8_t {
    kLevelPostLlc = 0,
    kLevelPreCache = 1,
    kLevelAxiMaster = 2,
};

// 各源标称时钟（用于把源内 cycle 折算成全局 tick）
constexpr uint64_t kClockPeriodTicks_host = 500ull;  // 2000 MHz
constexpr uint64_t kClockPeriodTicks_vortex = 1000ull;  // 1000 MHz
constexpr uint64_t kClockPeriodTicks_coralnpu = 2000ull;  // 500 MHz

// ---- 区域 ----
// boot_rom: 预留 / 引导。不参与 trace 分析。
constexpr uint64_t kBootRomBase = 0x0ull;
constexpr uint64_t kBootRomSize = 0x10000000ull;

// npu_slave: CoralNPU AXI slave 窗口。host 经此写 TCM 与控制寄存器。
constexpr uint64_t kNpuSlaveBase = 0x10000000ull;
constexpr uint64_t kNpuSlaveSize = 0x10000000ull;
constexpr uint64_t kNpuTcmAddr = 0x10000000ull;  // ITCM + DTCM，core-local。命中此处不算 DRAM 流量，默认不入 trace。
constexpr uint64_t kNpuCtrlResetAddr = 0x10030000ull;  // 写 1 再写 0 触发启动 (core_mini_axi_simulator.cc Run())
constexpr uint64_t kNpuCtrlPcAddr = 0x10030004ull;  // 起始 PC

// vortex_cp: Vortex CP 寄存器堆 (PIO)。与 VortexGPGPU.py 的 pio_addr 默认值一致，勿改。
constexpr uint64_t kVortexCpBase = 0x20000000ull;
constexpr uint64_t kVortexCpSize = 0x200ull;

// npu_pio: gem5 CoralNPU SimObject 的控制窗口 (ctrl/status/entry/emitted/mailbox×4)，与 CoralNPU.py 的 pio_addr 默认值一致，勿改。注意它与上面的 npu_slave 是两回事：npu_slave 是设备库内部的 AXI slave 窗口（host 经它写 TCM），npu_pio 是 gem5 这一侧的寄存器。实际只用到头 0x20 字节，占满一页是为了 host 侧能整页映射。
constexpr uint64_t kNpuPioBase = 0x30000000ull;
constexpr uint64_t kNpuPioSize = 0x1000ull;

// host_heap: host 私有堆。落在 NPU 的 DDR 窗口内但 NPU 不应触及。
constexpr uint64_t kHostHeapBase = 0x80000000ull;
constexpr uint64_t kHostHeapSize = 0x10000000ull;

// shared_buffer: 三方交接区。异构 trace 的全部信息量来自这里 —— 归并工具据此判定真实共享。
constexpr uint64_t kSharedBufferBase = 0x90000000ull;
constexpr uint64_t kSharedBufferSize = 0x10000000ull;

// vortex_vram: Vortex VRAM，经 BAR 对 host 可见。必须以此值覆盖 VortexGPGPU.py 里 pin_addr 的默认 0x100000000，否则超出 CoralNPU 的 32 位可寻址范围。
constexpr uint64_t kVortexVramBase = 0xa0000000ull;
constexpr uint64_t kVortexVramSize = 0x10000000ull;

// npu_work: NPU 私有工作区（权重、activation 暂存）。
constexpr uint64_t kNpuWorkBase = 0xb0000000ull;
constexpr uint64_t kNpuWorkSize = 0x10000000ull;

// npu_mailbox: NPU 经 AXI master 访问的 4×u32 mailbox。参考实现把所有非 DDR 的 master 访问都当 mailbox；本工程收窄为显式窗口，落在窗口外一律记为 unmapped 并计数。
constexpr uint64_t kNpuMailboxBase = 0xc0000000ull;
constexpr uint64_t kNpuMailboxSize = 0x10ull;

// CoralNPU IsDdrAddress() 判定区间
constexpr uint64_t kDramWindowBase = 0x80000000ull;
constexpr uint64_t kDramWindowSize = 0x40000000ull;

struct Region {
    const char* name;
    uint64_t    base;
    uint64_t    size;
    bool        is_dram;
};

constexpr Region kRegions[] = {
    { "boot_rom", 0x0ull, 0x10000000ull, false },
    { "npu_slave", 0x10000000ull, 0x10000000ull, false },
    { "vortex_cp", 0x20000000ull, 0x200ull, false },
    { "npu_pio", 0x30000000ull, 0x1000ull, false },
    { "host_heap", 0x80000000ull, 0x10000000ull, true },
    { "shared_buffer", 0x90000000ull, 0x10000000ull, true },
    { "vortex_vram", 0xa0000000ull, 0x10000000ull, true },
    { "npu_work", 0xb0000000ull, 0x10000000ull, true },
    { "npu_mailbox", 0xc0000000ull, 0x10ull, false },
};
constexpr size_t kNumRegions = sizeof(kRegions) / sizeof(kRegions[0]);

// 返回 addr 所属区域名，未映射返回 nullptr。线性扫描；仅用于诊断路径，
// 不要放进 per-access 热路径。
inline const char* RegionOf(uint64_t addr) {
    for (size_t i = 0; i < kNumRegions; ++i) {
        if (addr >= kRegions[i].base &&
            addr <  kRegions[i].base + kRegions[i].size) {
            return kRegions[i].name;
        }
    }
    return nullptr;
}

inline bool IsDram(uint64_t addr) {
    return addr >= kDramWindowBase &&
           addr <  kDramWindowBase + kDramWindowSize;
}

inline bool IsShared(uint64_t addr) {
    return addr >= kSharedBufferBase &&
           addr <  kSharedBufferBase + kSharedBufferSize;
}

}  // namespace hettrace

#endif  // HETTRACE_ADDRMAP_H_
