#!/bin/bash
# 把 Vortex 侧的 trace tap 装进 Vortex 源码树。
#
#   VORTEX_HOME=$HOME/vortex-gpu/vortex vortexint/install.sh
#
# 做三件事：
#   1. libhettrace 的头 -> $VORTEX_HOME/sim/simx/hettrace/
#      装在 sim/simx/ 下面是有意的：SimX 的 Makefile 已有 -I$(SRC_DIR)
#      （即 sim/simx），所以 <hettrace/...> 直接就能解析，Vortex 的构建
#      文件一行都不用改。
#   2. vortex_trace.h -> $VORTEX_HOME/sim/simx/gem5/
#   3. 打 5 个补丁：
#        vortex_gpgpu.{h,cpp}      设备库侧，加 vortex_gem5_trace_* 三个 ABI 函数
#        vortex_gpgpu_dev.{hh,cc}  gem5 侧，dlsym 可选解析 + curTick() 时间源
#        VortexGPGPU.py            两个参数：trace_enable / trace_addr_offset
#
# 补丁是纯增量的：新 ABI 由 gem5 侧用 dlsym 可选解析且不 fatal，所以没打过补丁
# 的 libvortex-gem5.so 照样能被加载，只是没有 trace。
#
# 幂等：重复运行会跳过已打过的补丁，不会重复叠加。
# 卸载：vortexint/install.sh --revert

set -euo pipefail

SELF_DIR=$(dirname "$(readlink -f "$0")")
PROJ_DIR=$(dirname "$SELF_DIR")
VORTEX_HOME=${VORTEX_HOME:-$HOME/vortex-gpu/vortex}

REVERT=0
if [ "${1:-}" = "--revert" ]; then REVERT=1; fi

GEM5_DIR="$VORTEX_HOME/sim/simx/gem5"
HET_DIR="$VORTEX_HOME/sim/simx/hettrace"

if [ ! -f "$GEM5_DIR/vortex_gpgpu.cpp" ]; then
    echo "错误: VORTEX_HOME=$VORTEX_HOME 看起来不是 Vortex 源码树" >&2
    echo "      (期望存在 $GEM5_DIR/vortex_gpgpu.cpp)" >&2
    exit 1
fi

PATCH_FILES="vortex_gpgpu.h vortex_gpgpu.cpp \
             vortex_gpgpu_dev.hh vortex_gpgpu_dev.cc VortexGPGPU.py"

# ---- 补丁 -------------------------------------------------------------------
# 判断当前状态用 patch -R --dry-run：能反向应用说明已经打过了。
apply_patch() {
    local f="$1" p="$SELF_DIR/patches/$1.patch"
    if patch -R -p0 -s -f --dry-run -i "$p" "$GEM5_DIR/$f" >/dev/null 2>&1; then
        echo "  $f: 补丁已在，跳过"
        return 0
    fi
    if ! patch -p0 -s -f --dry-run -i "$p" "$GEM5_DIR/$f" >/dev/null 2>&1; then
        echo "错误: $f 的补丁无法应用 —— Vortex 上游大概改过这个文件。" >&2
        echo "      需要重新生成 $p（见 docs/04-integration.md）。" >&2
        return 1
    fi
    cp -n "$GEM5_DIR/$f" "$GEM5_DIR/$f.pre-hettrace" 2>/dev/null || true
    patch -p0 -s -i "$p" "$GEM5_DIR/$f"
    echo "  $f: 已打补丁 (原文件备份为 $f.pre-hettrace)"
}

revert_patch() {
    local f="$1" p="$SELF_DIR/patches/$1.patch"
    if patch -R -p0 -s -f --dry-run -i "$p" "$GEM5_DIR/$f" >/dev/null 2>&1; then
        patch -R -p0 -s -i "$p" "$GEM5_DIR/$f"
        echo "  $f: 已还原"
    else
        echo "  $f: 未打过补丁，跳过"
    fi
}

if [ "$REVERT" = "1" ]; then
    echo "还原 Vortex trace tap:"
    for f in $PATCH_FILES; do revert_patch "$f"; done
    rm -f "$GEM5_DIR/vortex_trace.h"
    rm -rf "$HET_DIR"
    echo "完成。记得重新 make libvortex-gem5。"
    exit 0
fi

echo "安装 Vortex trace tap 到 $VORTEX_HOME"

mkdir -p "$HET_DIR"
install -m 0644 "$PROJ_DIR"/libhettrace/include/hettrace/*.h "$HET_DIR/"
echo "  hettrace 头 -> $HET_DIR"

install -m 0644 "$SELF_DIR/vortex_trace.h" "$GEM5_DIR/"
echo "  vortex_trace.h -> $GEM5_DIR"

for f in $PATCH_FILES; do apply_patch "$f"; done

cat <<EOF

接下来两步（顺序无所谓）：

1) 重新构建设备库：
     make -C $VORTEX_HOME/sim/simx USE_GEM5=1 libvortex-gem5 -j\$(nproc)
   产物 libvortex-gem5.so 即 gem5 VortexGPGPU SimObject 的 library 参数。

2) 把 gem5 侧的三个文件推进 gem5 树并重新编 gem5。Vortex 自带的安装脚本
   就是干这个的（gem5 侧源码的 source-of-truth 在 Vortex 树里）：
     GEM5_HOME=\$GEM5_HOME $VORTEX_HOME/sim/simx/gem5/install.sh
     scons -C \$GEM5_HOME build/X86/gem5.opt -j\$(nproc)
EOF
