// CoralNPU — gem5 SimObject wrapper for libcoralnpu-gem5.so.
//
// Installed at $GEM5_HOME/src/dev/coralnpu/coralnpu_dev.{cc,hh} by
// gem5int/install.sh. The source of truth is this project's tree, mirroring
// how the Vortex leg keeps its gem5-side sources in the Vortex tree: API drift
// between the two sides then shows up as a build error next to the C ABI
// header it broke, not as a runtime dlsym mystery.
//
// Design — three things worth knowing before reading the .cc:
//
// 1. gem5 owns the clock. coralnpu_gem5_tick() advances CoralNPU exactly one
//    cycle and returns; tickEvent_ reschedules itself at clockEdge(Cycles(1))
//    for as long as the core reports it is running. The device library never
//    advances its own clock while the simulation is live -- if it did, every
//    memory record produced during those stolen cycles would carry the same
//    curTick() and the merged trace's time base would be meaningless. This is
//    the entire reason the CoralNPU wrapper needed a non-blocking halted()/
//    wfi() accessor added to it.
//
// 2. Memory is genuinely shared, not just co-addressed. The library's AXI
//    master callbacks are routed into system->physProxy (functional access,
//    zero simulated time), so the NPU reads the bytes the host CPU actually
//    wrote. Functional is a deliberate choice, not a shortcut: the AXI read
//    callback must return 16 bytes within the same cycle, so there is nothing
//    to return if we had to wait for a timing response. The cost is that NPU
//    traffic imposes no contention on the memory system -- consistent with
//    this project's scope (observe traffic, don't model coupled timing).
//
// 3. Tracing is opt-in and never fatal. trace_enable=false, a library built
//    before the trace ABI, or an unset HETTRACE_DIR all mean "no trace" and
//    the simulation proceeds normally.

#ifndef __DEV_CORALNPU_CORALNPU_DEV_HH__
#define __DEV_CORALNPU_CORALNPU_DEV_HH__

#include <cstdint>
#include <string>

#include "dev/io_device.hh"
#include "params/CoralNPU.hh"
#include "sim/eventq.hh"

namespace gem5
{

class CoralNPU : public BasicPioDevice
{
public:
    using Params = CoralNPUParams;

    CoralNPU(const Params &p);
    ~CoralNPU() override;

    // PioDevice interface — the control/status/mailbox register window.
    Tick read(PacketPtr pkt) override;
    Tick write(PacketPtr pkt) override;

    // SimObject lifecycle
    void startup() override;

private:
    // Control register offsets within the PIO window. Deliberately tiny:
    // once the kernel is running, the host talks to the NPU through the
    // shared buffer and the mailbox, not through these.
    enum Reg : Addr
    {
        REG_CTRL     = 0x00,  // W: bit0 = start kernel (one-shot; a second
                              //    write is refused with a warning)
        REG_STATUS   = 0x04,  // R: bit0 halted, bit1 wfi, bit2 ticking
        REG_ENTRY    = 0x08,  // R: entry PC reported by load_elf
        REG_EMITTED  = 0x0c,  // R: trace records written so far (low 32b)
        REG_MAILBOX0 = 0x10,  // R/W: mailbox[0..3]
        REG_MAILBOX3 = 0x1c,
    };

    // One CoralNPU cycle per event. Reschedules itself while the core runs.
    void tick();

    // Load the ELF and pulse the ctrl register. Both use the library's
    // blocking AXI-slave path, which advances CoralNPU's clock internally --
    // legal only before the first tick is scheduled. Called from startup().
    //
    // Start is one-shot: started_ is never cleared, so once the kernel has
    // been launched -- and also once it has halted -- a further REG_CTRL
    // write is refused with a warning. Restarting a halted CoreMiniAxi core
    // by pulsing ctrl again is not something this project has verified, and
    // refusing loudly beats re-running from an unknown core state.
    void loadAndStart();

    // Memory-access tracing (hettrace) --------------------------------
    // The library is dlopen'd and does not link gem5, so it cannot call
    // curTick(). This trampoline is what puts CoralNPU's records on the same
    // time base as the host and Vortex traces -- the whole point of the
    // exercise.
    static uint64_t curTickTrampoline(void *ctx);

    // No-op if trace_enable=false, if the library predates the trace ABI, or
    // if HETTRACE_DIR is unset. None of those are errors.
    void openTrace();

    // Flush + write the .meta.json sidecar. Idempotent; called from the
    // completion path, from an exit callback, and from the destructor,
    // because gem5 does not reliably destroy SimObjects at exit and without
    // the sidecar downstream truncation detection has nothing to compare to.
    void closeTrace();

    // AXI master memory backend ---------------------------------------
    // Static trampolines handed to the library; ctx is `this`. Both are
    // synchronous functional accesses into gem5's physical memory.
    static void memReadTrampoline(void *ctx, uint64_t addr,
                                  uint8_t *dst, uint32_t size);
    static void memWriteTrampoline(void *ctx, uint64_t addr,
                                   const uint8_t *src, uint32_t size);
    void memRead(uint64_t addr, uint8_t *dst, uint32_t size);
    void memWrite(uint64_t addr, const uint8_t *src, uint32_t size);

    // Library binding ------------------------------------------------
    void *libHandle_;
    void *deviceHandle_;

    struct Abi
    {
        const char *(*build_info)(void);
        void       *(*create)(void);
        void        (*destroy)(void *h);
        void        (*set_mem_backend)(void *h,
                                       void (*read_fn)(void *, uint64_t,
                                                       uint8_t *, uint32_t),
                                       void (*write_fn)(void *, uint64_t,
                                                        const uint8_t *,
                                                        uint32_t),
                                       void *ctx);
        int         (*load_elf)(void *h, const char *path, uint32_t *out_entry);
        void        (*start)(void *h, uint32_t start_addr);
        bool        (*tick)(void *h);
        bool        (*halted)(void *h);
        bool        (*wfi)(void *h);
        uint32_t    (*mailbox_read)(void *h, uint32_t index);
        void        (*mailbox_write)(void *h, uint32_t index, uint32_t value);
    } abi_;

    // Optional trace ABI. Resolved with dlsym but deliberately *not* fatal on
    // absence, unlike Abi above: a libcoralnpu-gem5.so built before the tap
    // existed must still load and run. Missing symbols mean "no tracing
    // available", not "version mismatch".
    struct AbiTrace
    {
        int      (*open)(void *h, uint64_t (*tick_fn)(void *), void *ctx,
                         int64_t addr_offset);
        void     (*close)(void *h);
        uint64_t (*emitted)(void *h);
        uint64_t (*anomalies)(void *h);
    } traceAbi_;

    // Configuration --------------------------------------------------
    const std::string libraryPath_;
    const std::string kernelPath_;
    const bool        autoStart_;
    const bool        exitOnComplete_;
    const bool        shareMemory_;
    const bool        traceEnable_;
    const int64_t     traceAddrOffset_;
    // PIO base/size/latency live in BasicPioDevice as pioAddr/pioSize/pioDelay.

    // State ----------------------------------------------------------
    EventFunctionWrapper tickEvent_;
    uint32_t             entryPc_;
    bool                 started_;
    bool                 traceActive_;
    uint64_t             cycles_;
};

} // namespace gem5

#endif // __DEV_CORALNPU_CORALNPU_DEV_HH__
