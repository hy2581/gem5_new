#!/bin/bash
# host ↔ Vortex 字节共享验收：让 Vortex 自带的 vecadd 走完整的 host runtime →
# CP → 核 路径，然后在两份 trace 里把这次交接找出来。
#
#   GEM5_HOME=$HOME/gem5 VORTEX_HOME=$HOME/vortex-gpu/vortex \
#       gem5int/tests/run_vortex_shared.sh
#
# 与另外两个脚本的分工：
#   run_vortex.sh  单设备验收 —— gem5 能把 Vortex 跑起来、tap 能落记录。host 那条
#                  腿根本不在里面（内核是 standalone 预载的）。
#   run_het.sh     host + CoralNPU 的异构验收。
#   本脚本         host + Vortex 的异构验收，也就是 run_het.sh 在 Vortex 这边的
#                  对应物。
#
# ---- 为什么必须用 vecadd 而不是自己写个负载 ----
#
# host 侧碰不到 Vortex 的设备内存 —— 它只能经 BAR，而 BAR 上的字节要变成"内核看
# 得见的输入"，中间必经 Vortex 的 host runtime（建队列、mem_alloc、mem_copy、提
# 交 CMD_LAUNCH）。那套 ABI 只有 libvortex.so 实现，自己写等于重写一遍 runtime。
# vecadd 是上游的回归测试，它自检全部 64 个结果，所以 "PASSED!" 这一行本身就是字
# 节真的共享了的功能性证据：输入是 host 写的，结果是设备算的，host 又读回来核对过。
#
# ---- 这个脚本在 trace 层面验什么 ----
#
#   1. 正向跑通，且两份 trace 都落盘、计数器干净。
#   2. Vortex 的 trace 里同时有**两类**记录：核发出的（ctx = hart_id）和 CP 的
#      DMA（ctx = 0xffffffff、带 kFlagDma）。少了后者就是本项目踩过的坑 —— 见下。
#   3. DMA 记录同时覆盖暂存区与设备缓冲，也就是把 host 那一侧接上核那一侧的那段
#      搬运确实被记下来了。
#   4. 两个源在 vortex_bar 里有共享的 cache line，且 validate 认这是交接。
#   5. 反向对照：--vortex-trace-dev-view 关掉地址偏移之后，Vortex 的记录会跑进
#      host_heap。
#
# ---- 第 2 步为什么是重点 ----
#
# 一开始 Vortex 的 tap 只挂在 vortex::Memory 的 pre_send hook 上。那个位置看不见
# CP 的 DMA（CP 直接读写 simx::RAM，不过 cache 也不过 Memory），于是：
#   - host 的记录全在暂存区（dev 0xfc00_0000 上方的 64MB aperture）；
#   - 核的记录全在设备缓冲（dev 0x10000 一带）和代码段（dev 0x8000_0000）；
#   - 两边地址集**完全不相交**，共享 line 数 = 0。
# 而计算是对的（PASSED!）。也就是说 trace 会让下游得出"两个源没有共享"的结论，而
# 字节其实是共享的 —— 把两边接起来的那次搬运正是 CP 干的，只是没被记。这类"数据
# 齐全、结论相反"的缺陷比崩溃难查得多，所以单独立一步守住它。
#
# ---- 两个看着像控制、其实不能用的对照 ----
#
# 都真跑过，结论记在这里免得后人重走：
#
#   --vortex-bar-skew 0x10000000
#     把设备的 BAR 挪开。因果上有效（host 拿不到设备，跑到 max_ticks 也不会
#     PASSED），但**不能**用共享 line 数来判：host 访问的物理地址是
#     PIN_BASE + dev（driver.h 的 constexpr 决定，与 skew 无关），而 tap 记的是
#     dev' + PIN_BASE，其中 dev' 是 CP 从 ring 里读到的设备地址、同样与 skew 无
#     关。两个数**数值上照样相等**，共享 line 数不降。它慢（要跑到 max_ticks）、
#     判据还容易误用，所以不放进默认流程。
#
#   --vortex-trace-dev-view 用来判共享 line 数
#     记录会掉进 host_heap（dev 0x8000_0000 的代码段撞上 host 的 0x8000_0000 私
#     有堆），于是量出 65 条"共享" —— 全是假的。所以第 5 步只用它判**区域归属**，
#     不判共享。
#
# 更一般的结论：两个源的地址集重合度只有在两边都换算到同一个物理空间之后才有意
# 义。这就是 het_system.py 把 BAR 视角设成默认的原因。

