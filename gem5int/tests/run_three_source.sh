#!/bin/bash
# 三源同时跑一遍：一个 host 程序同时驱动 CoralNPU 和 Vortex，产出三份 trace，归并
# 成一条流。
#
#   GEM5_HOME=$HOME/gem5 CORALNPU_HOME=$HOME/coralnpu \
#       VORTEX_HOME=$HOME/vortex-gpu/vortex gem5int/tests/run_three_source.sh
#
# 与前两个协同验收的分工：
#   run_het.sh            host + CoralNPU，含反向对照（NPU 那条腿的正确性判据）
#   run_vortex_shared.sh  host + Vortex，含反向对照（Vortex 那条腿的正确性判据）
#   本脚本                两条腿**同时**在一个 gem5 进程里，验的是它们合在一起才
#                         能验的那几条：三份 trace 出自同一个 curTick()、两个设备
#                         的活动区间真的重叠、归并出来的单条流里三个源交错。
#
# 所以这里**不再**重复做反向对照 —— 每条腿的"共享是真的"已经由上面两个脚本各自的
# 对照守住了，在这里再跑一遍只是把耗时翻倍。本脚本要守的是别的东西。
#
# ---- 为什么"区间重叠"是一条必须验的性质 ----
#
# 本项目产出的 trace 是喂给下游 DRAM 模拟器的输入。如果两个设备的活动区间不相交
# （host -> Vortex -> host -> NPU 那种串行链就是这样），归并出来的流里永远不会出现
# 两个源夹在一起的片段，下游连"两个 master 同时压同一个控制器"这件事都构造不出来 ——
# 那这份三源 trace 除了"证明三个仿真器能共存"之外没有别的用处。
# `hettrace validate` 会把区间不相交报成 WARN，本脚本第 3 步直接判这一项。
#
# 负载是怎么做到重叠的写在 workloads/three_source/host_main.cpp 的文件头：Vortex 的
# 活异步提交完立刻启动 NPU，NPU 那 1.7 us 整个落在 Vortex 那 148 us 里面。
#
# ---- coralnpu <-> vortex 的共享 line 必须是 0 ----
#
# 第 4 步会把它当成**期望值**来判，不是当成缺陷。vortex_bar 在 4 GiB 之上，而
# CoralNPU 的 AXI 地址只有 32 位 —— 两个设备连指向同一个字节的地址都表达不出来，
# 唯一的通路是 host 中转。哪天这个数不是 0，那说明的是地址映射被改错了（比如
# trace_addr_offset 关了、BAR 被挪到 32 位空间里），不是"终于共享上了"。理由见
# docs/01-address-map.md 的硬约束 1。

set -euo pipefail

SELF_DIR=$(dirname "$(readlink -f "$0")")
PROJ_DIR=$(dirname "$(dirname "$SELF_DIR")")
GEM5_HOME=${GEM5_HOME:-$HOME/gem5}
CORALNPU_HOME=${CORALNPU_HOME:-$HOME/coralnpu}
VORTEX_HOME=${VORTEX_HOME:-$HOME/vortex-gpu/vortex}
VORTEX_BUILD=${VORTEX_BUILD:-$(dirname "$VORTEX_HOME")/vxbuild}
GEM5_BIN=${GEM5_BIN:-$GEM5_HOME/build/X86/gem5.opt}
CONFIG="$GEM5_HOME/configs/het/het_system.py"

HOST_BIN="$PROJ_DIR/workloads/three_source/build/host_main"
VORTEX_SO="$VORTEX_BUILD/sim/simx/libvortex-gem5.so"
RT_DIR="$VORTEX_BUILD/sw/runtime"
VXBIN="$VORTEX_BUILD/tests/regression/vecadd/kernel.vxbin"

fail() { echo "错误: $*" >&2; exit 1; }

[ -x "$GEM5_BIN" ] || fail "找不到 $GEM5_BIN，先 scons build/X86/gem5.opt"
[ -f "$CONFIG" ]   || fail "找不到 $CONFIG，先跑 gem5int/install.sh"

[ -x "$HOST_BIN" ] || fail "找不到 $HOST_BIN
      先建 host 负载：
        VORTEX_HOME=$VORTEX_HOME VORTEX_BUILD=$VORTEX_BUILD \\
            make -C $PROJ_DIR/workloads/three_source"

# ---- Vortex 那条腿要的东西（与 run_vortex_shared.sh 同一套）-------------------
[ -f "$VORTEX_SO" ] || fail "找不到 $VORTEX_SO
      先 make -C $VORTEX_BUILD/sim/simx USE_GEM5=1 libvortex-gem5"
