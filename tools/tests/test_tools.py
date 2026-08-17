#!/usr/bin/env python3
"""hettrace Python 工具链自测。

    python3 tools/tests/test_tools.py

重点覆盖两类：
  - 归并/读取的正确性（含与 C++ writer 产物的交叉验证，若已编译）
  - validate 对每种失效形态都真的报错 —— 一个从不报错的校验器没有价值
"""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from hettrace import addrmap, convert, merge, stats, synth, validate  # noqa: E402
from hettrace.reader import (  # noqa: E402
    OP_READ,
    OP_WRITE,
    TraceError,
    discover,
    read_header,
    read_records,
)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_failed = 0
_checks = 0


def check(cond, msg):
    global _failed, _checks
    _checks += 1
    if not cond:
        sys.stderr.write("FAIL: %s\n" % msg)
        _failed += 1


def tmpdir():
    return tempfile.mkdtemp(prefix="hettrace_py_")


# ---------------------------------------------------------------------------
# 地址映射
# ---------------------------------------------------------------------------

def test_addrmap_generated_in_sync():
    r = subprocess.run(
        [sys.executable, os.path.join(ROOT, "scripts", "gen_addrmap.py"), "--check"],
        capture_output=True, text=True,
    )
    check(r.returncode == 0,
          "生成的 addrmap 应与 addrmap.json 同步:\n%s%s" % (r.stdout, r.stderr))


def test_addrmap_invariants():
    # CoralNPU 只有 32 位地址空间，所有 DRAM 区域必须落在 4GiB 内。
    for name, (base, size, kind, _acc) in addrmap.REGIONS.items():
        if kind != "dram":
            continue
        check(base + size <= (1 << addrmap.ADDR_BITS),
              "DRAM 区域 %s 超出 %d 位可寻址范围" % (name, addrmap.ADDR_BITS))
        check(addrmap.is_dram(base),
              "DRAM 区域 %s 应落在 CoralNPU 的 DDR 判定窗口内" % name)

    check(addrmap.SHARED_REGIONS, "必须至少有一个三方共享区")
    for name in addrmap.SHARED_REGIONS:
        check(len(addrmap.REGIONS[name][3]) >= 3,
              "共享区 %s 应有 ≥3 个 accessor" % name)

    shared_base = addrmap.REGIONS["shared_buffer"][0]
    check(addrmap.region_of(shared_base) == "shared_buffer", "region_of 应正确")
    check(addrmap.is_shared(shared_base), "is_shared 应正确")
    check(addrmap.region_of(0xDEADBEEF) is None, "未映射地址应返回 None")
    check(not addrmap.may_access("coralnpu", addrmap.REGIONS["host_heap"][0]),
          "NPU 不应被允许访问 host 私有堆")
    check(addrmap.may_access("coralnpu", shared_base),
          "NPU 应被允许访问共享区")


# ---------------------------------------------------------------------------
# 读取与归并
# ---------------------------------------------------------------------------

def test_synth_roundtrip():
    d = tmpdir()
    try:
        synth.gen_cooperative(d, n_per_src=20)
        entries = discover(d)
        check(len(entries) == 3, "应发现 3 个源，实为 %d" % len(entries))
        names = [h.name for _p, h in entries]
        check(names == ["host", "vortex", "coralnpu"],
              "应按 src_id 排序，实为 %r" % names)

        for path, hdr in entries:
            recs = list(read_records(path))
            check(len(recs) > 0, "%s 应有记录" % hdr.name)
            seqs = [r.seq for r in recs]
            check(seqs == list(range(len(recs))), "%s 的 seq 应连续" % hdr.name)
            check(all(r.src_id == hdr.src_id for r in recs),
                  "%s 每条记录的 src_id 应与头部一致" % hdr.name)
            _sid, _lvl, _mhz, period = addrmap.SOURCES[hdr.name]
            check(hdr.clock_period_ticks == period,
                  "%s 的时钟周期应与 addrmap 一致" % hdr.name)
    finally:
        shutil.rmtree(d)