set -euo pipefail

SELF_DIR=$(dirname "$(readlink -f "$0")")
PROJ_DIR=$(dirname "$(dirname "$SELF_DIR")")
GEM5_HOME=${GEM5_HOME:-$HOME/gem5}
VORTEX_HOME=${VORTEX_HOME:-$HOME/vortex-gpu/vortex}
VORTEX_BUILD=${VORTEX_BUILD:-$(dirname "$VORTEX_HOME")/vxbuild}
GEM5_BIN=${GEM5_BIN:-$GEM5_HOME/build/X86/gem5.opt}
CONFIG="$GEM5_HOME/configs/het/het_system.py"
SO="$VORTEX_BUILD/sim/simx/libvortex-gem5.so"
RT_DIR="$VORTEX_BUILD/sw/runtime"
TEST_DIR="$VORTEX_BUILD/tests/regression/vecadd"
N=${N:-64}

fail() { echo "错误: $*" >&2; exit 1; }

[ -x "$GEM5_BIN" ] || fail "找不到 $GEM5_BIN，先 scons build/X86/gem5.opt"
[ -f "$CONFIG" ]   || fail "找不到 $CONFIG，先跑 gem5int/install.sh"
[ -f "$SO" ] || fail "找不到 $SO
      先 make -C $VORTEX_BUILD/sim/simx USE_GEM5=1 libvortex-gem5"

# host runtime 是两个 .so：libvortex.so 按 VORTEX_DRIVER 去 dlopen
# libvortex-gem5-x86_64.so。缺任何一个，被仿真进程都会死在动态链接上，报的是
# "cannot open shared object file"，看不出少的是哪一层。
for lib in libvortex.so libvortex-gem5-x86_64.so; do
    [ -f "$RT_DIR/$lib" ] || fail "找不到 $RT_DIR/$lib
      先 make -C $VORTEX_BUILD/sw/runtime"
done

# vecadd 与它的 .vxbin。.vxbin 要 Vortex 的 LLVM 工具链才编得出来，本项目不提供，
# 所以这里只检查、不代劳。
[ -x "$TEST_DIR/vecadd" ] || fail "找不到 $TEST_DIR/vecadd
      先 make -C $VORTEX_BUILD/tests/regression/vecadd"
[ -f "$TEST_DIR/kernel.vxbin" ] || fail "找不到 $TEST_DIR/kernel.vxbin
      要 Vortex 的 RISC-V LLVM 工具链，见 docs/04-integration.md"

grep -q trace_enable "$GEM5_HOME/build/X86/params/VortexGPGPU.hh" 2>/dev/null || \
    fail "gem5 里的 VortexGPGPU 没有 trace_enable 参数
      依次跑：
        VORTEX_HOME=$VORTEX_HOME $PROJ_DIR/vortexint/install.sh
        GEM5_HOME=$GEM5_HOME $VORTEX_HOME/sim/simx/gem5/install.sh
        scons -C $GEM5_HOME build/X86/gem5.opt -j\$(nproc)"

# 见 run_vortex.sh 里同一段注释：机器上另装的 ramulator2 会抢在 .so 自己的
# RUNPATH 前面被加载，dlopen 死在一个跟 ramulator 看不出关系的 undefined symbol 上。
RAMULATOR_DIR="$VORTEX_HOME/third_party/ramulator"
[ -f "$RAMULATOR_DIR/libramulator.so" ] || \
    fail "找不到 $RAMULATOR_DIR/libramulator.so，先 make -C $VORTEX_HOME/third_party"
export LD_LIBRARY_PATH="$RAMULATOR_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export PYTHONPATH="$PROJ_DIR/tools${PYTHONPATH:+:$PYTHONPATH}"

echo "gem5:       $GEM5_BIN"
echo "Vortex 库:  $SO"
echo "host 程序:  $TEST_DIR/vecadd -n$N"
echo "内核:       $TEST_DIR/kernel.vxbin ($(stat -c%s "$TEST_DIR/kernel.vxbin") 字节)"

OUT=$(mktemp -d)
DEVOUT=$(mktemp -d)
echo "HETTRACE_DIR=$OUT"

