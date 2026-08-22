# CPU + NPU + GPU 驱动存储：XPU-to-AXI 接入与全链条计划

## 结论先行

项目总目标应表述为：**CPU、NPU、GPU 产生真实或回放的访存请求，经片间链路访问远端内存
控制器和存储模型，用于验证功能并进一步研究共享存储系统。** 现有 HETTrace 是 XPU 请求的
观测和离线分析前端，不是最终的存储后端。

当前实现状态必须与目标架构分开描述：仓库已经支持**参考 XPU BFM 从 AXI 边界发起的后端
功能级全链路仿真**；真实 CPU/NPU/GPU-to-AXI、标准 UCIe/DFI 和真实 MC/DRAM 时序尚未接入。
因此当前结果用于验证接口连通性与数据正确性，不用于宣称真实 XPU 全链路或性能模型完成。

推荐的标准分层是：

```text
CPU AXI ─┐
NPU AXI ─┼─> AXI interconnect/front-end -> memory request packet
GPU AXI ─┘                                  |
                                            v
                                  UCIe adapter + UCIe link
                                            |
                                            v
                                    memory controller
                                            |
                                            v
                                      DFI -> DDR PHY
                                            |
                                            v
                                      storage simulator
```

DFI 官方定义的是 **memory controller logic 与 PHY 之间**的接口，而不是 AXI 的通用事务
格式；UCIe 定义 die-to-die 物理层、适配层和协议栈，可承载 PCIe/CXL 或 streaming 类协议。
因此“AXI 转 DFI后经过 UCIe 再到 MC”在标准语义上次序不对。若现有框图必须保留这个名字，
至少应把 UCIe 前的格式改名为 `mem_req packet` 或 `project DFI packet`，并注明它不兼容标准
DFI。

官方依据：