def test_merge_is_totally_ordered():
    d = tmpdir()
    try:
        synth.gen_cooperative(d, n_per_src=40)
        records, entries = merge.merge_dir(d)
        merged = list(records)
        check(len(merged) > 0, "归并结果不应为空")

        keys = [(r.tick, r.src_id, r.seq) for r in merged]
        check(keys == sorted(keys), "归并结果应按 (tick, src_id, seq) 全序")

        # 记录总数必须守恒
        total = 0
        for path, _h in entries:
            total += sum(1 for _ in read_records(path))
        check(len(merged) == total,
              "归并不应丢记录: 合并后 %d, 各源合计 %d" % (len(merged), total))

        # 必须真的交织，否则归并没意义
        srcs_seen = []
        for r in merged:
            if not srcs_seen or srcs_seen[-1] != r.src_id:
                srcs_seen.append(r.src_id)
        check(len(srcs_seen) > 3, "归并流应在多源之间反复交织，实际切换 %d 次"
              % len(srcs_seen))
    finally:
        shutil.rmtree(d)


def test_merge_text_output():
    d = tmpdir()
    try:
        synth.gen_cooperative(d, n_per_src=10)
        records, _ = merge.merge_dir(d)
        buf = io.StringIO()
        n = merge.write_text(records, buf)
        text = buf.getvalue()
        check(n > 0, "应写出记录")
        check("shared_buffer" in text, "输出应带 region 列")
        check("host" in text and "vortex" in text and "coralnpu" in text,
              "输出应含三个源名")
        data_lines = [l for l in text.splitlines() if not l.startswith("#")]
        check(len(data_lines) == n, "数据行数应与返回值一致")
    finally:
        shutil.rmtree(d)


def test_truncated_file_raises():
    d = tmpdir()
    try:
        synth.gen_cooperative(d, n_per_src=10)
        p = os.path.join(d, "host.hettrace")
        with open(p, "ab") as f:
            f.write(b"\x00" * 7)   # 非记录整数倍的残余
        try:
            list(read_records(p))
            check(False, "尾部残余应抛 TraceError")
        except TraceError as e:
            check("截断" in str(e), "错误信息应提示截断，实为 %s" % e)
    finally:
        shutil.rmtree(d)


# ---------------------------------------------------------------------------
# validate 必须抓住每种失效形态
# ---------------------------------------------------------------------------

def _run_validate(d):
    issues, summaries = validate.validate_dir(d)
    errs = [i for i in issues if i.level == "ERROR"]
    warns = [i for i in issues if i.level == "WARN"]
    return issues, summaries, errs, warns


def test_validate_accepts_healthy():
    d = tmpdir()
    try:
        synth.gen_cooperative(d, n_per_src=50)
        issues, summaries, errs, _warns = _run_validate(d)
        check(not errs, "健康 trace 不应有 ERROR，实际: %r"
              % [(e.source, e.message) for e in errs])
        check(len(summaries) == 3, "应汇总 3 个源")
        infos = [i for i in issues if i.level == "INFO"]
        check(any("shared_buffer" in i.message for i in infos),
              "应报告共享区被三方访问")
        # 报告应能生成且不抛异常
        rep = validate.format_report(issues, summaries)
        check("结论" in rep, "报告应含结论行")
        check("通过" in rep or "限制" in rep, "健康 trace 结论应为通过或仅有限制")
    finally:
        shutil.rmtree(d)


def test_validate_catches_no_sharing():
    d = tmpdir()
    try:
        synth.gen_broken_no_sharing(d)
        _i, _s, errs, _w = _run_validate(d)
        check(any("共享" in e.message for e in errs),
              "应报出共享区无人触及，实际: %r" % [e.message for e in errs])
    finally:
        shutil.rmtree(d)


def test_validate_catches_non_monotonic():
    d = tmpdir()
    try:
        synth.gen_broken_non_monotonic(d)
        _i, _s, errs, _w = _run_validate(d)
        check(any("tick 回退" in e.message for e in errs),
              "应报出 tick 回退，实际: %r" % [e.message for e in errs])
    finally:
        shutil.rmtree(d)


def test_validate_catches_serial():
    d = tmpdir()
    try:
        synth.gen_broken_serial(d)
        _i, _s, _errs, warns = _run_validate(d)
        check(any("不重叠" in w.message for w in warns),
              "应警告时间区间不重叠，实际: %r" % [w.message for w in warns])
    finally:
        shutil.rmtree(d)


def test_validate_catches_truncation():
    d = tmpdir()
    try:
        synth.gen_broken_truncated(d)
        _i, _s, errs, _w = _run_validate(d)
        check(any("截断" in e.message for e in errs),
              "应报出截断，实际: %r" % [e.message for e in errs])
    finally:
        shutil.rmtree(d)