# vecadd 是按**相对路径**打开 kernel.vxbin 的，所以工作目录必须是它自己的目录。
# 在别处跑会得到 vx_module_load_file 返回 VX_ERR_INVALID_VALUE —— 那个错误码
# 完全看不出是"文件没找到"。
run_gem5() { # $1=HETTRACE_DIR  $2..=额外参数
    local hd="$1"; shift
    local m5out; m5out=$(mktemp -d)
    ( cd "$TEST_DIR" && HETTRACE_DIR="$hd" "$GEM5_BIN" --outdir="$m5out" "$CONFIG" \
        --cmd "$TEST_DIR/vecadd" --options="-n$N" \
        --vortex-library "$SO" --vortex-host-rt-dir "$RT_DIR" "$@" 2>&1 )
}

# ---- 1. 正向跑 --------------------------------------------------------------
echo
echo "---- 1/5 host runtime 驱动 Vortex 跑 vecadd ----"
set +e
LOG=$(run_gem5 "$OUT")
RC=$?
set -e
echo "$LOG" | grep -E "VortexGPGPU: (pin|memory trace)|^(PASSED|FAIL)|^---- 结束" \
    | sed 's/^.*info: /  /' || true
[ "$RC" = "0" ] || { echo "$LOG" | tail -20; fail "gem5 返回 $RC（期望 0）"; }
echo "$LOG" | grep -q "^PASSED!" || { echo "$LOG" | tail -20; fail "vecadd 自检没通过"; }
for f in host.hettrace vortex.hettrace; do
    [ -f "$OUT/$f" ] || fail "没有产出 $f"
done
echo "  ok   vecadd 自检通过 —— 输入是 host 写的、结果是设备算的，字节确实共享"

# ---- 2. meta.json 的计数器 --------------------------------------------------
echo
echo "---- 2/5 两份 meta.json 的计数器 ----"
python3 - "$OUT" <<'PY' || exit 1
import json, os, sys
d = sys.argv[1]
bad = []
for name, period in (("host", 500), ("vortex", 1000)):
    m = json.load(open(os.path.join(d, name + ".hettrace.meta.json")))
    if m["emitted"] == 0:
        bad.append("%s: emitted=0，tap 没接上" % name)
    if m["unmapped"]:
        bad.append("%s: unmapped=%d，地址与 addrmap.json 不一致" % (name, m["unmapped"]))
    if m["non_monotonic"]:
        bad.append("%s: non_monotonic=%d，时间戳回退" % (name, m["non_monotonic"]))
    if m["clock_period_ticks"] != period:
        bad.append("%s: clock_period_ticks=%d，期望 %d" % (name, m["clock_period_ticks"], period))
    if m["level"] != 0:
        bad.append("%s: level=%d，期望 0 (kLevelPostLlc)" % (name, m["level"]))
    print("       %-7s emitted=%-6d bytes=%-7d 区间 [%d, %d]"
          % (name, m["emitted"], m["bytes"], m["first_tick"], m["last_tick"]))
for b in bad:
    print("  FAIL " + b)
if not bad:
    print("  ok   两源 unmapped=0 non_monotonic=0，时钟周期与 addrmap.json 一致")
sys.exit(1 if bad else 0)
PY

# ---- 3. 核记录 + CP DMA 记录 ------------------------------------------------
echo
echo "---- 3/5 Vortex trace 里核与 CP DMA 两类记录都在 ----"
python3 - "$OUT" <<'PY' || exit 1
import sys
from hettrace import reader

BAR       = 0x100000000            # het_system.py 的 VORTEX_BAR[0]
STAGING   = BAR + 0xfc000000       # vortex.cpp: PIN_REGION_SIZE - GEM5_HOST_APERTURE
BUF_LIMIT = BAR + 0x10000000       # 设备分配器从 ALLOC_BASE_ADDR 往上长，缓冲都在低位
FLAG_DMA  = 1 << 4
DMA_CTX   = 0xffffffff             # vortex_trace.h 的 kDmaCtx

recs = list(reader.read_records(sys.argv[1] + "/vortex.hettrace"))
dma  = [r for r in recs if r.flags & FLAG_DMA]
core = [r for r in recs if not (r.flags & FLAG_DMA)]
print("       共 %d 条：CP DMA %d 条 / 核 %d 条" % (len(recs), len(dma), len(core)))

bad = []
if not core:
    bad.append("一条核记录都没有 —— pre_send hook 没接上，或者访存全被 cache 吃了")
if not dma:
    bad.append("一条 CP DMA 记录都没有 —— vortex_gpgpu.cpp 的 dram_{read,write} "
               "hook 里少了 trace_.OnDma，host 与核的交接会显示成毫不相关")
if any(r.ctx != DMA_CTX for r in dma):
    bad.append("DMA 记录的 ctx 不是 kDmaCtx —— 会与 hart 0 的足迹混在一起")
