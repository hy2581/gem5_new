"""hettrace 文件读取。

二进制与文本两种格式统一成同一个 Record namedtuple，下游工具不必关心格式。

一切都做成迭代器：长跑产生的 trace 可以到几十 GB，任何 "先读进 list" 的写法
在真实数据上都会 OOM。
"""

from __future__ import annotations

import json
import os
import struct
from collections import namedtuple

from . import addrmap

MAGIC = b"HETTRC\x00\x01"
HEADER_SIZE = 64
RECORD_SIZE = 32
FORMAT_VERSION = 1

HDR_FILTERED_DRAM = 1 << 0

FLAG_BURST_BEAT = 1 << 0
FLAG_PREFETCH = 1 << 1
FLAG_UNMAPPED = 1 << 2
FLAG_INSTR = 1 << 3
# Vortex 的 CP DMA 走这一位（vortexint/vortex_trace.h）。真 trace 里 vortex 源
# 大半的记录都带它 —— 少了这个常量，任何想按"核 vs 搬运引擎"分开看的代码都得
# 自己写死 16，而 record.h 一改就没人发现。
FLAG_DMA = 1 << 4

OP_READ = 0
OP_WRITE = 1

# 与 libhettrace/include/hettrace/record.h 的 FileHeader 逐字段对应
_HEADER_STRUCT = struct.Struct("<8sIIQQHBB28s")
# 与 Record 逐字段对应
_RECORD_STRUCT = struct.Struct("<QQIIIHBB")

Header = namedtuple(
    "Header",
    "version record_size ticks_per_second clock_period_ticks "
    "src_id level flags name filtered_dram",
)

Record = namedtuple("Record", "tick addr size ctx seq src_id op flags")


class TraceError(Exception):
    pass


def _decode_header(buf):
    if len(buf) < HEADER_SIZE:
        raise TraceError("文件短于 %d 字节，不是合法 hettrace" % HEADER_SIZE)
    magic, ver, rsize, tps, cpt, src_id, level, flags, name = _HEADER_STRUCT.unpack(
        buf[: _HEADER_STRUCT.size]
    )
    if magic != MAGIC:
        raise TraceError("magic 不匹配: %r（期望 %r）" % (magic, MAGIC))
    if ver != FORMAT_VERSION:
        raise TraceError("格式版本 %d 不受支持（本工具支持 %d）" % (ver, FORMAT_VERSION))
    if rsize != RECORD_SIZE:
        raise TraceError("record_size=%d，期望 %d" % (rsize, RECORD_SIZE))
    return Header(
        version=ver,
        record_size=rsize,
        ticks_per_second=tps,
        clock_period_ticks=cpt,
        src_id=src_id,
        level=level,
        flags=flags,
        name=name.rstrip(b"\x00").decode("utf-8", "replace"),
        filtered_dram=bool(flags & HDR_FILTERED_DRAM),
    )


def _parse_text_header(fh):
    """文本模式的头部是 5 行注释；解析出与二进制头等价的字段。"""
    fields = {}
    pos = fh.tell()
    while True:
        line = fh.readline()
        if not line:
            break
        if not line.startswith("#"):
            fh.seek(pos)
            break
        for tok in line[1:].split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                fields[k] = v
        pos = fh.tell()

    name = fields.get("name", "unknown")
    level_raw = fields.get("level", "0")
    return Header(
        version=FORMAT_VERSION,
        record_size=RECORD_SIZE,
        ticks_per_second=int(fields.get("ticks_per_second", addrmap.TICKS_PER_SECOND)),
        clock_period_ticks=int(fields.get("clock_period_ticks", 0)),
        src_id=int(fields.get("src_id", 0)),
        level=int(level_raw),
        flags=HDR_FILTERED_DRAM if fields.get("filter") == "dram" else 0,
        name=name,
        filtered_dram=fields.get("filter") == "dram",
    )


def is_text(path):
    return path.endswith(".txt")


def read_header(path):
    if is_text(path):
        with open(path, "r") as fh:
            return _parse_text_header(fh)
    with open(path, "rb") as fh:
        return _decode_header(fh.read(HEADER_SIZE))


def read_records(path, chunk_records=8192):
    """流式产出 Record。"""
    if is_text(path):
        with open(path, "r") as fh:
            _parse_text_header(fh)
            for line in fh:
                if not line.strip() or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) != 8:
                    raise TraceError("文本记录字段数为 %d，期望 8: %r" % (len(parts), line))
                tick, src, op, addr, size, ctx, seq, flags = parts
                yield Record(
                    tick=int(tick),
                    addr=int(addr, 16),
                    size=int(size),
                    ctx=int(ctx),
                    seq=int(seq),
                    src_id=int(src),
                    op=OP_WRITE if op == "W" else OP_READ,
                    flags=int(flags, 16),
                )
        return

    unpack = _RECORD_STRUCT.unpack_from
    with open(path, "rb") as fh:
        hdr_buf = fh.read(HEADER_SIZE)
        _decode_header(hdr_buf)
        bufsize = RECORD_SIZE * chunk_records
        tail = b""
        while True:
            chunk = fh.read(bufsize)
            if not chunk:
                break
            if tail:
                chunk = tail + chunk
            n = len(chunk) // RECORD_SIZE
            for i in range(n):
                tick, addr, size, ctx, seq, src_id, op, flags = unpack(
                    chunk, i * RECORD_SIZE
                )
                yield Record(tick, addr, size, ctx, seq, src_id, op, flags)
            tail = chunk[n * RECORD_SIZE :]
        if tail:
            # 截断的尾部记录：进程被杀且缓冲未刷出的典型症状。
            raise TraceError(
                "文件尾部有 %d 字节残余（不是 %d 的整数倍）——"
                "trace 可能被截断，不要用于分析" % (len(tail), RECORD_SIZE)
            )


def read_meta(path):
    """读侧车 meta.json；不存在返回 None。"""
    mp = path + ".meta.json"
    if not os.path.exists(mp):
        return None
    with open(mp) as f:
        return json.load(f)


def discover(directory):
    """返回目录下所有 trace 文件路径，按源 id 排序。"""
    out = []
    for fn in sorted(os.listdir(directory)):
        if fn.endswith(".meta.json"):
            continue
        if not (fn.endswith(".hettrace") or fn.endswith(".hettrace.txt")):
            continue
        path = os.path.join(directory, fn)
        try:
            hdr = read_header(path)
        except (TraceError, OSError):
            continue
        out.append((path, hdr))
    out.sort(key=lambda ph: (ph[1].src_id, ph[0]))
    return out
