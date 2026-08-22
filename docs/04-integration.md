# 三棵树怎么接起来

本项目不 fork gem5、Vortex、CoralNPU 中的任何一棵，而是把自己的东西**装进**它们的树里。
本文件说清楚谁装到哪、为什么这么装、以及补丁打不上时怎么办。

## 四棵树

| 树 | 环境变量 | 里面放了什么 |
|---|---|---|
| 本项目 | — | 所有 source-of-truth |
| gem5 | `GEM5_HOME` | `src/dev/coralnpu/`、`src/hettrace/`、`src/dev/vortex/`、`configs/het/` |
| Vortex | `VORTEX_HOME` | `sim/simx/hettrace/`、`sim/simx/gem5/vortex_trace.h`、5 个补丁 |
| CoralNPU | `CORALNPU_HOME` | `gem5int/` 整个 package、2 个补丁 |

三个安装脚本都是**幂等**的（重跑只刷新文件、已打过的补丁会跳过）且都支持 `--revert`。

已知能跑通的那一组上游 commit 记在 [UPSTREAM.md](../UPSTREAM.md) —— 补丁是 `-p0` diff，
上游漂移是这套装法唯一的系统性风险，换版本前先看那里。

```bash
GEM5_HOME=$HOME/gem5                     ./gem5int/install.sh
VORTEX_HOME=$HOME/vortex-gpu/vortex      ./vortexint/install.sh
CORALNPU_HOME=$HOME/coralnpu             ./coralnpuint/install.sh
```

## 两种安装方式，以及为什么不统一

**新目录（首选）**：gem5 侧的 `src/dev/coralnpu/`、`src/hettrace/`、`configs/het/`，
CoralNPU 侧的 `gem5int/`。这几处一个上游文件都不碰，所以"上游改了文件导致补丁打不上"这个
失效模式**根本不存在**，`--revert` 也就只是 `rm -rf`，不需要备份还原。

这么做是可行的，因为三套构建系统都会自动发现新目录：

* gem5 的 `SConstruct` 递归查找 `src/**/SConscript`；
* bazel 把每个带 `BUILD` 的目录当作一个 package；
* SimX 的 Makefile 已有 `-I$(SRC_DIR)`（即 `sim/simx`），所以 hettrace 的头装在
  `sim/simx/hettrace/` 下面就能被 `#include <hettrace/writer.h>` 找到。

**补丁（不得已）**：只有 7 个文件必须改，每一个都有非它不可的理由。

| 树 | 文件 | 为什么必须改 |
|---|---|---|
| CoralNPU | `hw_sim/core_mini_axi_wrapper.h` | 加 `halted()` / `wfi()` 两个非阻塞访问器。那两个状态位是 `private`，而现成的 `WaitForTermination()` 会自己推时钟 —— 在 gem5 里用它就破坏"时钟只由 gem5 推"这条不变量 |
| CoralNPU | `hw_sim/BUILD` | 把 `core_mini_axi_wrapper` 的 visibility 放到 public，否则 `//gem5int` 依赖不到 |
| Vortex | `sim/simx/gem5/vortex_gpgpu.{h,cpp}` | 设备库侧新增 `vortex_gem5_trace_*` 三个 ABI 函数 |
| Vortex | `sim/simx/gem5/vortex_gpgpu_dev.{hh,cc}` | gem5 侧 dlsym 可选解析这三个函数，并把 `curTick()` 作为时间源递进去 |
| Vortex | `sim/simx/gem5/VortexGPGPU.py` | 两个参数：`trace_enable` / `trace_addr_offset` |

Vortex 那 5 个补丁全是**纯增量**的：新 ABI 由 gem5 侧用 `dlsym` 可选解析且解析失败不
fatal，所以没打过补丁的 `libvortex-gem5.so` 照样能被加载，只是没有 trace。

`gem5int/install.sh` 不装 Vortex 的 gem5 SimObject：那份源码的 source-of-truth 在 Vortex
树里（`sim/simx/gem5/`），由 Vortex 自己的 `install.sh` 装进 gem5。所以 Vortex 那条腿要跑
**两个**安装脚本，顺序不能反：

```bash
VORTEX_HOME=$HOME/vortex-gpu/vortex ./vortexint/install.sh      # 先打补丁
GEM5_HOME=$HOME/gem5 $VORTEX_HOME/sim/simx/gem5/install.sh      # 再把打过补丁的源码装进 gem5
```