- [DFI Group：DFI 是 MC 与 PHY 的接口](https://ddr-phy.org/)
- [UCIe Consortium：UCIe 规范覆盖物理层、协议栈和软件模型](https://www.uciexpress.org/specifications)
- [UCIe 官方 Q&A：标准内存语义可使用 CXL.mem](https://www.uciexpress.org/post/introduction-to-ucie-webinar-q-a-recap)

## 你负责的 XPU-to-AXI 应交付什么

### 1. 先冻结接口契约

不要先从“把某个 callback 接成几根线”开始。CPU、NPU、GPU 必须先共享一份接口契约：

| 项目 | 首版建议 | 当前 demo |
|---|---|---|
| AXI 版本 | AXI4 memory-mapped | AXI4 子集 |
| 地址宽度 | 根据统一地址图选 48/64 位；原型可 32 位 | 32 位 |
| 数据宽度 | 由吞吐目标和 XPU 原生总线决定 | 64 位 |
| burst | 首版只做对齐 INCR，不跨 4 KiB | INCR，最多 256 beats |
| ID | 每 master 有独立 ID 空间；互连后仍能路由响应 | 4 位 |
| 源标识 | `AxUSER` 或互连端口号标明 CPU/NPU/GPU | 2 位：0/1/2 |
| outstanding | 先 1，再扩到多 ID、多 outstanding | 1 |
| 原子/独占 | 首版禁用，单独立项 | 不支持 |
| cache 一致性 | 明确非一致、软件管理，或换 ACE/CHI/CXL | 非一致 |
| 错误 | 至少传播 OKAY/SLVERR/DECERR | OKAY/DECERR |
| 时钟 | 每个 XPU 时钟和 AXI/UCIe 时钟必须写清 | 单时钟 demo |

真实系统若要覆盖 `vortex_bar` 的 4 GiB 以上地址，32 位地址不够。当前 demo 只在
`0x9000_0000` 起始的 4 KiB 窗口验证握手和数据，因此选择 32 位；正式接口建议直接采用能覆盖
全局地址图的宽度，避免后期改 ABI。

### 2. 每个 AXI master 必须满足的时序规则

你交付的不只是“能发地址”，而应满足下面这些可断言规则：

1. `VALID=1 && READY=0` 时，通道 payload 必须保持稳定；
2. AW 与 W 是独立通道，不能假设同周期到达；
3. `AWLEN + 1` 必须等于 W beat 数，最后一拍 `WLAST=1`；
4. `ARLEN + 1` 必须等于 R beat 数，最后一拍 `RLAST=1`；
5. `WSTRB` 的每一位只控制对应 byte lane，不能把部分写扩成整字写；
6. burst 地址按 `1 << AxSIZE` 递增，且不跨 4 KiB 边界；
7. B/R 返回必须按 ID 送回正确的 XPU；
8. 下游施加任意背压时，XPU 不能丢请求、重复请求或改变 payload；
9. reset 后所有 `VALID` 清零，不能留下半笔事务；
10. 明确内存序：同 ID 是否保序，不同 ID 是否允许乱序，barrier 在哪里生效。

这些规则应做成 AXI protocol checker/SVA，不能只靠 waveform 肉眼看。

### 3. 三类 XPU 的具体接法

#### CPU

观察点应放在最后一级 cache/一致性层之后，转换的是实际离开 CPU 子系统的内存请求，而不是
每条 load/store 指令。若 CPU 来自 gem5，应使用 timing request/response port 形成可等待的
事务；现有 `CommMonitor` tap 只读观察、不能把下游延迟反馈给 CPU。

#### NPU

CoralNPU 已有 AXI master 行为，但当前 gem5 集成把读写收敛为“同一 callback 内同步返回”，
因此是零延迟功能访问。正式接入必须保留 RTL 的 AXI ready/valid 语义：下游未返回时让 AXI
通道停等，而不是先返回伪数据再补结果。重点测试 multi-beat、窄写、`WSTRB`、ID 和读响应
背压。

#### GPU

GPU 至少有两类流量：核/cache miss/writeback，以及命令处理器的 DMA。现项目曾验证过只接核
tap 会遗漏 CP 搬运，导致“计算正确但 host/GPU 共享 line 为 0”。XPU-to-AXI 必须把这两类
流量都送入统一 AXI/互连，并用 `AxUSER` 或独立 ID 范围区分核和 DMA（如果分析需要）。

### 4. 多 XPU 汇聚

当前 `storage_chain_top.sv` 暴露一个 AXI slave 端口，假设 CPU/NPU/GPU 已由上游互连仲裁，
`AWUSER/ARUSER` 分别取：

```text
0 = CPU
1 = NPU
2 = GPU
3 = reserved
```

实际实现可选择：

- 三个独立 AXI slave port + 一个项目内 AXI interconnect；
- 使用成熟 AXI interconnect IP；
- XPU 侧先变成统一 request packet，再在 packet 层仲裁。

优先推荐成熟 AXI interconnect。自研互连很容易在 AW/W 解耦、ID 扩展和响应路由上出错。

## 已搭建的 AXI 边界后端功能链

路径位于 `storage_chain/`：

```text
reference XPU AXI BFM
  -> axi_to_memreq
  -> ucie_link_model
  -> mc_model
  -> dfi_memory_model
  -> byte-addressed storage
```

### 模块边界

| 模块 | 当前验证内容 | 尚未建模 |
|---|---|---|
| `axi_to_memreq` | 五通道握手、INCR burst、ID、USER、WSTRB、背压 | 多 outstanding、乱序、原子 |
| `ucie_link_model` | 双向无损传输、固定延迟、反压 | flit、credit、CRC/retry、训练、lane |
| `mc_model` | 请求接收、固定调度延迟、metadata 返回 | bank/row scheduler、QoS、refresh |
| `dfi_memory_model` | 简化 command/response、固定延迟、byte array | 标准 DFI 信号/训练、DDR PHY 时序 |
| `tb_storage_chain` | 三源标识、burst、读回、WSTRB、R 背压、逐级计数 | 随机并发、性能覆盖、协议 VIP |

这里的 `ucie_link_model` 和 `dfi_memory_model` 名字表达它们将来要替换的位置，不代表已经实现
对应标准。

### 运行与验收

```bash
make test-storage-chain
```

testbench 做三组数据交接：

1. CPU 写 4 beats，NPU 读回；
2. GPU 写 2 beats，CPU 读回；
3. CPU 写 64 位整字，GPU 用 `WSTRB=0x0f` 只覆盖低 32 位，NPU 读回组合结果。

同时在第一拍读响应上主动拉低 `RREADY` 两个周期，检查 `RVALID/RDATA` 保持稳定。成功输出：

```text
CHAIN PASS: AXI beats=15, UCIe req/rsp=15/15, MC cmds=15, DFI writes/reads=8/7
```

这证明 15 个 AXI beat 在每一级都一进一出，8 次写和 7 次读的数据正确，且部分写与背压没有
破坏链路。

## 如何把你的 XPU AXI 接进 demo

1. 保持 `storage_chain_top.sv` 下游不变；
2. 用你的 XPU master 替换 `tb/tb_storage_chain.sv` 中的 AXI BFM；
3. 把 XPU 的 `AW* W* B* AR* R*` 连接到 top 的 `s_axi_*`；
4. 每类 XPU设置固定 `AxUSER`，不要在 AW 与 AR 上使用不同编码；
5. 先限制单 outstanding、对齐 INCR burst，让现有 scoreboard 通过；
6. 再扩展多 outstanding，并同步扩展 `axi_to_memreq` 和 MC/tag scoreboard；
7. 保留六个 stage counter。任何计数不相等都先当成丢包/重复包处理；
8. 在 XPU AXI 边界继续挂 HETTrace，用于对比“XPU 发出”与“MC 收到”的地址流。

现有 `.hettrace` 只含地址、大小、读写和时间，没有 write data，因此可以用来做地址/流量回放，
不能单独完成数据正确性验证。功能验证必须由真实 XPU data channel 或测试 BFM 提供 WDATA，
并用读回 scoreboard 检查。

## 从功能链走向真实模型的替换顺序

### 阶段 A：你现在应完成的 XPU-to-AXI

- 三个 XPU 的 AXI master 或 transactor；
- AXI checker；
- 每源 ID/USER 规划；
- 背压、reset、burst、部分写测试；
- 与本 demo 联调到 `CHAIN PASS`。

### 阶段 B：AXI 与 UCIe 协议选择

如果需要跨厂商/标准内存语义，优先评估 CXL.mem over UCIe；如果两端都是自研 chiplet 且只做
研究原型，可把 `mem_req packet` 映射到 UCIe streaming/raw transport。无论选哪种，都要定义
request/response packet、credit、最大 payload、顺序、错误和 retry 语义。

### 阶段 C：替换 UCIe 占位

加入 adapter、flit packing、credit/backpressure、CRC/retry、link training 和双时钟 CDC。
保留 transaction tag，比较 UCIe 两端的请求/响应计数和 payload hash。

### 阶段 D：替换 MC 与存储数组

先实现 address mapping（channel/rank/bank/row/column）和调度队列，再连接 Ramulator/DRAMsim
一类模型。此时才开始报告排队延迟、带宽、row hit rate 和公平性。

### 阶段 E：标准 DFI/PHY 验证

只有目标确实需要 MC-to-PHY 联调时，再把简化 DFI 边界替换为对应 DDR/LPDDR/HBM 版本的标准
DFI 信号与 VIP。DFI 版本、频率比、训练、低功耗和 refresh 必须与具体 memory technology
一起冻结，不能只写“支持 DFI”。

## 最小完成判据

你的 XPU-to-AXI 部分达到以下条件，才算可以交给后级继续建模：

- 三种 XPU 都能独立跑过 1/2/4/16 beat 的读写；
- AW/W 任意错开、所有 READY 随机拉低时仍无死锁和丢包；
- `WSTRB`、ID、RESP、LAST、USER 全部由 checker 覆盖；
- reset 可在空闲和事务中间注入，恢复策略有明确规格；
- 同地址的 CPU→NPU、GPU→CPU、CPU/GPU 部分写交接读回正确；
- XPU 出口、UCIe 两端、MC、memory 的请求数与 payload hash 对得上；
- HETTrace 地址流与 AXI handshake 后实际接受的请求一致；
- 文档明确当前是一致还是非一致内存，以及软件/硬件由谁负责 flush、barrier 和可见性。
