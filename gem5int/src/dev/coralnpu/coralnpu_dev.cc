// CoralNPU gem5 SimObject. Design rationale is in coralnpu_dev.hh.

#include "dev/coralnpu/coralnpu_dev.hh"

#include <dlfcn.h>

#include "base/logging.hh"
#include "base/trace.hh"
#include "debug/CoralNPU.hh"
#include "mem/packet_access.hh"
#include "mem/port_proxy.hh"
#include "sim/core.hh"
#include "sim/sim_exit.hh"
#include "sim/system.hh"

namespace gem5
{

namespace {

template <typename T>
T dlsym_or_fatal(void *handle, const char *symbol, const char *libpath)
{
    void *p = dlsym(handle, symbol);
    if (p == nullptr) {
        fatal("CoralNPU: dlsym(%s) failed in %s: %s",
              symbol, libpath, dlerror());
    }
    return reinterpret_cast<T>(p);
}

// For the additive trace ABI: absence is a valid outcome (older library), so
// return nullptr instead of fatal-ing. dlerror() is cleared so a later failed
// dlsym_or_fatal reports its own error, not this one.
template <typename T>
T dlsym_optional(void *handle, const char *symbol)
{
    void *p = dlsym(handle, symbol);
    if (p == nullptr) {
        dlerror();
    }
    return reinterpret_cast<T>(p);
}

} // namespace

CoralNPU::CoralNPU(const Params &p)
  : BasicPioDevice(p, p.pio_size),
    libHandle_(nullptr),
    deviceHandle_(nullptr),
    abi_{},
    traceAbi_{},
    libraryPath_(p.library),
    kernelPath_(p.kernel),
    autoStart_(p.auto_start),
    exitOnComplete_(p.exit_on_complete),
    shareMemory_(p.share_memory),
    traceEnable_(p.trace_enable),
    traceAddrOffset_(p.trace_addr_offset),
    tickEvent_([this]{ this->tick(); }, name() + ".tickEvent"),
    entryPc_(0),
    started_(false),
    traceActive_(false),
    cycles_(0)
{
    if (libraryPath_.empty()) {
        fatal("CoralNPU: 'library' parameter is required "
              "(path to libcoralnpu-gem5.so)");
    }

    libHandle_ = dlopen(libraryPath_.c_str(), RTLD_LAZY | RTLD_LOCAL);
    if (libHandle_ == nullptr) {
        fatal("CoralNPU: dlopen('%s') failed: %s", libraryPath_, dlerror());
    }

    // Resolve the ABI surface up-front. Any missing symbol is a hard build
    // mismatch — fatal at construction rather than mid-simulation.
    abi_.build_info      = dlsym_or_fatal<const char*(*)(void)>
                            (libHandle_, "coralnpu_gem5_build_info",      libraryPath_.c_str());
    abi_.create          = dlsym_or_fatal<void*(*)(void)>
                            (libHandle_, "coralnpu_gem5_create",          libraryPath_.c_str());
    abi_.destroy         = dlsym_or_fatal<void(*)(void*)>
                            (libHandle_, "coralnpu_gem5_destroy",         libraryPath_.c_str());
    abi_.set_mem_backend = dlsym_or_fatal<void(*)(void*,
                              void(*)(void*, uint64_t, uint8_t*, uint32_t),
                              void(*)(void*, uint64_t, const uint8_t*, uint32_t),
                              void*)>
                            (libHandle_, "coralnpu_gem5_set_mem_backend", libraryPath_.c_str());
    abi_.load_elf        = dlsym_or_fatal<int(*)(void*, const char*, uint32_t*)>
                            (libHandle_, "coralnpu_gem5_load_elf",        libraryPath_.c_str());
    abi_.start           = dlsym_or_fatal<void(*)(void*, uint32_t)>
                            (libHandle_, "coralnpu_gem5_start",           libraryPath_.c_str());
    abi_.tick            = dlsym_or_fatal<bool(*)(void*)>
                            (libHandle_, "coralnpu_gem5_tick",            libraryPath_.c_str());
    abi_.halted          = dlsym_or_fatal<bool(*)(void*)>
                            (libHandle_, "coralnpu_gem5_halted",          libraryPath_.c_str());
    abi_.wfi             = dlsym_or_fatal<bool(*)(void*)>
                            (libHandle_, "coralnpu_gem5_wfi",             libraryPath_.c_str());
    abi_.mailbox_read    = dlsym_or_fatal<uint32_t(*)(void*, uint32_t)>
                            (libHandle_, "coralnpu_gem5_mailbox_read",    libraryPath_.c_str());
    abi_.mailbox_write   = dlsym_or_fatal<void(*)(void*, uint32_t, uint32_t)>
                            (libHandle_, "coralnpu_gem5_mailbox_write",   libraryPath_.c_str());

    // Additive trace ABI — optional by design; see AbiTrace in the header.
    traceAbi_.open      = dlsym_optional<int(*)(void*, uint64_t(*)(void*), void*,
                                               int64_t)>
                            (libHandle_, "coralnpu_gem5_trace_open");
    traceAbi_.close     = dlsym_optional<void(*)(void*)>
                            (libHandle_, "coralnpu_gem5_trace_close");
    traceAbi_.emitted   = dlsym_optional<uint64_t(*)(void*)>
                            (libHandle_, "coralnpu_gem5_trace_emitted");
    traceAbi_.anomalies = dlsym_optional<uint64_t(*)(void*)>
                            (libHandle_, "coralnpu_gem5_trace_anomalies");

    inform("CoralNPU: %s", abi_.build_info());
    inform("CoralNPU: library=%s", libraryPath_);
    inform("CoralNPU: pio[ctrl/status/mailbox]=[0x%llx,+0x%llx)",
           static_cast<unsigned long long>(pioAddr),
           static_cast<unsigned long long>(pioSize));

    deviceHandle_ = abi_.create();
    if (deviceHandle_ == nullptr) {
        fatal("CoralNPU: coralnpu_gem5_create returned NULL");
    }
}

CoralNPU::~CoralNPU()
{
    // Before destroy(): the tap lives inside the device object.
    closeTrace();
    if (deviceHandle_ != nullptr && abi_.destroy != nullptr) {
        abi_.destroy(deviceHandle_);
    }
    if (libHandle_ != nullptr) {
        dlclose(libHandle_);
    }
}

// ---- AXI master memory backend ---------------------------------------------

void
CoralNPU::memReadTrampoline(void *ctx, uint64_t addr, uint8_t *dst,
                            uint32_t size)
{
    static_cast<CoralNPU *>(ctx)->memRead(addr, dst, size);
}

void
CoralNPU::memWriteTrampoline(void *ctx, uint64_t addr, const uint8_t *src,
                             uint32_t size)
{
    static_cast<CoralNPU *>(ctx)->memWrite(addr, src, size);
}

void
CoralNPU::memRead(uint64_t addr, uint8_t *dst, uint32_t size)
{
    // Functional, not timing: the AXI read callback must produce data in the
    // same cycle it is called (see coralnpu_dev.hh). readBlob fatals if the
    // address is unmapped, which is the behaviour we want — silently returning
    // zeros would show up much later as a mysteriously wrong kernel result.
    sys->physProxy.readBlob(addr, dst, size);
}

void
CoralNPU::memWrite(uint64_t addr, const uint8_t *src, uint32_t size)
{
    sys->physProxy.writeBlob(addr, src, size);
}

// ---- Tracing ---------------------------------------------------------------

uint64_t
CoralNPU::curTickTrampoline(void *ctx)
{
    // ctx is unused: curTick() is the global event-queue clock and there is
    // exactly one. The parameter is kept so the library's tick-provider
    // signature stays generic across the three trace sources.
    (void)ctx;
    return static_cast<uint64_t>(curTick());
}

void
CoralNPU::openTrace()
{
    if (!traceEnable_ || traceAbi_.open == nullptr) {
        // trace_enable=false, or the library predates the trace ABI.
        return;
    }
    const int rc = traceAbi_.open(deviceHandle_, &CoralNPU::curTickTrampoline,
                                  this, traceAddrOffset_);
    if (rc != 0) {
        // Overwhelmingly the normal case: HETTRACE_DIR is simply not set.
        return;
    }
    traceActive_ = true;
    inform("CoralNPU: memory trace active (AXI master tap, addr_offset=%lld)",
           static_cast<long long>(traceAddrOffset_));

    // gem5 does not reliably destroy SimObjects at exit, so the destructor
    // alone is not enough to get the buffered tail and the .meta.json sidecar
    // onto disk.
    registerExitCallback([this]{ this->closeTrace(); });
}

void
CoralNPU::closeTrace()
{
    if (!traceActive_) return;
    traceActive_ = false;

    const uint64_t n = (traceAbi_.emitted != nullptr)
                           ? traceAbi_.emitted(deviceHandle_) : 0;
    const uint64_t bad = (traceAbi_.anomalies != nullptr)
                             ? traceAbi_.anomalies(deviceHandle_) : 0;
    if (traceAbi_.close != nullptr) {
        traceAbi_.close(deviceHandle_);
    }
    inform("CoralNPU: memory trace closed, %llu records",
           static_cast<unsigned long long>(n));

    // Loud on purpose. A non-zero count means the core issued a multi-beat AXI
    // master burst, and at that point neither this tap's one-callback-equals-
    // one-16-byte-window reading nor the upstream reference DDR backend is
    // correct — so the trace is not trustworthy. Better a warning nobody can
    // miss than a plausible-looking but wrong trace.
    if (bad != 0) {
        warn("CoralNPU: %llu trace anomalies (multi-beat AXI master burst or "
             "out-of-range access) — this trace is NOT trustworthy; see "
             "coralnpu_trace.h",
             static_cast<unsigned long long>(bad));
    }
}

// ---- Lifecycle -------------------------------------------------------------

void
CoralNPU::startup()
{
    BasicPioDevice::startup();

    if (shareMemory_) {
        // Route the AXI master through gem5's physical memory so the NPU sees
        // the bytes the host CPU actually wrote. Without this the library uses
        // a private array and "shared buffer" is only shared in address, not
        // in data.
        abi_.set_mem_backend(deviceHandle_,
                             &CoralNPU::memReadTrampoline,
                             &CoralNPU::memWriteTrampoline,
                             this);
        inform("CoralNPU: AXI master routed to gem5 physical memory "
               "(functional access)");
    } else {
        inform("CoralNPU: AXI master backed by the library's private DDR "
               "array — the shared buffer is NOT data-coherent with the host");
    }

    // Before any tick is scheduled, so no request can slip past the tap.
    openTrace();

    if (kernelPath_.empty()) {
        inform("CoralNPU: no kernel — idle until the host writes REG_CTRL");
        return;
    }

    // load_elf and start use the library's blocking AXI-slave path, which
    // advances CoralNPU's clock internally. Doing it here, before the first
    // tickEvent_ is scheduled, is what keeps that legal.
    if (abi_.load_elf(deviceHandle_, kernelPath_.c_str(), &entryPc_) != 0) {
        fatal("CoralNPU: coralnpu_gem5_load_elf('%s') failed", kernelPath_);
    }
    inform("CoralNPU: kernel=%s loaded, entry PC=0x%08x",
           kernelPath_, entryPc_);

    if (autoStart_) {
        loadAndStart();
    } else {
        inform("CoralNPU: waiting for the host to write REG_CTRL bit0");
    }
}

void
CoralNPU::loadAndStart()
{
    if (started_) {
        // Covers both "still running" and "already finished": start is
        // one-shot for the lifetime of the device (see tick()).
        warn("CoralNPU: start ignored — the kernel has already been started "
             "once (halted=%d, ticking=%d); start is one-shot",
             static_cast<int>(abi_.halted(deviceHandle_)),
             static_cast<int>(tickEvent_.scheduled()));
        return;
    }
    started_ = true;
    abi_.start(deviceHandle_, entryPc_);
    if (!tickEvent_.scheduled()) {
        schedule(tickEvent_, clockEdge(Cycles(1)));
    }
    DPRINTF(CoralNPU, "kernel started at PC 0x%08x\n", entryPc_);
}

void
CoralNPU::tick()
{
    ++cycles_;
    // Exactly one CoralNPU cycle per gem5 event. See coralnpu_dev.hh.
    if (abi_.tick(deviceHandle_)) {
        schedule(tickEvent_, clockEdge(Cycles(1)));
        return;
    }

    inform("CoralNPU: kernel finished after %llu cycles (halted=%d wfi=%d)",
           static_cast<unsigned long long>(cycles_),
           static_cast<int>(abi_.halted(deviceHandle_)),
           static_cast<int>(abi_.wfi(deviceHandle_)));

    if (exitOnComplete_) {
        // Standalone smoke-test path: nothing else is driving the simulation,
        // so stopping here is the only way it ends.
        closeTrace();
        exitSimLoop("CoralNPU: kernel complete");
    }
    // Otherwise: stay dormant and let the host collect the result by polling
    // REG_STATUS / reading the mailbox.
    //
    // Dormant is terminal: start is one-shot, so a second REG_CTRL write is
    // refused with a warning rather than restarting a halted core from a
    // state this project has never verified (see loadAndStart). One kernel
    // per device per gem5 run.
}

// ---- PIO -------------------------------------------------------------------

Tick
CoralNPU::read(PacketPtr pkt)
{
    const Addr off = pkt->getAddr() - pioAddr;
    uint32_t value = 0;

    switch (off) {
      case REG_STATUS:
        value = (abi_.halted(deviceHandle_) ? 1u : 0u)
              | (abi_.wfi(deviceHandle_)    ? 2u : 0u)
              | (tickEvent_.scheduled()     ? 4u : 0u);
        break;
      case REG_ENTRY:
        value = entryPc_;
        break;
      case REG_EMITTED:
        value = static_cast<uint32_t>(
            (traceAbi_.emitted != nullptr) ? traceAbi_.emitted(deviceHandle_)
                                           : 0);
        break;
      case REG_CTRL:
        // Write-only in spirit; reads back the start bit so a host can tell
        // whether its write took effect.
        value = started_ ? 1u : 0u;
        break;
      default:
        if (off >= REG_MAILBOX0 && off <= REG_MAILBOX3) {
            value = abi_.mailbox_read(deviceHandle_,
                                      uint32_t((off - REG_MAILBOX0) / 4));
        } else {
            warn("CoralNPU: PIO read from unmapped offset 0x%llx",
                 static_cast<unsigned long long>(off));
        }
        break;
    }

    pkt->setUintX(static_cast<uint64_t>(value), ByteOrder::little);
    pkt->makeAtomicResponse();
    return pioDelay;
}

Tick
CoralNPU::write(PacketPtr pkt)
{
    const Addr off = pkt->getAddr() - pioAddr;
    const uint32_t value =
        static_cast<uint32_t>(pkt->getUintX(ByteOrder::little));

    switch (off) {
      case REG_CTRL:
        if ((value & 1u) != 0) {
            if (kernelPath_.empty()) {
                warn("CoralNPU: REG_CTRL start ignored — no kernel loaded");
            } else {
                loadAndStart();
            }
        }
        break;
      default:
        if (off >= REG_MAILBOX0 && off <= REG_MAILBOX3) {
            abi_.mailbox_write(deviceHandle_,
                               uint32_t((off - REG_MAILBOX0) / 4), value);
        } else {
            warn("CoralNPU: PIO write to unmapped offset 0x%llx",
                 static_cast<unsigned long long>(off));
        }
        break;
    }

    pkt->makeAtomicResponse();
    return pioDelay;
}

} // namespace gem5
