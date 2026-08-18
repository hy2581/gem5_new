"""hettrace 命令行入口。

    python3 -m hettrace validate  <trace_dir>
    python3 -m hettrace merge     <trace_dir> [-o out.txt]
    python3 -m hettrace stats     <trace_dir> [--window TICKS] [--line BYTES]
    python3 -m hettrace dump      <trace_file> [-n N]
    python3 -m hettrace convert   <trace_dir> --preset readwrite [-o out.trace]
"""

from __future__ import annotations

import argparse
import os
import sys

from . import addrmap, convert as convert_mod, merge, stats, validate
from .reader import OP_WRITE, TraceError, read_header, read_meta, read_records


def _positive_int(s):
    """argparse 类型：必须为正。

    0 不是"没有限制"而是死循环 / 除零：--window 0 会让 bandwidth_timeline 的
    窗口永远推不动，--line 0 会在 footprint 里除零。这两个都出现过，所以在
    参数层就挡掉，而不是等到跑起来。
    """
    v = int(s)
    if v <= 0:
        raise argparse.ArgumentTypeError("必须是正整数，收到 %r" % s)
    return v


def _nonneg_int(s):
    v = int(s)
    if v < 0:
        raise argparse.ArgumentTypeError("不能为负，收到 %r" % s)
    return v


def cmd_validate(args):
    issues, summaries = validate.validate_dir(args.trace_dir)
    print(validate.format_report(issues, summaries))
    return 1 if any(i.level == "ERROR" for i in issues) else 0


def cmd_merge(args):
    records, entries = merge.merge_dir(args.trace_dir)
    if not entries:
        sys.stderr.write("%s 下没有 trace 文件\n" % args.trace_dir)
        return 1
    sys.stderr.write(
        "归并 %d 个源: %s\n"
        % (len(entries), ", ".join(h.name for _p, h in entries))
    )
    if args.output:
        with open(args.output, "w") as fh:
            n = merge.write_text(records, fh)
        sys.stderr.write("写出 %d 条到 %s\n" % (n, args.output))
    else:
        n = merge.write_text(records, sys.stdout)
        sys.stderr.write("写出 %d 条\n" % n)
    return 0


def cmd_stats(args):
    print(stats.format_report(args.trace_dir, args.window, args.line))
    return 0


def cmd_dump(args):
    try:
        hdr = read_header(args.trace_file)
    except (TraceError, OSError) as e:
        sys.stderr.write("%s\n" % e)
        return 1
    print("# 文件: %s" % args.trace_file)
    print(
        "# src_id=%d name=%s level=%s clock_period_ticks=%d filter=%s"
        % (
            hdr.src_id,
            hdr.name,
            addrmap.LEVEL_NAMES.get(hdr.level, hdr.level),
            hdr.clock_period_ticks,
            "dram" if hdr.filtered_dram else "all",
        )
    )
    meta = read_meta(args.trace_file)
    if meta:
        print(
            "# meta: emitted=%s filtered=%s unmapped=%s non_monotonic=%s"
            % (
                meta.get("emitted"),
                meta.get("filtered"),
                meta.get("unmapped"),
                meta.get("non_monotonic"),
            )
        )
    print("# %-14s %-3s %-12s %6s %6s %6s %-6s %s" % (
        "tick", "op", "addr", "size", "ctx", "seq", "flags", "region"))
    n = 0
    for r in read_records(args.trace_file):
        if args.count and n >= args.count:
            print("# ... (--count %d 截断)" % args.count)
            break
        print(
            "  %-14d %-3s 0x%-10x %6d %6d %6d 0x%-4x %s"
            % (
                r.tick,
                "W" if r.op == OP_WRITE else "R",
                r.addr,
                r.size,
                r.ctx,
                r.seq,
                r.flags,
                addrmap.region_of(r.addr) or "-",
            )
        )
        n += 1
    return 0


