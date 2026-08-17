"""转换成下游 DRAM 模拟器的输入格式。

关于 ramulator2 的格式：本工程不假定 ramulator2 的 trace 前端格式，因为它在
不同版本间变过。这里给两个常见方言的预设，外加一个 --template 自由格式；请对
照 /home/hy258/ramulator2/src/frontend/impl/ 下实际的 reader 确认后再选用。
`hettrace convert --list-presets` 会打印每个预设的样例行。

无时间戳的格式（如 readwrite）丢掉 tick，只保留顺序 —— 顺序来自按全局 tick
的归并，因此跨源交织关系是保留的，但下游模拟器会按自己的节奏发请求。这一点
连同 docs/03-limitations.md 里的反馈缺失问题一起，构成结论的适用边界。
"""

from __future__ import annotations

from .reader import OP_WRITE

PRESETS = {
    # ramulator2 readwrite_trace 风格：十六进制地址 + R/W
    "readwrite": {
        "template": "{addr:#x} {rw}",
        "example": "0x90000040 R",
        "note": "十六进制地址 + R/W，无时间戳",
    },
    # 十进制地址 + R/W，部分版本的 ramulator/DRAMsim 用
    "dec_readwrite": {
        "template": "{addr} {rw}",
        "example": "2415919168 R",
        "note": "十进制地址 + R/W，无时间戳",
    },
    # 保留 tick 与源，便于自研模型 / 排查
    "timed": {
        "template": "{tick} {src} {rw} {addr:#x} {size}",
        "example": "1000 1 R 0x90000040 64",
        "note": "带 tick 与源 id，信息无损，供自研 DRAM 模型使用",
    },
}


def list_presets():
    L = []
    for name, d in PRESETS.items():
        L.append("%-14s %-28s %s" % (name, d["example"], d["note"]))
    return "\n".join(L)


def convert(records, out_fh, template, sources=None):
    """按 template 逐条格式化写出。

    template 可用字段: tick, addr, size, ctx, seq, src, rw, op
    sources 非 None 时只保留这些 src_id。
    """
    n = 0
    for r in records:
        if sources is not None and r.src_id not in sources:
            continue
        out_fh.write(
            template.format(
                tick=r.tick,
                addr=r.addr,
                size=r.size,
                ctx=r.ctx,
                seq=r.seq,
                src=r.src_id,
                rw="W" if r.op == OP_WRITE else "R",
                op=r.op,
            )
        )
        out_fh.write("\n")
        n += 1
    return n
