"""合成 trace 生成器。

用途有两个，都不是玩具：

1. 让 Python 工具链（归并 / 校验 / 统计 / 转换）在三个仿真器都还没编出来时
   就能被测试。工具链的 bug 若等到真 trace 出来才发现，排查成本高得多。
2. 造出各种失效形态（tick 回退、seq 断裂、无共享、串行不重叠），验证
   validate 真的能抓住它们 —— 一个从不报错的校验器没有价值。

写出的文件与 libhettrace 的二进制格式逐字节兼容，由 tools/tests 交叉验证。
"""

from __future__ import annotations

import os
import struct

from . import addrmap
from .reader import (
    FLAG_UNMAPPED,
    HDR_FILTERED_DRAM,
    MAGIC,
    OP_READ,
    OP_WRITE,
    RECORD_SIZE,
    _HEADER_STRUCT,
    _RECORD_STRUCT,
)


class SynthWriter:
    """按 libhettrace 二进制格式写出，字段语义与 C++ TraceWriter 一致。"""

    def __init__(self, directory, src_name, filtered_dram=True):
        if src_name not in addrmap.SOURCES:
            raise ValueError("未知源 %r" % src_name)
        self.src_id, level, _mhz, self.period = addrmap.SOURCES[src_name]
        self.level = addrmap.LEVELS[level]
        self.name = src_name
        self.path = os.path.join(directory, "%s.hettrace" % src_name)
        self.filtered_dram = filtered_dram
        self._recs = []
        self._seq = 0
        self._stats = {
            "emitted": 0, "filtered": 0, "unmapped": 0,
            "non_monotonic": 0, "bytes": 0, "first_tick": 0, "last_tick": 0,
        }

    def emit(self, tick, addr, size, op, ctx=0, flags=0, seq=None):
        if addrmap.region_of(addr) is None:
            flags |= FLAG_UNMAPPED
            self._stats["unmapped"] += 1
        if self._stats["emitted"] == 0:
            self._stats["first_tick"] = tick
        elif tick < self._stats["last_tick"]:
            self._stats["non_monotonic"] += 1
        self._stats["last_tick"] = tick
        self._stats["emitted"] += 1
        self._stats["bytes"] += size

        s = self._seq if seq is None else seq
        self._seq = s + 1
        self._recs.append(
            _RECORD_STRUCT.pack(tick, addr, size, ctx, s, self.src_id, op, flags)
        )

    def close(self, write_meta=True, truncate_records=0):
        """truncate_records>0 时故意少写若干条，模拟缓冲未刷出的截断 trace。"""
        hdr = _HEADER_STRUCT.pack(
            MAGIC,
            1,
            RECORD_SIZE,
            addrmap.TICKS_PER_SECOND,
            self.period,
            self.src_id,
            self.level,
            HDR_FILTERED_DRAM if self.filtered_dram else 0,
            self.name.encode()[:27],
        )
        recs = self._recs
        if truncate_records:
            recs = recs[:-truncate_records]
        with open(self.path, "wb") as f:
            f.write(hdr)
            f.write(b"".join(recs))
        if write_meta:
            with open(self.path + ".meta.json", "w") as f:
                f.write("{\n")
                f.write('  "src_id": %d,\n' % self.src_id)
                f.write('  "name": "%s",\n' % self.name)
                f.write('  "level": %d,\n' % self.level)
                f.write('  "format": "bin",\n')
                f.write('  "filter": "%s",\n' % ("dram" if self.filtered_dram else "all"))
                f.write('  "ticks_per_second": %d,\n' % addrmap.TICKS_PER_SECOND)
                f.write('  "clock_period_ticks": %d,\n' % self.period)
                for k in ("emitted", "filtered", "unmapped", "non_monotonic",
                          "bytes", "first_tick"):
                    f.write('  "%s": %d,\n' % (k, self._stats[k]))
                f.write('  "last_tick": %d\n' % self._stats["last_tick"])
                f.write("}\n")
        return self.path


