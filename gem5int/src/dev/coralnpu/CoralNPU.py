# Python SimObject binding for the gem5-side CoralNPU device.
#
# Installed into $GEM5_HOME/src/dev/coralnpu/ by gem5int/install.sh; the
# source of truth is this project's tree.

from m5.objects.Device import BasicPioDevice
from m5.params import *


class CoralNPU(BasicPioDevice):
    type = "CoralNPU"
    cxx_header = "dev/coralnpu/coralnpu_dev.hh"
    cxx_class = "gem5::CoralNPU"

    # Path to libcoralnpu-gem5.so, produced by
    #   bazel build //gem5int:libcoralnpu-gem5.so
    # in the CoralNPU tree after coralnpuint/install.sh has run. Required;
    # the C++ ctor fatals if empty. Use the -rvv variant if the kernel needs
    # the vector unit.
    library = Param.String("Absolute path to libcoralnpu-gem5.so")

    # RISC-V ELF loaded into the core's ITCM at startup(). Leaving it empty
    # gives an idle device: useful for testing the PIO/mailbox path alone,
    # since a start request with no kernel is refused rather than silently
    # running whatever happens to be in TCM.
    kernel = Param.String("", "Optional RISC-V ELF to load at startup")

    # True: run as soon as the simulation starts, no host involvement.
    # False: the kernel is loaded but parked, and the host has to write
    # REG_CTRL bit0 over PIO — which is what the cooperative workload does,
    # because the NPU must not read the shared buffer before the host has
    # filled it.
    auto_start = Param.Bool(False, "Start the kernel from startup()")

    # Terminate the simulation when the kernel halts or hits wfi. Only
    # correct for standalone NPU runs; in the heterogeneous config the host
    # program decides when everything is done, so this stays False and the
    # device just goes dormant.
    exit_on_complete = Param.Bool(
        False, "exitSimLoop() when the kernel finishes"
    )

    # Route the library's AXI master through gem5 physical memory instead of
    # its private DDR array. Without this the NPU and the host agree on
    # *addresses* but not on *bytes*, and a cooperative workload silently
    # computes garbage. The access is functional (zero simulated time) —
    # required, because an AXI read callback has to return data in the same
    # cycle it is called. See the design notes in coralnpu_dev.hh.
    share_memory = Param.Bool(
        True, "Back the AXI master with gem5 physical memory"
    )

    # Control/status/mailbox window. 0x20 of registers is the whole
    # interface; once running, host and NPU talk through the shared buffer.
    #
    # pio_addr is *inherited* from BasicPioDevice, so this line is a plain
    # default-value override, NOT `pio_addr = Param.Addr(...)`. Redeclaring it
    # as a Param compiles and looks right, but it puts a second `Addr pio_addr`
    # into CoralNPUParams that shadows BasicPioDeviceParams::pio_addr — and
    # BasicPioDevice's ctor reads the base one, which nothing ever fills. The
    # device then registers [0x0, +pio_size) on the bus while config.ini shows
    # the address you asked for, and the first host PIO access dies in
    # xbar.cc with "Unable to find destination". pio_size has no such twin:
    # BasicPioDevice has no size param (it takes the size as a ctor argument),
    # so declaring it here is correct.
    pio_addr = 0x30000000
    pio_size = Param.Addr(0x0020, "PIO region size (bytes)")

    # ---- Memory-access tracing (hettrace) ------------------------------
    # Read-only tap on the AXI master port, i.e. exactly the traffic that
    # leaves the NPU for DDR. TCM hits are invisible by construction — they
    # never reach the port.
    #
    # As on the Vortex leg, these params only decide *whether to try*;
    # whether a file appears is decided by HETTRACE_DIR inside the device
    # library, so the shared output directory stays out of the config script.
    # A library built before the trace ABI existed, or an unset HETTRACE_DIR,
    # both mean "no trace" and never an error.
    trace_enable = Param.Bool(
        True,
        "Install the AXI master memory trace tap (no-op unless HETTRACE_DIR "
        "is set in the environment)",
    )

    # Added to every device address before it is recorded. 0 is correct for
    # the recommended setup, where the kernel already uses global physical
    # addresses (see workloads/shared_buffer).
    trace_addr_offset = Param.Int64(
        0, "Offset added to device addresses before recording"
    )