if any(r.ctx == DMA_CTX for r in core):
    bad.append("核记录用了 kDmaCtx 这个哨兵值")

# 这两行是本步的核心判据：搬运的两端都要在 trace 里。只有暂存区那一端 = host 的
# 字节进了设备但没人送到缓冲；只有缓冲那一端 = 缓冲里的字节不知从何而来。
in_staging = [r for r in dma if r.addr >= STAGING]
in_buffer  = [r for r in dma if r.addr < BUF_LIMIT]
if not in_staging:
    bad.append("DMA 记录里没有暂存区（>= 0x%x）的 —— host 那一端没接上" % STAGING)
if not in_buffer:
    bad.append("DMA 记录里没有设备缓冲（< 0x%x）的 —— 核那一端没接上" % BUF_LIMIT)
for b in bad:
    print("  FAIL " + b)
if not bad:
    print("  ok   DMA 两端都在：暂存区 %d 条 + 设备缓冲 %d 条，ctx 与核记录分得开"
          % (len(in_staging), len(in_buffer)))
sys.exit(1 if bad else 0)
PY

# ---- 4. validate + 共享 line -----------------------------------------------
echo
echo "---- 4/5 归并校验与共享 cache line ----"
python3 -m hettrace validate "$OUT" > "$OUT/validate.txt" 2>&1 || {
    cat "$OUT/validate.txt"; fail "validate 没通过"; }
grep -E "交接区|结论" "$OUT/validate.txt" | sed 's/^/  /'
grep -q "交接区 vortex_bar 被 host, vortex 共同访问" "$OUT/validate.txt" || \
    fail "validate 没认出 vortex_bar 是交接区"

python3 - "$OUT" <<'PY' || exit 1
import sys
from hettrace import stats
sizes, pairwise, _lb = stats.footprint(sys.argv[1])
shared = pairwise.get(("host", "vortex"), 0)
print("       足迹 host=%d line / vortex=%d line，共享 %d line"
      % (sizes.get("host", 0), sizes.get("vortex", 0), shared))
if shared == 0:
    print("  FAIL 共享 line = 0 —— 两个源的地址集不相交。第 3 步过了的话，"
          "问题在偏移换算而不在 tap")
    sys.exit(1)
print("  ok   %d 条 cache line 被两个源都碰过" % shared)
PY

# ---- 5. 反向对照：关掉地址偏移 ---------------------------------------------
# 只判区域归属，不判共享 line 数 —— 理由见文件头。
echo
echo "---- 5/5 反向对照：--vortex-trace-dev-view 关掉偏移 ----"
set +e
DEVLOG=$(run_gem5 "$DEVOUT" --vortex-trace-dev-view)
DEVRC=$?
set -e
[ "$DEVRC" = "0" ] || { echo "$DEVLOG" | tail -20; fail "对照跑挂了（gem5 返回 $DEVRC）"; }
echo "$DEVLOG" | grep -q "^PASSED!" || fail "对照跑里 vecadd 没通过 —— 偏移只该影响观测，不该影响行为"

python3 - "$DEVOUT" <<'PY' || exit 1
import sys
from collections import Counter
from hettrace import addrmap, reader
recs = list(reader.read_records(sys.argv[1] + "/vortex.hettrace"))
c = Counter(addrmap.region_of(r.addr) or "unmapped" for r in recs)
print("       Vortex 记录的区域分布: %s" % dict(c))
# 设备内地址 0x8000_0000 是 .vxbin 的代码段，撞上 host 私有堆 host_heap；
# 设备缓冲的 0x10000 一带则直接被 HETTRACE_FILTER=dram 滤掉（不在 trace 窗口里）。
# 两个后果都不是"另一种视角"，是错的归属 —— 这一步就是把它显示出来。
if c.get("vortex_bar"):
    print("  FAIL 关掉偏移之后还有记录落在 vortex_bar —— 说明偏移其实没关掉，"
          "这个对照没起作用")
    sys.exit(1)
if not c.get("host_heap"):
    print("  FAIL 期望看到记录被错归到 host_heap，实际没有。可能是 .vxbin 的装载"
          "地址变了；对照失效，第 4 步的结论就没有旁证了")
    sys.exit(1)
print("  ok   %d 条记录被错归到 host_heap，vortex_bar 里一条不剩 —— 正向那一遍的"
      "区域归属来自偏移，不是巧合" % c["host_heap"])
PY

echo
echo "全部通过"
echo "正向 trace 保留在 $OUT"
echo "对照 trace 保留在 $DEVOUT"