反了的话 gem5 里装的是打补丁**前**的 `VortexGPGPU.py`，编出来的 gem5 没有 `trace_enable`
参数，而配置脚本会在设置这个参数时报一个"看不出与安装顺序有关"的错。`run_vortex.sh` 第一
件事就是检查 `build/X86/params/VortexGPGPU.hh` 里有没有 `trace_enable`，正是为了把这个失
效模式挡在前面。

## 补丁打不上怎么办

安装脚本用 `patch -R --dry-run` 判断状态（能反向应用 = 已经打过了），打不上时报的是：

```
错误: hw_sim/xxx 的补丁无法应用 —— 上游大概改过这个文件。
      需要重新生成 xxx.patch（见 docs/04-integration.md）。
```

重新生成的做法：补丁都是 `-p0` 的单文件 unified diff，头部形如
`--- core_mini_axi_wrapper.h` / `+++ core_mini_axi_wrapper.h`（**没有** `a/` `b/` 前缀）。

```bash
cd $CORALNPU_HOME/hw_sim
cp core_mini_axi_wrapper.h.pre-hettrace /tmp/orig.h     # 上一次的原文件备份
# 手工把改动搬到新版本的上游文件上，然后：
diff -u /tmp/orig.h core_mini_axi_wrapper.h > $PROJ/coralnpuint/patches/core_mini_axi_wrapper.h.patch
```

`diff -u` 出来的头部路径要手工改成不带目录的裸文件名，`-p0` 才能配合脚本里
`patch -p0 ... "$HW_SIM_DIR/$f"` 的用法。首次打补丁时脚本会把原文件存成
`<name>.pre-hettrace`（`cp -n`，不会覆盖已有备份），所以总有一份"上游原样"可比。

## 构建

### gem5

```bash
$GEM5_HOME/.venv/bin/scons -C $GEM5_HOME build/X86/gem5.opt -j$(nproc)
```

**为什么写全路径**：gem5 自 v24 起把构建依赖装在树内的 `.venv/` 里（`pip install -r
requirements.txt`），`scons` 通常**不在** `PATH` 上，直接敲 `scons` 得到的是
command not found，或者更糟 —— 敲到系统里另一个版本的 scons 上。`.venv` 不存在时先建：

```bash
/usr/bin/python3 -m venv $GEM5_HOME/.venv
$GEM5_HOME/.venv/bin/pip install -r $GEM5_HOME/requirements.txt
```

**Python 版本**：gem5 要求 3.8+，且 `gem5.opt` 会**链接**构建时那个解释器的
`libpython`（本机是系统的 3.12，`ldd gem5.opt | grep python` 可查）。本项目自己的
Python 工具（`hettrace`、`gen_addrmap.py`）只用标准库、3.8 就能跑，两边不必是同一个
解释器 —— 但要注意 `python3` 指到哪：机器上若有无关的 venv 抢在 `PATH` 前面（本机
`python3` 是一个 3.8 的 EDA venv），`python3 -m hettrace` 和 gem5 里跑的就不是同一个
Python 了。工具本身不受影响，容易受影响的是"我以为我在用哪个 python"。

编完之后核对一下东西是否真的进去了 —— 这比"编译通过"靠得住，因为漏装一个 `.py` 只会让
参数消失，不会让编译失败：

```bash
nm -C $GEM5_HOME/build/X86/gem5.opt | grep -c 'gem5::CoralNPU::'          # 应 > 0
grep -n trace_enable $GEM5_HOME/build/X86/params/CoralNPU.hh              # 应有
grep -n trace_enable $GEM5_HOME/build/X86/params/VortexGPGPU.hh           # 应有
```

`params/*.hh` 是 SCons 从 `.py` 生成的，所以它是"`.py` 装对了没有"的直接证据。改过
`.py` 之后必须重编：残留的 `build/` 里既有旧的 `.o` 也有旧的生成头。

### CoralNPU 设备库

```bash
cd $CORALNPU_HOME
bazel build //gem5int:libcoralnpu-gem5.so     # 产物 bazel-bin/gem5int/libcoralnpu-gem5.so
bazel build //gem5int:ddr_touch.elf           # 验证内核
```

`libcoralnpu-gem5-rvv.so` 是带向量单元的变体，ABI 完全相同，gem5 侧不需要知道自己 dlopen
的是哪一个（`coralnpu_gem5_build_info()` 会说）。内核用到 RVV 时换这个。

注意 `ddr_touch.elf` 的产物路径在 `bazel-out/` 下面，而 `bazel-out` 是符号链接 —— `find`
默认不跟进符号链接，所以测试脚本里先 `readlink -f` 再 find。

