# AXI 边界 → UCIe → MC → DFI → memory 功能链

这是一个从 AXI 边界开始、用于接口联调的最小 SystemVerilog 后端功能链，不是实际
CPU/NPU/GPU 全链路、UCIe/DFI 协议实现或性能模型。当前 testbench 用参考 XPU BFM 发起流量；
它给真实 XPU-to-AXI 留出 AXI ready/valid 边界，把其余模块先做成可运行占位，从而尽早验证
读写数据、burst、字节使能、背压、ID/源标识和端到端无丢包。

正确分层是：

```text
CPU/NPU/GPU AXI master
        ↓
axi_to_memreq（AXI slave/事务化）
        ↓
ucie_link_model（功能级双向延迟链路）
        ↓
mc_model（单 outstanding、固定调度延迟）
        ↓
dfi_memory_model（简化 DFI/PHY + 字节数组存储）
```

## 运行

```bash
make -C storage_chain test
# 或在仓库根目录：make test-storage-chain
```

成功结尾：

```text
CHAIN PASS: AXI beats=15, UCIe req/rsp=15/15, MC cmds=15, DFI writes/reads=8/7
```

默认使用 Icarus Verilog 12，构建产物在忽略的 `storage_chain/build/` 下。

## 文件

| 文件 | 作用 |
|---|---|
| `rtl/axi_to_memreq.sv` | XPU 接入边界；AXI4 对齐 INCR burst、单 outstanding |
| `rtl/ucie_link_model.sv` | request/response 两条无损 ready/valid 延迟通道 |
| `rtl/mc_model.sv` | 最小 MC：固定调度延迟，元数据原样返回 |
| `rtl/dfi_memory_model.sv` | 简化 DFI 功能接口和 4 KiB byte array |
| `rtl/storage_chain_top.sv` | 完整连接与各阶段计数器 |
| `tb/tb_storage_chain.sv` | CPU/NPU/GPU 参考激励、scoreboard、背压与 WSTRB 测试 |

实际 XPU 接入方法、接口契约、标准边界和逐步替换路线见
[`docs/06-storage-chain-plan.md`](../docs/06-storage-chain-plan.md)。
