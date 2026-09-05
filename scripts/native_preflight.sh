#!/usr/bin/env bash
# Read-only readiness check for the native Ubuntu workflow.  This script does
# not install packages, build sources, apply patches, or modify user settings.

set -u

SELF_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=native_env.sh
. "$SELF_DIR/native_env.sh"

# Keep these in sync with UPSTREAM.md.
GEM5_REV=2721ed751edac7d4cf3df574c6e0293343a14ba2
CORALNPU_REV=fcb74cfe79dbd184b9c53539490994e701981f80
VORTEX_REV=d76b7f24e658867ab57e3942d7c648c3e6af072d
SOFTFLOAT_REV=b51ef8f3201669b2288104c28546fc72532a1ea4
VORTEX_RAMULATOR_REV=e62c84a6f0e06566ba6e182d308434b4532068a5
COCOGFX_REV=b1befdb36df8af7ac9e2c96acaf81957aab5d107
MEMSIM_REV=7945650579c44713ddec80acc2c82ae34e1f19a5

failures=0

ok() {
    printf '  ok   %s\n' "$*"
}

bad() {
    printf '  MISS %s\n' "$*" >&2
    failures=$((failures + 1))
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 -> $(command -v "$1")"
    else
        bad "命令 $1"
    fi
}

check_directory() {
    if [ -d "$1" ]; then
        ok "$2 -> $1"
    else
        bad "$2 目录 $1"
    fi
}

check_file() {
    if [ -f "$1" ]; then
        ok "$2 -> $1"
    else
        bad "$2 $1"
    fi
}

check_executable() {
    if [ -x "$1" ]; then
        ok "$2 -> $1"
    else
        bad "$2 $1"
    fi
}

check_revision() {
    local label=$1 source_tree=$2 expected=$3
    local actual=

    if ! git -C "$source_tree" rev-parse --is-inside-work-tree \
            >/dev/null 2>&1; then
        bad "$label 无法读取 Git revision: $source_tree"
        return
    fi
    actual=$(git -C "$source_tree" rev-parse HEAD 2>/dev/null)

    if [ "$actual" = "$expected" ]; then
        ok "$label revision $actual"
    else
        bad "$label revision 期望 $expected，实际 ${actual:-<empty>}"
    fi
}

echo "Native Linux environment"
echo "  project    $HET_PROJECT_ROOT"
echo "  gem5       $GEM5_HOME"
echo "  CoralNPU   $CORALNPU_HOME"
echo "  Vortex     $VORTEX_HOME"
echo "  VX build   $VORTEX_BUILD"
echo "  mem_sim    $MEMSIM_HOME"
echo "  hbm_sim    $MEMSIM_BIN"

echo
echo "Commands"
for command_name in git make gcc g++ python3 cmake iverilog vvp verilator bazel; do
    check_command "$command_name"
done

echo
echo "Source trees"
check_directory "$GEM5_HOME/.git" "gem5"
check_directory "$CORALNPU_HOME/.git" "CoralNPU"
check_directory "$VORTEX_HOME/.git" "Vortex"
check_directory "$MEMSIM_HOME/.git" "mem_sim"
check_file "$MEMSIM_HOME/CMakeLists.txt" "mem_sim source"
check_file "$VORTEX_HOME/third_party/ramulator/CMakeLists.txt" \
    "Vortex Ramulator dependency source"

echo
echo "Pinned source revisions"
check_revision "gem5" "$GEM5_HOME" "$GEM5_REV"
check_revision "CoralNPU" "$CORALNPU_HOME" "$CORALNPU_REV"
check_revision "Vortex" "$VORTEX_HOME" "$VORTEX_REV"
check_revision "Vortex SoftFloat" "$VORTEX_HOME/third_party/softfloat" \
    "$SOFTFLOAT_REV"
check_revision "Vortex Ramulator dependency" \
    "$VORTEX_HOME/third_party/ramulator" "$VORTEX_RAMULATOR_REV"
check_revision "Vortex CocoGFX" "$VORTEX_HOME/third_party/cocogfx" \
    "$COCOGFX_REV"
check_revision "mem_sim/hbm_sim" "$MEMSIM_HOME" "$MEMSIM_REV"

echo
echo "Run-ready artifacts"
check_executable "$GEM5_HOME/build/X86/gem5.opt" "gem5.opt"
check_executable "$GEM5_HOME/.venv/bin/scons" "gem5 SCons"
check_file "$GEM5_HOME/configs/het/het_system.py" "installed three-source config"
check_file "$GEM5_HOME/build/X86/params/HetAxiMonitor.hh" \
    "built HetAxiMonitor params"
check_file "$GEM5_HOME/build/X86/params/UnifiedTimingMemory.hh" \
    "built functional memory params"
check_file "$GEM5_HOME/build/X86/params/VortexGPGPU.hh" \
    "built Vortex SimObject params"
check_file "$GEM5_HOME/build/X86/params/CoralNPU.hh" \
    "built CoralNPU SimObject params"
check_executable "$MEMSIM_BIN" "external hbm_sim"
check_file "$VORTEX_HOME/third_party/ramulator/libramulator.so" \
    "Vortex Ramulator dependency library"
check_file "$VORTEX_BUILD/sim/simx/libvortex-gem5.so" "Vortex gem5 library"
check_file "$VORTEX_BUILD/sw/runtime/libvortex.so" "Vortex host runtime"
check_file "$VORTEX_BUILD/sw/runtime/libvortex-gem5-x86_64.so" "Vortex gem5 driver"
check_executable "$VORTEX_BUILD/tests/regression/vecadd/vecadd" \
    "Vortex vecadd host workload"
check_file "$VORTEX_BUILD/tests/regression/vecadd/kernel.vxbin" "Vortex vecadd kernel"
check_file "$CORALNPU_HOME/bazel-bin/gem5int/libcoralnpu-gem5.so" \
    "CoralNPU gem5 library"
CORALNPU_BAZEL_OUT=$(readlink -f "$CORALNPU_HOME/bazel-out" 2>/dev/null || true)
CORALNPU_KERNEL=
if [ -n "$CORALNPU_BAZEL_OUT" ]; then
    CORALNPU_KERNEL=$(find "$CORALNPU_BAZEL_OUT" \
        -path '*/gem5int/ddr_touch.elf' -type f -print -quit 2>/dev/null)
fi
check_file "$CORALNPU_KERNEL" "CoralNPU ddr_touch workload"
check_file "$HET_PROJECT_ROOT/workloads/three_source/host_main.cpp" \
    "three-source host workload source"

echo
echo "Versions"
uname -srmo | sed 's/^/  /'
gcc --version | sed -n '1s/^/  /p'
python3 --version 2>&1 | sed 's/^/  /'
iverilog -V 2>&1 | sed -n '1s/^/  /p'
verilator --version 2>&1 | sed 's/^/  /'
if [ -f "$CORALNPU_HOME/.bazelversion" ]; then
    sed 's/^/  CoralNPU .bazelversion: /' "$CORALNPU_HOME/.bazelversion"
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "READY: native Linux environment can run the full three-source workflow."
else
    echo "NOT READY: $failures required command/source/artifact checks failed." >&2
    echo "Build the missing items in the project manual docs/USER_MANUAL.md, then rerun this script." >&2
    exit 1
fi