def gen_cooperative(directory, n_per_src=200):
    """健康形态：host 写共享 buffer -> Vortex 读改写 -> NPU 读结果。

    三者时间区间重叠，共享区被三方触及 —— 这是 validate 应当完全放行的形态，
    也是 workloads/shared_buffer 那个负载要在真机上复现的访问模式。
    """
    shared = addrmap.REGIONS["shared_buffer"][0]
    period = {n: addrmap.SOURCES[n][3] for n in ("host", "vortex", "coralnpu")}

    # host：填充共享 buffer，并在全程持续访问自己的堆
    h = SynthWriter(directory, "host")
    for i in range(n_per_src):
        h.emit(1000 + i * 10 * period["host"], shared + i * 64, 64, OP_WRITE, ctx=0)
        h.emit(1000 + (i * 10 + 5) * period["host"],
               addrmap.REGIONS["host_heap"][0] + i * 64, 64, OP_READ, ctx=0)
    h.close()

    # vortex：读共享 buffer 再写回，同时用自己的 VRAM
    v = SynthWriter(directory, "vortex")
    for i in range(n_per_src):
        base = 3000 + i * 12 * period["vortex"]
        v.emit(base, shared + i * 64, 64, OP_READ, ctx=i % 8)
        v.emit(base + 2 * period["vortex"],
               addrmap.REGIONS["vortex_vram"][0] + i * 64, 64, OP_READ, ctx=i % 8)
        v.emit(base + 4 * period["vortex"], shared + i * 64, 64, OP_WRITE, ctx=i % 8)
    v.close()

    # npu：读共享 buffer 的结果，写自己的工作区
    n = SynthWriter(directory, "coralnpu")
    for i in range(n_per_src):
        base = 5000 + i * 15 * period["coralnpu"]
        n.emit(base, shared + i * 64, 16, OP_READ, ctx=1)
        n.emit(base + period["coralnpu"],
               addrmap.REGIONS["npu_work"][0] + i * 16, 16, OP_WRITE, ctx=1)
    n.close()
    return directory


def gen_broken_no_sharing(directory, n=100):
    """失效形态：三个源各干各的，共享区无人触及。validate 必须报 ERROR。"""
    for name, reg in (("host", "host_heap"), ("vortex", "vortex_vram"),
                      ("coralnpu", "npu_work")):
        w = SynthWriter(directory, name)
        base = addrmap.REGIONS[reg][0]
        for i in range(n):
            w.emit(1000 + i * 100, base + i * 64, 64, OP_READ)
        w.close()
    return directory


def gen_broken_non_monotonic(directory, n=50):
    """失效形态：Vortex 的时间戳用了源内 cycle 而非全局 tick，出现回退。"""
    shared = addrmap.REGIONS["shared_buffer"][0]
    h = SynthWriter(directory, "host")
    for i in range(n):
        h.emit(1000 + i * 100, shared + i * 64, 64, OP_WRITE)
    h.close()

    v = SynthWriter(directory, "vortex")
    for i in range(n):
        tick = 1000 + i * 100
        if i == n // 2:
            tick = 500          # 回退
        v.emit(tick, shared + i * 64, 64, OP_READ)
    v.close()
    return directory


def gen_broken_serial(directory, n=50):
    """失效形态：三者串行执行，时间区间不重叠 —— 无争抢可分析，应报 WARN。"""
    shared = addrmap.REGIONS["shared_buffer"][0]
    for idx, name in enumerate(("host", "vortex", "coralnpu")):
        w = SynthWriter(directory, name)
        t0 = 1000 + idx * 10 ** 7
        for i in range(n):
            w.emit(t0 + i * 100, shared + i * 64, 64,
                   OP_WRITE if idx == 0 else OP_READ)
        w.close()
    return directory


def gen_broken_truncated(directory, n=50):
    """失效形态：meta 说 n 条，文件里只有 n-10 条 —— 进程被杀，缓冲丢了。"""
    shared = addrmap.REGIONS["shared_buffer"][0]
    h = SynthWriter(directory, "host")
    for i in range(n):
        h.emit(1000 + i * 100, shared + i * 64, 64, OP_WRITE)
    h.close()

    v = SynthWriter(directory, "vortex")
    for i in range(n):
        v.emit(1000 + i * 100, shared + i * 64, 64, OP_READ)
    v.close(truncate_records=10)
    return directory


def gen_broken_seq_gap(directory, n=50):
    """失效形态：seq 有洞 —— 记录在中途被丢弃。"""
    shared = addrmap.REGIONS["shared_buffer"][0]
    h = SynthWriter(directory, "host")
    for i in range(n):
        h.emit(1000 + i * 100, shared + i * 64, 64, OP_WRITE)
    h.close()

    v = SynthWriter(directory, "vortex")
    for i in range(n):
        seq = i if i < n // 2 else i + 7   # 断裂
        v.emit(1000 + i * 100, shared + i * 64, 64, OP_READ, seq=seq)
    v.close()
    return directory


SCENARIOS = {
    "cooperative": gen_cooperative,
    "no_sharing": gen_broken_no_sharing,
    "non_monotonic": gen_broken_non_monotonic,
    "serial": gen_broken_serial,
    "truncated": gen_broken_truncated,
    "seq_gap": gen_broken_seq_gap,
}