def test_validate_catches_seq_gap():
    d = tmpdir()
    try:
        synth.gen_broken_seq_gap(d)
        _i, _s, errs, _w = _run_validate(d)
        check(any("seq" in e.message for e in errs),
              "应报出 seq 断裂，实际: %r" % [e.message for e in errs])
    finally:
        shutil.rmtree(d)


def test_validate_catches_empty_dir():
    d = tmpdir()
    try:
        _i, _s, errs, _w = _run_validate(d)
        check(errs, "空目录应报 ERROR")
    finally:
        shutil.rmtree(d)


# ---------------------------------------------------------------------------
# 统计与转换
# ---------------------------------------------------------------------------

def test_stats_detects_sharing():
    d = tmpdir()
    try:
        synth.gen_cooperative(d, n_per_src=50)
        sizes, pairwise, lb = stats.footprint(d)
        check(len(sizes) == 3, "footprint 应覆盖 3 个源")
        check(lb == 64, "默认 line 应为 64 字节")
        # host 与 vortex 都访问共享 buffer 的同一批 line
        check(pairwise.get(("host", "vortex"), 0) > 0,
              "host 与 vortex 应有共享 line，实为 %r" % pairwise)
        check(pairwise.get(("coralnpu", "host"), 0) > 0
              or pairwise.get(("host", "coralnpu"), 0) > 0,
              "host 与 npu 应有共享 line，实为 %r" % pairwise)

        windows, srcs = stats.bandwidth_timeline(d, 100000)
        check(len(windows) > 0, "应产生带宽窗口")
        check(set(srcs) == {"host", "vortex", "coralnpu"}, "应覆盖三个源")
        overlap = sum(1 for w in windows
                      if sum(1 for n in srcs if w.per_src_count.get(n, 0) > 0) >= 2)
        check(overlap > 0, "协同负载应存在多源并发窗口")

        rep = stats.format_report(d, 100000)
        check("共享 line" in rep, "统计报告应含共享 line 段")
    finally:
        shutil.rmtree(d)


def test_stats_no_sharing_reports_zero():
    d = tmpdir()
    try:
        synth.gen_broken_no_sharing(d)
        _sizes, pairwise, _lb = stats.footprint(d)
        check(all(v == 0 for v in pairwise.values()),
              "各干各的负载不应有共享 line，实为 %r" % pairwise)
    finally:
        shutil.rmtree(d)


def test_convert_presets():
    d = tmpdir()
    try:
        synth.gen_cooperative(d, n_per_src=10)
        records, _ = merge.merge_dir(d)
        buf = io.StringIO()
        n = convert.convert(records, buf,
                            convert.PRESETS["readwrite"]["template"])
        lines = buf.getvalue().strip().splitlines()
        check(len(lines) == n, "行数应与返回值一致")
        check(all(l.split()[1] in ("R", "W") for l in lines),
              "readwrite 预设第二列应为 R/W")
        check(all(l.split()[0].startswith("0x") for l in lines),
              "readwrite 预设地址应为十六进制")

        # 按源过滤
        records, _ = merge.merge_dir(d)
        buf2 = io.StringIO()
        npu_id = addrmap.SOURCES["coralnpu"][0]
        n2 = convert.convert(records, buf2,
                             convert.PRESETS["timed"]["template"], {npu_id})
        check(0 < n2 < n, "按源过滤应减少行数: %d vs %d" % (n2, n))
        for l in buf2.getvalue().strip().splitlines():
            check(int(l.split()[1]) == npu_id, "过滤后只应剩 NPU 记录")
    finally:
        shutil.rmtree(d)