def cmd_convert(args):
    if args.list_presets:
        print(convert_mod.list_presets())
        return 0

    template = args.template
    if template is None:
        if args.preset not in convert_mod.PRESETS:
            sys.stderr.write(
                "未知预设 %r。可用: %s\n"
                % (args.preset, ", ".join(convert_mod.PRESETS))
            )
            return 1
        template = convert_mod.PRESETS[args.preset]["template"]

    srcs = None
    if args.sources:
        srcs = set()
        for tok in args.sources.split(","):
            tok = tok.strip()
            if tok in addrmap.SOURCES:
                srcs.add(addrmap.SOURCES[tok][0])
                continue
            try:
                srcs.add(int(tok, 0))
            except ValueError:
                sys.stderr.write(
                    "--sources 里的 %r 既不是源名也不是数字 id。可用源名: %s\n"
                    % (tok, ", ".join(sorted(addrmap.SOURCES)))
                )
                return 1

    records, entries = merge.merge_dir(args.trace_dir)
    if not entries:
        sys.stderr.write("%s 下没有 trace 文件\n" % args.trace_dir)
        return 1

    if args.output:
        with open(args.output, "w") as fh:
            n = convert_mod.convert(records, fh, template, srcs)
        sys.stderr.write("写出 %d 条到 %s\n" % (n, args.output))
    else:
        n = convert_mod.convert(records, sys.stdout, template, srcs)
        sys.stderr.write("写出 %d 条\n" % n)
    return 0


def build_parser():
    p = argparse.ArgumentParser(
        prog="hettrace", description="异构访存 trace 工具"
    )
    sub = p.add_subparsers(dest="cmd")

    v = sub.add_parser("validate", help="校验 trace 是否可用于分析")
    v.add_argument("trace_dir")
    v.set_defaults(func=cmd_validate)

    m = sub.add_parser("merge", help="按全局 tick 归并多源 trace")
    m.add_argument("trace_dir")
    m.add_argument("-o", "--output")
    m.set_defaults(func=cmd_merge)

    s = sub.add_parser("stats", help="带宽 / footprint / 共享度统计")
    s.add_argument("trace_dir")
    s.add_argument(
        "--window", type=_positive_int, default=1000000,
        help="带宽窗口 tick 数，默认 1e6 (=1us)")
    s.add_argument("--line", type=_positive_int, default=64,
                   help="cache line 字节数")
    s.set_defaults(func=cmd_stats)

    d = sub.add_parser("dump", help="人读单个 trace 文件")
    d.add_argument("trace_file")
    d.add_argument("-n", "--count", type=_nonneg_int, default=50,
                   help="最多打印多少条，0 表示全部")
    d.set_defaults(func=cmd_dump)

    c = sub.add_parser("convert", help="转换为下游 DRAM 模拟器格式")
    c.add_argument("trace_dir", nargs="?")
    c.add_argument("--preset", default="readwrite")
    c.add_argument("--template", help="自定义格式串，覆盖 --preset")
    c.add_argument("--sources", help="只保留这些源，逗号分隔（名字或 id）")
    c.add_argument("-o", "--output")
    c.add_argument("--list-presets", action="store_true")
    c.set_defaults(func=cmd_convert)

    return p


def main(argv=None):
    p = build_parser()
    args = p.parse_args(argv)
    if not getattr(args, "func", None):
        p.print_help()
        return 1
    if args.cmd == "convert" and args.list_presets:
        return cmd_convert(args)
    if args.cmd == "convert" and not args.trace_dir:
        p.error("convert 需要 trace_dir（或用 --list-presets）")

    try:
        return args.func(args)
    except TraceError as e:
        # 截断的 trace 是 read_records 在流中途才发现的（尾部残余字节），所以
        # 这个异常可以从 merge / stats / convert / dump 的任何一处冒出来。它是
        # 本工具**预期要检测**的失效形态，用 traceback 报出来只会让人以为是工具
        # 自己崩了 —— 而且 merge/convert 此时已经写出了一部分内容。
        sys.stderr.write("hettrace: %s\n" % e)
        sys.stderr.write(
            "         先跑 hettrace validate 看是哪个源出的问题。"
            "merge / convert 此前写出的内容是残缺的，不要使用。\n"
        )
        return 1
    except BrokenPipeError:
        # `hettrace merge dir | head` 的正常收场。必须排在 OSError 之前 ——
        # BrokenPipeError 是它的子类。按 CPython 官方建议把 stdout 重定向到
        # devnull，否则解释器退出时刷缓冲还会再抛一次，屏幕上留下
        # "Exception ignored in: <_io.TextIOWrapper name='<stdout>'>"。
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        return 1
    except OSError as e:
        sys.stderr.write("hettrace: %s\n" % e)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
