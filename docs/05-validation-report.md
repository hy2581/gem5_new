---
title: "异构 XPU 统一 AXI4 HETTrace 验证报告"
date: "2026-09-05"
status: "PASS"
---

# 当前版本验证报告

本报告对应其所在提交的项目源码，以及 [UPSTREAM.md](../UPSTREAM.md) 固定的四棵外部源码树。
验证在 Ubuntu 24.04.4 LTS x86-64 服务器上完成。它是当前持久化的结果真值来源；各次运行产生的
`validate.txt`、`stats.txt`、`hbm_sim.txt`、`summary.md`、trace 和 CSV 均为可再生产物，不提交
到仓库。

## 1. 当前架构口径

```text
host ───────┬─ shared_buffer ─ CoralNPU
            └─ vortex_bar ──── Vortex
                    │
                    v
       unified memory-side HetAxiMonitor
                    │ HETTrace v2
                    v
       convert --preset memsim → hbm_sim
```

CoralNPU 的 AXI 地址只有 32 位，而 Vortex BAR 位于 4 GiB 以上，因此不存在三方以同一物理地址
直连共享的区域。三源协同由 host 分别完成两条真实字节交接。统一 monitor 从 gem5 packet 重构
五通道 AXI 事件，三源记录均为 `level=interconnect`、`SYNTH=true`；外部 completion 不回灌 gem5。

## 2. 回归矩阵

| 检查 | 2026-09-05 结果 | 覆盖范围 |
|---|---:|---|
| `make check` | PASS：Python 317/317（37 用例）；C++ writer 171/171 | 地址/文档同步、格式、校验、统计、转换、writer |
| `make test-storage-chain` | PASS：6 transactions / 15 events / 3 sources；lint PASS | 五通道透明边界、WSTRB、ID、USER、RESP、LAST、反压 |
| `make test-memsim-smoke` | PASS：596/596 requests；9,536 B 守恒 | 合成 LLM-like trace→mapping→真实外部 HBM4→response |
| `make preflight` | `READY` | 工具、固定 revision、gem5/设备库/runtime/kernel/`hbm_sim` 产物 |
| `run_het.sh` | PASS | host↔CoralNPU 正向共享及 `--npu-no-share` 反向对照 |
| `run_vortex_shared.sh` | PASS | host↔Vortex runtime、CP DMA、core、BAR 共享与 AXI 因果 |
| `run_three_source.sh` | PASS | 同一 gem5 进程中的三源功能、自检、分类、并发与投影守恒 |

Vortex shared 回归中，19,292/19,339 个 host 事务具有非零响应延迟，且
`non_monotonic=0`，覆盖 atomic fast-forward 的延迟完成时间戳路径。

## 3. 最新三源 trace

| 源 | AXI 记录 | 事务 | 数据拍 | 读 | 写 | 字节 |
|---|---:|---:|---:|---:|---:|---:|
| host | 78,127 | 19,391 | 49,478 | 40,124 | 9,354 | 715,984 |
| Vortex | 1,252 | 249 | 881 | 497 | 384 | 13,848 |
| CoralNPU | 320 | 128 | 128 | 64 | 64 | 2,048 |
| **合计** | **79,699** | **19,768** | **50,487** | **40,685** | **9,802** | **731,880** |

三份 meta 均满足 `unmapped=0`、`non_monotonic=0`、`level=3`、`synth=true`。校验器实际观察到：

- `shared_buffer` 被 host 与 CoralNPU 共同访问；
- `vortex_bar` 被 host 与 Vortex 共同访问；
- Vortex core 与 CP DMA 均被正确分类；
- CoralNPU 地址、ID 与部分 WSTRB 保留到统一 packet 投影；
- 50,487 个 AXI 数据拍逐行映射为 50,487 个外部请求。

## 4. 外部 HBM4 重放

同一份三源 trace 使用固定的 `mem_sim` commit 和 `configs/hbm.cfg`，以 `--standard hbm4`、
`--response-delivery-mode host` 完整运行：

| 指标 | 结果 |
|---|---:|
| host requests / DRAM transactions | 50,487 / 50,487 |
| completed reads / writes | 40,685 / 9,802 |
| consumed responses | 50,487 |
| remaining requests / pending | 0 / 0 |
| mapping 与 response ID 集合差异 | 0 |
| response 时序关系错误 | 0 |
| hit cycle limit | false |
| system cycles | 2,476,809 |
| average read latency | 166.99 hbm_sim cycles |

该运行自报 `validation_mode=exploratory`、`model_conformance=standard_default`。输入中的
`data=`/`expect=` 是只承载请求大小的零值替身，因此 `data_mismatches=0` 只验证替身一致性，
不能证明原始 WDATA/RDATA 正确。`system cycles` 和 latency 是固定到达流的 open-loop 存储时序，
不能解释成应用执行时间、IPC、tokens/s 或闭环加速比。

## 5. 文档一致性审计

本轮同时完成以下检查：

- `addrmap.json`、C++/Python 生成物和实际两条交接路径一致；
- 项目手册、README、格式、限制、集成、RTL 边界与 benchmark 文档均描述当前架构；
- 不再引用已删除的旧 trace probe、在线内存后端、协议占位实现或过期报告资产；
- 仓库内 Markdown 相对链接均解析到现存文件；
- `git diff --check` 与所有 shell 脚本语法检查通过。

复现命令、环境变量和故障排查见[项目手册](USER_MANUAL.md)。结论使用前仍须遵守
[结果边界](03-limitations.md)。