def test_cli_end_to_end():
    """跑真正的命令行，捕捉 import / 参数解析层面的问题。"""
    d = tmpdir()
    try:
        synth.gen_cooperative(d, n_per_src=30)
        env = dict(os.environ)
        env["PYTHONPATH"] = os.path.join(ROOT, "tools")

        for args, want_rc in (
            (["validate", d], 0),
            (["stats", d], 0),
            (["merge", d], 0),
            (["convert", d, "--preset", "readwrite"], 0),
            (["convert", "--list-presets"], 0),
            (["dump", os.path.join(d, "host.hettrace"), "-n", "5"], 0),
        ):
            r = subprocess.run(
                [sys.executable, "-m", "hettrace"] + args,
                capture_output=True, text=True, env=env, cwd=ROOT,
            )
            check(r.returncode == want_rc,
                  "hettrace %s 应返回 %d，实为 %d\nstderr:\n%s"
                  % (" ".join(args[:2]), want_rc, r.returncode, r.stderr))

        # 坏 trace 应让 validate 以非零退出，这样能直接用于 CI 门禁
        d2 = tmpdir()
        try:
            synth.gen_broken_no_sharing(d2)
            r = subprocess.run(
                [sys.executable, "-m", "hettrace", "validate", d2],
                capture_output=True, text=True, env=env, cwd=ROOT,
            )
            check(r.returncode != 0, "坏 trace 应让 validate 非零退出")
        finally:
            shutil.rmtree(d2)
    finally:
        shutil.rmtree(d)


def test_cpp_writer_interop():
    """交叉验证：C++ TraceWriter 写的文件，Python 侧必须能原样读出。

    这是整条链上最关键的一个测试 —— 两侧的格式定义各写一遍，任何字段偏移或
    字节序分歧都会在这里暴露，而不是等到分析真 trace 时出现无意义的地址。
    """
    src = os.path.join(ROOT, "libhettrace", "tests", "test_writer.cc")
    inc = os.path.join(ROOT, "libhettrace", "include")
    if not os.path.exists(src):
        check(False, "找不到 C++ 测试源")
        return

    d = tmpdir()
    try:
        exe = os.path.join(d, "cpp_writer_test")
        r = subprocess.run(
            ["g++", "-std=c++17", "-I", inc, src, "-o", exe],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            check(False, "C++ 测试编译失败:\n%s" % r.stderr)
            return

        outdir = os.path.join(d, "traces")
        os.makedirs(outdir)
        env = dict(os.environ)
        env["HETTRACE_DIR"] = outdir
        env["HETTRACE_FORMAT"] = "bin"
        r = subprocess.run([exe], capture_output=True, text=True, env=env)
        check(r.returncode == 0, "C++ 测试应通过:\n%s%s" % (r.stdout, r.stderr))

        # C++ 侧写的 vortex.hettrace：3 条记录，字段已知
        p = os.path.join(outdir, "vortex.hettrace")
        check(os.path.exists(p), "C++ 应产出 vortex.hettrace")
        if not os.path.exists(p):
            return

        hdr = read_header(p)
        shared = addrmap.REGIONS["shared_buffer"][0]
        vram = addrmap.REGIONS["vortex_vram"][0]
        check(hdr.name == "vortex", "Python 应读出源名 vortex，实为 %r" % hdr.name)
        check(hdr.src_id == addrmap.SOURCES["vortex"][0], "src_id 应一致")
        check(hdr.clock_period_ticks == addrmap.SOURCES["vortex"][3],
              "时钟周期应一致")
        check(hdr.filtered_dram, "默认应为 dram 过滤")

        recs = list(read_records(p))
        check(len(recs) == 3, "应读出 3 条，实为 %d" % len(recs))
        if len(recs) == 3:
            check(recs[0].tick == 1000 and recs[0].addr == shared
                  and recs[0].size == 64 and recs[0].op == OP_READ
                  and recs[0].ctx == 7 and recs[0].seq == 0,
                  "记录 0 应逐字段一致，实为 %r" % (recs[0],))
            check(recs[1].op == OP_WRITE and recs[1].addr == shared + 64,
                  "记录 1 应为写共享区下一行")
            check(recs[2].addr == vram, "记录 2 应为 VRAM 地址")

        # burst 展开的产物也要能读，且地址真的递增
        pb = os.path.join(outdir, "npu_burst.hettrace")
        if os.path.exists(pb):
            brecs = list(read_records(pb))
            check(len(brecs) == 4, "burst 应展开为 4 条")
            addrs = [r.addr for r in brecs]
            check(addrs == [shared + i * 16 for i in range(4)],
                  "burst 地址应按拍递增，实为 %r" % [hex(a) for a in addrs])
    finally:
        shutil.rmtree(d)


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        try:
            t()
        except Exception as e:  # noqa: BLE001
            global _failed
            _failed += 1
            sys.stderr.write("FAIL %s 抛出异常: %r\n" % (t.__name__, e))
    print("hettrace tools: %d 项检查, %d 项失败 (%d 个用例)"
          % (_checks, _failed, len(tests)))
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