for lib in libvortex.so libvortex-gem5-x86_64.so; do
    [ -f "$RT_DIR/$lib" ] || fail "找不到 $RT_DIR/$lib
      先 make -C $VORTEX_BUILD/sw/runtime"
done
# 本负载自己不带内核，直接用上游 vecadd 编好的那个 .vxbin（要 Vortex 的 LLVM 工具
# 链，见 docs/04-integration.md）。用绝对路径喂给 -k，所以工作目录无所谓 —— 这一点
# 和 vecadd 不同，那个是按相对路径开文件的。
[ -f "$VXBIN" ] || fail "找不到 $VXBIN
      先 make -C $VORTEX_BUILD/tests/regression/vecadd"

grep -q trace_enable "$GEM5_HOME/build/X86/params/VortexGPGPU.hh" 2>/dev/null || \
    fail "gem5 里的 VortexGPGPU 没有 trace_enable 参数，见 docs/04-integration.md"

# 见 run_vortex.sh 里同一段注释：机器上另装的 ramulator2 会抢在 .so 自己的 RUNPATH
# 前面被加载，dlopen 死在一个跟 ramulator 看不出关系的 undefined symbol 上。
RAMULATOR_DIR="$VORTEX_HOME/third_party/ramulator"
[ -f "$RAMULATOR_DIR/libramulator.so" ] || \
    fail "找不到 $RAMULATOR_DIR/libramulator.so，先 make -C $VORTEX_HOME/third_party"
export LD_LIBRARY_PATH="$RAMULATOR_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---- NPU 那条腿要的东西（与 run_het.sh 同一套）-------------------------------
NPU_SO=$(readlink -f "$CORALNPU_HOME/bazel-bin/gem5int/libcoralnpu-gem5.so" 2>/dev/null || true)
[ -n "$NPU_SO" ] && [ -f "$NPU_SO" ] || \
    fail "找不到 libcoralnpu-gem5.so，先 bazel build //gem5int:libcoralnpu-gem5.so"
# bazel-out 是符号链接，find 默认不跟进去。而且 .elf 与 .so 常常不在同一个
# bazel-out 配置目录下（.elf 走的是 RISC-V 交叉工具链的那份配置），所以只能 find，
# 不能照着 .so 的路径拼。
BAZEL_OUT=$(readlink -f "$CORALNPU_HOME/bazel-out" 2>/dev/null || true)
NPU_ELF=$(find "$BAZEL_OUT" -path "*/gem5int/ddr_touch.elf" 2>/dev/null | head -1)
[ -n "$NPU_ELF" ] || fail "找不到 ddr_touch.elf，先 bazel build //gem5int:ddr_touch.elf"

export PYTHONPATH="$PROJ_DIR/tools${PYTHONPATH:+:$PYTHONPATH}"

echo "gem5:       $GEM5_BIN"
echo "host 程序:  $HOST_BIN"
echo "Vortex 库:  $VORTEX_SO"
echo "Vortex 内核: $VXBIN"
echo "NPU 库:     $NPU_SO"
echo "NPU 内核:   $NPU_ELF"

OUT=$(mktemp -d)
M5OUT=$(mktemp -d)
echo "HETTRACE_DIR=$OUT"

# ---- 1. 正向跑 --------------------------------------------------------------
echo
echo "---- 1/5 一个 host 程序同时驱动两个设备 ----"
set +e
LOG=$(HETTRACE_DIR="$OUT" "$GEM5_BIN" --outdir="$M5OUT" "$CONFIG" \
    --cmd "$HOST_BIN" --options="-k $VXBIN" \
    --vortex-library "$VORTEX_SO" --vortex-host-rt-dir "$RT_DIR" \
    --npu-library "$NPU_SO" --npu-kernel "$NPU_ELF" 2>&1)
RC=$?
set -e
echo "$LOG" | grep -E "^host: |CoralNPU: kernel finished|^---- 结束" | sed 's/^/  /' || true
[ "$RC" = "0" ] || { echo "$LOG" | tail -25; fail "gem5 返回 $RC（期望 0）"; }
# host 的退出码由它自己打印的这一行代表 —— gem5 不管被仿真程序 return 几都是 0 退
# 出，所以只判 gem5 的返回码是不够的。
echo "$LOG" | grep -q "^host: 全部通过" || {
    echo "$LOG" | grep "^host: " | tail -10
    fail "host 自检没过 —— 上面几行里有它自己报的原因"; }