### Vortex

Vortex 是三棵树里最麻烦的一棵，因为它的 `third_party` 是 git submodule，而默认 checkout
下来是空目录：

```bash
cd $VORTEX_HOME
git submodule update --init third_party/softfloat third_party/ramulator third_party/cocogfx
make -C $VORTEX_HOME/third_party -j$(nproc)
```

不做这一步的话，编 SimX 会以 `softfloat.h: No such file or directory` 之类的形式失败 ——
报的是缺头文件，看不出是 submodule 没拉。

然后配置并编设备库。`USE_GEM5=1` 不能省：默认目标只编 `simx` 可执行文件，**不编**
`libvortex-gem5.so`。

```bash
export VORTEX_BUILD=$(dirname $VORTEX_HOME)/vxbuild     # run_vortex.sh 的默认值
mkdir -p $VORTEX_BUILD && cd $VORTEX_BUILD
$VORTEX_HOME/configure --xlen=32
make -C $VORTEX_BUILD/sim/simx USE_GEM5=1 libvortex-gem5 -j$(nproc)
nm -D --defined-only $VORTEX_BUILD/sim/simx/libvortex-gem5.so | grep vortex_gem5_trace_
```

**别把构建目录放在 `/tmp`**。Vortex 是 out-of-tree 构建，放哪都行，`/tmp` 看着很自然
—— 但 Ubuntu 开机会清 `/tmp`，重启之后 `libvortex-gem5.so` 就没了。那时 `run_vortex.sh`
报的是"找不到 .so"，完全看不出是被系统删的，而且重编一次要几分钟。

最后那行是 tap 是否真的编进去了的判据，应看到三个符号：`vortex_gem5_trace_open` /
`_close` / `_emitted`。

**运行时有一个坑**：`libvortex-gem5.so` 链的是 Vortex 自带的
`third_party/ramulator/libramulator.so`，`.so` 里有正确的 `RUNPATH`。但 `RUNPATH` 的搜索
顺序在 `LD_LIBRARY_PATH` **之后**，所以机器上别处若还装了一个 ramulator2（它是个独立项
目，很常见）且在 `LD_LIBRARY_PATH` 里，那份会被抢先加载，gem5 在 dlopen 时死在：

```
undefined symbol: _ZN9Ramulator7Logging19_create_base_loggerEv
```

这个报错完全看不出与 ramulator 版本有关。解法是把 Vortex 自带的那份放到最前面：

```bash
export LD_LIBRARY_PATH=$VORTEX_HOME/third_party/ramulator:$LD_LIBRARY_PATH
```

`run_vortex.sh` 自己做了这件事并在做不到时给出明确的错误。

### Vortex 的 RISC-V 工具链（`run_vortex_shared.sh` 需要）

只跑 `run_vortex.sh`（单设备 tap 验收）**不需要** RISC-V 工具链 —— 它用的内核是手写的裸机
rv32im 平坦镜像（`workloads/vortex_smoke/kernel.S`），用系统自带的 multilib
`riscv64-unknown-elf-gcc` 就能编，`vortex_gem5_load_kernel` 的 flat-image 路径接受 `.bin`。

但**只有** `.vxbin` 才能走 CP 驱动的启动路径，也就是 host ↔ Vortex 真正交换字节所必需的那
条路（见 [03-limitations.md](03-limitations.md)）。`run_vortex_shared.sh` 走的就是这条路，
所以它需要 Vortex 的 LLVM 工具链，装法是 Vortex 自己的：

```bash
mkdir -p /tmp/tc-dl && cd /tmp/tc-dl              # 脚本下载到 cwd，用个临时目录
TOOLDIR=$HOME/tools $VORTEX_BUILD/ci/toolchain_install.sh --llvm --libc32 --libcrt32 --riscv32
```

几点：

* 用**配置后**的 `$VORTEX_BUILD/ci/toolchain_install.sh`，不是源码树里的 `.sh.in`（那是
  模板，`configure` 才会把 `@TOOLDIR@` 之类替换掉）。
* 别用 `--all`：那会连 verilator / yosys / sta / pocl / chipstar / mesa 一起拉下来，本项目
  一个都用不到。编 `.vxbin` 只要上面四样，约 1.6 GB。
* `OSVERSION` 默认 `ubuntu/focal`，预编译产物在更新的发行版上照样能跑（glibc 向前兼容）。
* 脚本对每个组件会先 `rm -rf $TOOLDIR/<组件>`，所以 `$TOOLDIR` 里若已有同名目录会被删掉。

