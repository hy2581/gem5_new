# 上游版本记录

本项目不直接修改上游基线，而是把自己的集成代码装进去（见
[docs/04-integration.md](docs/04-integration.md)）。代价是**上游漂移会让观测/异步补丁打不上**，
而且失效方式不总是明显的 —— 补丁能打上但语义变了，比补丁直接失败更难查。

所以这里钉死"已知能跑通的那一组版本"。换版本不是不行，但请从这里出发做 diff，别从
"clone 最新的" 出发。

当前默认契约更新于 **2026-09-05**：CPU、Vortex 和 CoralNPU 的 memory-side 请求在 gem5
中的同一个 interconnect 观察点写成 HETTrace v2；gem5 只负责功能真值，不从外部存储模型
接收时序反馈。离线工具用 `convert --preset memsim` 把统一 AXI4 trace 投影为请求流，外部
`mem_sim` 的 `hbm_sim` 是存储控制器/DRAM 时序真值。

项目侧旧的在线 Ramulator、AXI/UCIe bridge 和 Python 内置 `memsim` 已退出默认架构。这里仍
钉住的 `third_party/ramulator` **只属于 Vortex SimX 自身的构建与运行时依赖**，不可删除，
也不可把它解释为本项目的离线或在线存储后端。

## 四棵主源码树

| 树 | 远端 | commit | 日期 | 最近的 tag |
|---|---|---|---|---|
| gem5 | `https://github.com/gem5/gem5.git` | `2721ed751edac7d4cf3df574c6e0293343a14ba2` | 2026-08-14 | 见下（**非上游原版**） |
| Vortex | `https://github.com/vortexgpgpu/vortex.git` | `d76b7f24e658867ab57e3942d7c648c3e6af072d` | 2026-07-29 | `v3.0` |
| CoralNPU | `https://github.com/google-coral/coralnpu.git` | `fcb74cfe79dbd184b9c53539490994e701981f80` | 2026-07-23 | `M3-2026-04-27` |
| mem_sim/hbm_sim | `https://github.com/GuXing25/mem_sim.git` | `7945650579c44713ddec80acc2c82ae34e1f19a5` | 2026-09-03 | — |

Vortex SimX 的三个 submodule（不初始化的话 SimX 会以“缺头文件”的形式失败，看不出是
submodule 没拉）：

| submodule | commit |
|---|---|
| `third_party/softfloat` | `b51ef8f3201669b2288104c28546fc72532a1ea4` |
| `third_party/ramulator` | `e62c84a6f0e06566ba6e182d308434b4532068a5` |
| `third_party/cocogfx` | `b1befdb36df8af7ac9e2c96acaf81957aab5d107` |

表中的 Ramulator 只满足 Vortex SimX 的既有依赖；统一 trace 的下游时序实验使用上表单独
钉住的 `mem_sim/hbm_sim`。

## gem5 这棵树不是上游原版 —— 需要单独说明

本项目开发所用的 gem5 是一棵**私有 fork**（`git@github.com:hy2581/gem5.git`），在上游
`c8222cc67a`（`v25.1.0.1` hotfix）之上多了 3 个提交，来自一个与本项目无关的在先项目
（定制堆叠存储器仿真）。其中一个提交改过 `src/mem/comm_monitor.{cc,hh}` 和
`CommMonitor.py`，但统一 HETTrace 路径不使用该 fork 的 AXI direct socket，也不依赖旧的
per-device `CommMonitor` tap。项目自己的透明 AXI 监视器安装在共享 memory-side
interconnect 上；三源分类、请求/响应关联和 HETTrace v2 写出都由该监视器完成。

**结论**：不要启用私有 fork 中与本项目无关的 AXI direct socket。本项目应当可以移植到
上游原版 gem5 `v25.1.0.1`，但纯净上游树仍需单独运行三源回归验证。

## 构建环境（本机实测通过的一组）

| | 版本 |
|---|---|
| OS | Ubuntu 24.04.4 LTS |
| gcc / g++ | 13.3.0 |
| Python（构建 gem5 用） | 3.12.3（系统 `/usr/bin/python3`，`gem5.opt` 链的是它的 `libpython`） |
| Python（跑本项目工具） | 3.8.20 也可 —— 工具只用标准库 |
| SCons | 在 `$GEM5_HOME/.venv/bin/scons`，**不在 PATH 上** |
| Bazel | CoralNPU 树内为 8.6.0（由 `.bazelversion` 钉住；树外 bazelisk 默认版本不作为构建口径） |
| CMake / generator | 3.28.3 / Unix Makefiles；Ninja 不是必需项，`hbm_sim` 要求 C++20 |
| Verilator | 5.020 |
| Vortex LLVM 工具链 | `TOOLCHAIN_REV=v3.0`，`OSVERSION=ubuntu/focal`，装在 `$HOME/tools` |

## 怎么核对手上的树是不是这一组

```bash
for d in "$GEM5_HOME" "$VORTEX_HOME" "$CORALNPU_HOME" "$MEMSIM_HOME"; do
    printf '%-40s %s\n' "$d" "$(git -C "$d" rev-parse HEAD)"
done
git -C "$VORTEX_HOME" submodule status
```

对不上也不一定有问题 —— 补丁是纯增量的，装脚本会用 `patch -R --dry-run` 自己判断状态。
真出问题时报错和重新生成补丁的做法见
[docs/04-integration.md](docs/04-integration.md#补丁打不上)。