for f in host.hettrace vortex.hettrace coralnpu.hettrace; do
    [ -f "$OUT/$f" ] || fail "没有产出 $f"
    [ -f "$OUT/$f.meta.json" ] || fail "没有产出 $f.meta.json"
done
echo "  ok   两个设备各自与 host 核对通过，三份 trace 与侧车文件都在"

# ---- 2. 三份 meta.json ------------------------------------------------------
echo
echo "---- 2/5 三份 meta.json 的计数器与时钟 ----"
python3 - "$OUT" <<'PY' || exit 1
import json, os, sys
d = sys.argv[1]
# (源, clock_period_ticks, level) —— 周期来自 addrmap.json 的 clock_mhz，level 是
# tap 的挂点：host 与 vortex 都是 post_llc(0)，NPU 记的是 AXI master(2)。
want = (("host", 500, 0), ("vortex", 1000, 0), ("coralnpu", 2000, 2))
bad = []
for name, period, level in want:
    m = json.load(open(os.path.join(d, name + ".hettrace.meta.json")))
    if m["emitted"] == 0:
        bad.append("%s: emitted=0，这一源的 tap 没接上" % name)
    if m["unmapped"]:
        bad.append("%s: unmapped=%d，地址与 addrmap.json 不一致" % (name, m["unmapped"]))
    if m["non_monotonic"]:
        bad.append("%s: non_monotonic=%d，时间戳回退" % (name, m["non_monotonic"]))
    if m["clock_period_ticks"] != period:
        bad.append("%s: clock_period_ticks=%d，期望 %d" % (name, m["clock_period_ticks"], period))
    if m["level"] != level:
        bad.append("%s: level=%d，期望 %d" % (name, m["level"], level))
    print("       %-9s emitted=%-6d bytes=%-7d 区间 [%d, %d]"
          % (name, m["emitted"], m["bytes"], m["first_tick"], m["last_tick"]))
for b in bad:
    print("  FAIL " + b)
if not bad:
    print("  ok   三源 unmapped=0 non_monotonic=0，三个时钟周期各自与 addrmap.json 一致")
sys.exit(1 if bad else 0)
PY

# ---- 3. 两个设备的活动区间真的重叠 -------------------------------------------
echo
echo "---- 3/5 两个设备的活动区间重叠（本脚本的核心判据）----"
python3 - "$OUT" <<'PY' || exit 1
import json, os, sys
d = sys.argv[1]
iv = {}
for name in ("host", "vortex", "coralnpu"):
    m = json.load(open(os.path.join(d, name + ".hettrace.meta.json")))
    iv[name] = (m["first_tick"], m["last_tick"])
(vlo, vhi), (nlo, nhi) = iv["vortex"], iv["coralnpu"]
(hlo, hhi) = iv["host"]
ov_lo, ov_hi = max(vlo, nlo), min(vhi, nhi)
print("       vortex   [%d, %d]" % (vlo, vhi))
print("       coralnpu [%d, %d]" % (nlo, nhi))
bad = []
if ov_hi <= ov_lo:
    bad.append("两个设备的区间不相交 —— 这份 trace 里不存在两源交错，"
               "下游没法用它复现争抢。负载退化成串行了？")
else:
    span = nhi - nlo
    print("       重叠 %d tick（NPU 自己的跨度 %d tick，占 %.0f%%）"
          % (ov_hi - ov_lo, span, 100.0 * (ov_hi - ov_lo) / span if span else 0))
if not (hlo <= min(vlo, nlo) and hhi >= max(vhi, nhi)):
    bad.append("两个设备的区间没有整个落在 host 区间里 —— 设备在 host 起跑前或"
               "收工后动过，说明时间戳不是同一个 curTick()")
for b in bad:
    print("  FAIL " + b)
if not bad:
    print("  ok   NPU 的整段活动落在 Vortex 的活动区间里，两者又都在 host 区间内")
sys.exit(1 if bad else 0)
PY

# ---- 4. validate + 两两共享 --------------------------------------------------
echo
echo "---- 4/5 归并校验：两个交接区各自成立，第三对必须是 0 ----"
python3 -m hettrace validate "$OUT" > "$OUT/validate.txt" 2>&1 || {
    cat "$OUT/validate.txt"; fail "validate 没通过"; }
grep -E "交接区|WARN|结论" "$OUT/validate.txt" | sed 's/^/  /'
for want in "交接区 shared_buffer 被 host, coralnpu 共同访问" \
            "交接区 vortex_bar 被 host, vortex 共同访问"; do
    grep -q "$want" "$OUT/validate.txt" || fail "validate 没认出：$want"
