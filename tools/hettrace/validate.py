"""trace 校验。

这个工具的存在理由：trace-driven 研究里最贵的错误是拿到一批"看起来正常"的
trace，分析了两周才发现时间基准接错了 / 地址没对齐到同一映射 / 三个源其实是
串行跑的。这里把那些失效模式全部前置成显式检查。

严重级别：
    ERROR — trace 不可用于分析，必须修
    WARN  — 可用但结论受限，必须在报告里写明
"""

from __future__ import annotations

from collections import namedtuple

from . import addrmap
from .reader import (
    FLAG_BURST_BEAT,
    FLAG_UNMAPPED,
    OP_WRITE,
    TraceError,
    discover,
    read_meta,
    read_records,
)

Issue = namedtuple("Issue", "level source message")

SrcSummary = namedtuple(
    "SrcSummary",
    "name src_id level count reads writes bytes first_tick last_tick "
    "regions unmapped burst_beats",
)


def _summarize(path, hdr):
    count = reads = writes = nbytes = 0
    first_tick = last_tick = None
    non_monotonic = 0
    seq_gaps = 0
    expected_seq = 0
    regions = {}
    unmapped = 0
    burst_beats = 0
    bad_accessor = {}

    src_name = hdr.name
    # 文件头里的 name 可能是测试用的临时名；以 src_id 反查规范名做权限判定。
    canonical = addrmap.SRC_NAME_BY_ID.get(hdr.src_id)

    for r in read_records(path):
        count += 1
        if r.op == OP_WRITE:
            writes += 1
        else:
            reads += 1
        nbytes += r.size

        if first_tick is None:
            first_tick = r.tick
        elif r.tick < last_tick:
            non_monotonic += 1
        last_tick = r.tick

        if r.seq != expected_seq:
            seq_gaps += 1
            expected_seq = r.seq
        expected_seq += 1

        if r.flags & FLAG_UNMAPPED:
            unmapped += 1
        if r.flags & FLAG_BURST_BEAT:
            burst_beats += 1

        reg = addrmap.region_of(r.addr)
        key = reg or "<unmapped>"
        regions[key] = regions.get(key, 0) + 1

        if reg is not None and canonical is not None:
            if canonical not in addrmap.REGIONS[reg][3]:
                bad_accessor[reg] = bad_accessor.get(reg, 0) + 1

    summary = SrcSummary(
        name=src_name,
        src_id=hdr.src_id,
        level=hdr.level,
        count=count,
        reads=reads,
        writes=writes,
        bytes=nbytes,
        first_tick=first_tick or 0,
        last_tick=last_tick or 0,
        regions=regions,
        unmapped=unmapped,
        burst_beats=burst_beats,
    )
    return summary, non_monotonic, seq_gaps, bad_accessor


def validate_dir(directory):
    """返回 (issues, summaries)。"""
    issues = []
    summaries = []

    try:
        entries = discover(directory)
    except OSError as e:
        return [Issue("ERROR", "-", "无法读取目录 %s: %s" % (directory, e))], []

    if not entries:
        return [Issue("ERROR", "-", "%s 下没有 hettrace 文件" % directory)], []

    for path, hdr in entries:
        src = hdr.name
        try:
            summary, non_mono, seq_gaps, bad_accessor = _summarize(path, hdr)
        except TraceError as e:
            issues.append(Issue("ERROR", src, str(e)))
            continue
        summaries.append(summary)

        if summary.count == 0:
            issues.append(
                Issue("ERROR", src, "trace 为空 —— tap 没接上，或负载没触及该源")
            )
            continue

        # 时间基准接错的直接证据。
        if non_mono:
            issues.append(
                Issue(
                    "ERROR",
                    src,
                    "%d 次 tick 回退 —— 时间戳没有取自 gem5 全局 tick，"
                    "很可能误用了源内 cycle 计数" % non_mono,
                )
            )

        if seq_gaps:
            issues.append(
                Issue(
                    "ERROR",
                    src,
                    "seq 有 %d 处断裂 —— 记录丢失（缓冲未刷出 / 进程被杀）" % seq_gaps,
                )
            )

        # 与 meta 侧车交叉核对，捕捉截断。
        meta = read_meta(path)
        if meta is None:
            issues.append(
                Issue("WARN", src, "缺少 meta.json 侧车，无法交叉核对记录数")
            )
        elif meta.get("emitted") != summary.count:
            issues.append(
                Issue(
                    "ERROR",
                    src,
                    "meta 记录 emitted=%s，文件中实为 %d 条 —— trace 被截断"
                    % (meta.get("emitted"), summary.count),
                )
            )

        # 时钟域：头部声明必须与 addrmap.json 一致，否则 tick 折算是错的。
        canonical = addrmap.SRC_NAME_BY_ID.get(hdr.src_id)
        if canonical is None:
            issues.append(
                Issue("WARN", src, "src_id=%d 不在 addrmap.json 中" % hdr.src_id)
            )
        else:
            _sid, exp_level, _mhz, exp_period = addrmap.SOURCES[canonical]
            if hdr.clock_period_ticks != exp_period:
                issues.append(
                    Issue(
                        "ERROR",
                        src,
                        "clock_period_ticks=%d，addrmap.json 声明为 %d —— "
                        "时钟域配置不一致"
                        % (hdr.clock_period_ticks, exp_period),
                    )
                )
            if hdr.level != addrmap.LEVELS[exp_level]:
                issues.append(
                    Issue(
                        "ERROR",
                        src,
                        "tap 层级为 %s，addrmap.json 声明为 %s —— "
                        "混用不同层级的 trace 无法互相比对"
                        % (
                            addrmap.LEVEL_NAMES.get(hdr.level, hdr.level),
                            exp_level,
                        ),
                    )
                )

        if summary.unmapped:
            issues.append(
                Issue(
                    "ERROR",
                    src,
                    "%d 条记录落在所有已声明区域之外 —— 地址映射与实际负载不符"
                    % summary.unmapped,
                )
            )

        for reg, n in sorted(bad_accessor.items()):
            issues.append(
                Issue(
                    "WARN",
                    src,
                    "%d 次访问 region %s，但 addrmap.json 未把 %s 列为其 accessor"
                    % (n, reg, canonical),
                )
            )

    issues.extend(_cross_source_checks(summaries))
    return issues, summaries


