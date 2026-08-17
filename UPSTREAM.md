# 上游版本记录

本项目不 fork 任何一棵上游树，而是把自己的东西装进去（见
[docs/04-integration.md](docs/04-integration.md)）。代价是**上游漂移会让 7 个补丁打不上**，
而且失效方式不总是明显的 —— 补丁能打上但语义变了，比补丁直接失败更难查。

所以这里钉死"已知能跑通的那一组版本"。换版本不是不行，但请从这里出发做 diff，别从
"clone 最新的" 出发。

## 三棵树

| 树 | 远端 | commit | 日期 | 最近的 tag |
|---|---|---|---|---|
| gem5 | `https://github.com/gem5/gem5.git` | `2721ed751edac7d4cf3df574c6e0293343a14ba2` | 2026-08-14 | 见下（**非上游原版**） |
| Vortex | `https://github.com/vortexgpgpu/vortex.git` | `d76b7f24e658867ab57e3942d7c648c3e6af072d` | 2026-07-29 | `v3.0` |
| CoralNPU | `https://github.com/google-coral/coralnpu.git` | `fcb74cfe79dbd184b9c53539490994e701981f80` | 2026-07-23 | `M3-2026-04-27` |

Vortex 的三个 submodule（不初始化的话 SimX 会以"缺头文件"的形式失败，看不出是 submodule
没拉）：

| submodule | commit |
|---|---|
| `third_party/softfloat` | `b51ef8f3201669b2288104c28546fc72532a1ea4` |
| `third_party/ramulator` | `e62c84a6f0e06566ba6e182d308434b4532068a5` |
| `third_party/cocogfx` | `b1befdb36df8af7ac9e2c96acaf81957aab5d107` |

## gem5 这棵树不是上游原版 —— 需要单独说明

本项目开发所用的 gem5 是一棵**私有 fork**（`git@github.com:hy2581/gem5.git`），在上游
`c8222cc67a`（`v25.1.0.1` hotfix）之上多了 3 个提交，来自一个与本项目无关的在先项目
（定制堆叠存储器仿真）。其中一个提交**改了 `src/mem/comm_monitor.{cc,hh}` 和
`CommMonitor.py`** —— 而 host tap 恰好挂在 `CommMonitor` 上，所以这件事必须查清楚而不是
假设无关。

查的结果：

* host tap（`HetTraceProbe`）继承的 `BaseMemProbe`、以及它监听的 `"PktRequest"` 探针点，
  **在上游 `c8222cc67a` 里就已存在**（`comm_monitor.cc:76` 建的 `ppPktReq`）。tap 没有用到
  fork 新增的任何东西。
* fork 给 `CommMonitor` 加的是一条 AXI4 联合仿真通路，它额外调了一次
  `ppPktReq->notify()` —— 但那行在 `if (!axiDirectSocket.empty())` 里面，而
  `axi_direct_socket` 参数默认是空串，本项目的配置脚本从不设置它。所以那条通路在我们的
  跑法下根本不进入。

**结论**：本项目应当能在上游原版 gem5 `v25.1.0.1` 上构建并跑出相同结果。**但这一点没有被
实际验证过** —— 手上只有这棵 fork。要在纯净 gem5 上用，建议先跑
`gem5int/tests/run_het.sh`，它的反向对照会把"host 看到的字节到底对不对"直接暴露出来。

## 构建环境（本机实测通过的一组）

| | 版本 |
|---|---|
| OS | Ubuntu 24.04.4 LTS |
| gcc / g++ | 13.3.0 |
| Python（构建 gem5 用） | 3.12.3（系统 `/usr/bin/python3`，`gem5.opt` 链的是它的 `libpython`） |
| Python（跑本项目工具） | 3.8.20 也可 —— 工具只用标准库 |
| SCons | 在 `$GEM5_HOME/.venv/bin/scons`，**不在 PATH 上** |
| Bazel | 8.6.0（由 CoralNPU 的 `.bazelversion` 钉住，bazelisk 按需下载） |
| Verilator | 5.020 |
| Vortex LLVM 工具链 | `TOOLCHAIN_REV=v3.0`，`OSVERSION=ubuntu/focal`，装在 `$HOME/tools` |

## 怎么核对手上的树是不是这一组

```bash
for d in $GEM5_HOME $VORTEX_HOME $CORALNPU_HOME; do
    printf '%-40s %s\n' "$d" "$(git -C "$d" rev-parse HEAD)"
done
git -C $VORTEX_HOME submodule status
```

对不上也不一定有问题 —— 补丁是纯增量的，装脚本会用 `patch -R --dry-run` 自己判断状态。
真出问题时报错和重新生成补丁的做法见
[docs/04-integration.md](docs/04-integration.md#补丁打不上怎么办)。