done
# 区间不相交会被 validate 报成 WARN。第 3 步已经直接判过，这里再顺手确认报告里干净
# —— 免得将来 validate 换了判据而脚本还以为自己在守着这条性质。
#
# 写成 if 而不是 `grep -q ... && fail`：那种写法在 set -e 下能跑对纯属巧合 ——
# grep 没匹配时整条 AND 列表的退出码是 1，一旦它挪到脚本末尾就会让整个脚本以 1
# 退出，而屏幕上什么错都没有。
if grep -q "时间区间不重叠" "$OUT/validate.txt"; then
    fail "validate 报了区间不重叠"
fi

python3 - "$OUT" <<'PY' || exit 1
import sys
from hettrace import stats
sizes, pairwise, _lb = stats.footprint(sys.argv[1])
def pair(a, b):
    return pairwise.get((a, b), pairwise.get((b, a), 0))
hn, hv, nv = pair("host", "coralnpu"), pair("host", "vortex"), pair("coralnpu", "vortex")
print("       足迹 host=%d / vortex=%d / coralnpu=%d line"
      % (sizes.get("host", 0), sizes.get("vortex", 0), sizes.get("coralnpu", 0)))
print("       共享 line: host<->coralnpu=%d  host<->vortex=%d  coralnpu<->vortex=%d"
      % (hn, hv, nv))
bad = []
if not hn:
    bad.append("host 与 coralnpu 没有共享 line —— shared_buffer 那次交接没落进 trace")
if not hv:
    bad.append("host 与 vortex 没有共享 line —— CP 的 DMA 没落进 trace（见 "
               "run_vortex_shared.sh 第 3 步）")
if nv:
    bad.append("coralnpu 与 vortex 之间出现了 %d 条共享 line。这不可能是真的："
               "vortex_bar 在 4 GiB 之上，CoralNPU 的 AXI 只有 32 位。"
               "查地址映射（trace_addr_offset / pin_addr）" % nv)
for b in bad:
    print("  FAIL " + b)
if not bad:
    print("  ok   两个交接区各自量到了共享，两个设备之间如期为 0")
sys.exit(1 if bad else 0)
PY

# ---- 5. 归并成一条流 --------------------------------------------------------
# 这一步才是"三源 trace 可用"的最终形态：一条按 tick 单调的流，三个源交错在里面。
# 前面几步都是分开看每一份，交错只有归并之后才看得见。
echo
echo "---- 5/5 归并：一条单调的流，NPU 活动期内三个源都在 ----"
python3 -m hettrace merge "$OUT" -o "$OUT/merged.hettrace" | sed 's/^/  /'
python3 - "$OUT" <<'PY' || exit 1
import collections, sys
rows = []
for line in open(sys.argv[1] + "/merged.hettrace"):
    if line.startswith("#"):
        continue
    f = line.split()
    rows.append((int(f[0]), f[1]))
bad = []
if not all(a[0] <= b[0] for a, b in zip(rows, rows[1:])):
    bad.append("归并结果不是按 tick 单调的")
srcs = {s for _t, s in rows}
if srcs != {"host", "vortex", "coralnpu"}:
    bad.append("归并流里的源是 %s，期望三个都在" % sorted(srcs))
switches = sum(1 for a, b in zip(rows, rows[1:]) if a[1] != b[1])
# NPU 活动期是三源同时在跑的那一小段；三个源在这一段里都要有记录，否则"交错"只是
# 把三段首尾相接地拼起来了。
lo = min(t for t, s in rows if s == "coralnpu")
hi = max(t for t, s in rows if s == "coralnpu")
c = collections.Counter(s for t, s in rows if lo <= t <= hi)
print("       共 %d 条，源切换 %d 次" % (len(rows), switches))
print("       NPU 活动期 [%d, %d] 内: %s" % (lo, hi, dict(c)))
if len(c) != 3:
    bad.append("NPU 活动期内只有 %s 有记录 —— 三源没有真的交错" % sorted(c))
for b in bad:
    print("  FAIL " + b)
if not bad:
    print("  ok   一条单调流，NPU 那 %d tick 里三个源的记录夹在一起"
          % (hi - lo))
sys.exit(1 if bad else 0)
PY

echo
echo "全部通过 —— 三个仿真器在一个 gem5 进程里同时跑，三份 trace 归并成一条流"
echo "trace 保留在 $OUT（含 merged.hettrace 与 validate.txt）"