def _cross_source_checks(summaries):
    """跨源检查 —— 决定这批 trace 到底有没有"异构"信息量。"""
    issues = []
    live = [s for s in summaries if s.count > 0]
    if len(live) < 2:
        issues.append(
            Issue(
                "ERROR",
                "-",
                "只有 %d 个源产生了记录 —— 这不是异构 trace" % len(live),
            )
        )
        return issues

    # 1. 共享区必须被至少两个源真实触及，否则三条 trace 互不相关，
    #    归并出来也看不到任何交接行为。
    for reg in addrmap.SHARED_REGIONS:
        touchers = [s.name for s in live if s.regions.get(reg, 0) > 0]
        if len(touchers) < 2:
            issues.append(
                Issue(
                    "ERROR",
                    "-",
                    "共享区 %s 只被 %s 触及 —— 负载没有真正的跨设备数据交接，"
                    "trace 退化为三条不相干的流"
                    % (reg, touchers or "任何源都没有"),
                )
            )
        else:
            issues.append(
                Issue("INFO", "-", "共享区 %s 被 %s 共同访问" % (reg, ", ".join(touchers)))
            )

    # 2. 时间区间必须重叠。不重叠说明三者是串行跑的，没有任何争抢可分析。
    for i in range(len(live)):
        for j in range(i + 1, len(live)):
            a, b = live[i], live[j]
            lo = max(a.first_tick, b.first_tick)
            hi = min(a.last_tick, b.last_tick)
            if lo >= hi:
                issues.append(
                    Issue(
                        "WARN",
                        "-",
                        "%s [%d,%d] 与 %s [%d,%d] 时间区间不重叠 —— "
                        "两者串行执行，这段 trace 无法用于争抢分析"
                        % (
                            a.name,
                            a.first_tick,
                            a.last_tick,
                            b.name,
                            b.first_tick,
                            b.last_tick,
                        ),
                    )
                )

    return issues


def format_report(issues, summaries):
    L = []
    a = L.append

    a("=" * 72)
    a("hettrace 校验报告")
    a("=" * 72)
    a("")
    a("每源统计:")
    a(
        "  %-10s %-12s %10s %10s %10s %12s"
        % ("源", "层级", "记录数", "读", "写", "字节")
    )
    for s in summaries:
        a(
            "  %-10s %-12s %10d %10d %10d %12d"
            % (
                s.name,
                addrmap.LEVEL_NAMES.get(s.level, "?"),
                s.count,
                s.reads,
                s.writes,
                s.bytes,
            )
        )
    a("")
    a("时间区间 (gem5 tick):")
    for s in summaries:
        span = s.last_tick - s.first_tick
        a(
            "  %-10s [%14d, %14d]  跨度 %d tick (%.3f us)"
            % (
                s.name,
                s.first_tick,
                s.last_tick,
                span,
                span / (addrmap.TICKS_PER_SECOND / 1e6),
            )
        )
    a("")
    a("区域分布:")
    for s in summaries:
        a("  %s:" % s.name)
        total = max(s.count, 1)
        for reg, n in sorted(s.regions.items(), key=lambda kv: -kv[1]):
            a("    %-16s %10d  (%5.1f%%)" % (reg, n, 100.0 * n / total))
    a("")

    errors = [i for i in issues if i.level == "ERROR"]
    warns = [i for i in issues if i.level == "WARN"]
    infos = [i for i in issues if i.level == "INFO"]

    for label, group in (("ERROR", errors), ("WARN", warns), ("INFO", infos)):
        if not group:
            continue
        a("%s (%d):" % (label, len(group)))
        for i in group:
            a("  [%s] %s" % (i.source, i.message))
        a("")

    if errors:
        a("结论: 不可用。先修掉 %d 个 ERROR。" % len(errors))
    elif warns:
        a("结论: 可用，但有 %d 项限制必须写进报告。" % len(warns))
    else:
        a("结论: 通过。")
    a("=" * 72)
    return "\n".join(L)