装好之后按 Vortex 自己的方式建 host runtime 与回归测试：

```bash
make -C $VORTEX_BUILD/sw/runtime                    # libvortex.so + libvortex-gem5-x86_64.so
make -C $VORTEX_BUILD/tests/regression/vecadd       # vecadd + kernel.vxbin
```

这三个产物就是 `run_vortex_shared.sh` 要的全部东西（它会自己检查、缺哪个报哪个）。

`.vxbin` 也可以直接喂给 `het_system.py` 的 `--vortex-kernel`，那走的是 standalone 预载路
径 —— 没有 host 那条腿，等于 `run_vortex.sh` 的跑法。要验字节共享必须走 CP，也就是要有
host runtime。

## 配置脚本里的一个坑：`SystemExit("消息")`

gem5 配置脚本是跑在 gem5 里的 Python，退出路径与普通 python3 不一样。
`src/sim/main.cc` 捕获 `SystemExit` 之后做的是：

```cpp
if (e.matches(PyExc_SystemExit))
    return e.value().attr("code").cast<int>();
```

`code` 是字符串就抛 `pybind11::cast_error`，进程 `terminate`，屏幕上只剩：

```
terminate called after throwing an instance of 'pybind11::cast_error'
  what():  Unable to cast Python instance of type <class 'str'> to C++ type 'int'
Program aborted at tick 0
--- BEGIN LIBC BACKTRACE ---
```

**那条本该打出来的错误消息一个字都看不到**，而现象看着像 gem5 或某个设备库炸了 —— 本项目
在三源负载上为此排查了一轮，真实原因只是 `--npu-kernel` 指的 `ddr_touch.elf` 路径不存在
（`.elf` 和 `.so` 不在同一个 bazel-out 配置目录下，得 `find`，不能照着 `.so` 的路径拼）。

所以本项目的三个配置脚本一律先 `print(..., file=sys.stderr)` 再 `raise SystemExit(1)`。
`het_system.py` 里包成了 `die()`，注释就在那儿。往这些脚本里加检查时照这个写法。

## 跑测试

```bash
# host + CoralNPU 协同（含反向对照）—— 本项目的主验收
GEM5_HOME=$HOME/gem5 CORALNPU_HOME=$HOME/coralnpu gem5int/tests/run_het.sh

# host + Vortex 协同（走 CP，需要 .vxbin 与 host runtime，见上一节）
GEM5_HOME=$HOME/gem5 VORTEX_HOME=$HOME/vortex-gpu/vortex \
    gem5int/tests/run_vortex_shared.sh

# 三源同时跑并归并（要上面两条腿的全部前置条件，外加自己的 host 负载，见下）
VORTEX_HOME=$HOME/vortex-gpu/vortex VORTEX_BUILD=$HOME/vortex-gpu/vxbuild \
    make -C workloads/three_source
GEM5_HOME=$HOME/gem5 CORALNPU_HOME=$HOME/coralnpu \
    VORTEX_HOME=$HOME/vortex-gpu/vortex gem5int/tests/run_three_source.sh

# CoralNPU 单设备
GEM5_HOME=$HOME/gem5 CORALNPU_HOME=$HOME/coralnpu gem5int/tests/run_gem5_npu.sh

# Vortex 单设备（tap 验收，不需要 RISC-V 工具链）
GEM5_HOME=$HOME/gem5 VORTEX_HOME=$HOME/vortex-gpu/vortex gem5int/tests/run_vortex.sh

# 不需要任何仿真器的检查（addrmap 同步性 + 234 项自测）
make check

# CoralNPU 设备库的纯 C 冒烟测试（不经 gem5）
CORALNPU_HOME=$HOME/coralnpu coralnpuint/tests/run_smoke.sh
```

`make check` = `gen_addrmap.py --check` + `tools/tests/test_tools.py`（164 项）+
`libhettrace/tests/test_writer.cc`（70 项）。两套自测都不用 pytest / gtest，各自数检查项、
各自定退出码 —— 少两个依赖，在只有 gem5 自带 python 的机器上也能跑。

`gen_addrmap.py --check` 只校验生成物是否与 `addrmap.json` 同步，不写文件，适合放在 CI 的
最前面 —— 生成物过期会让 C++ 侧和 Python 侧对"哪个地址属于哪个区域"的判断不一致，那种错
误在别处表现得非常隐晦。
