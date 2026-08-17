#!/usr/bin/env python3
"""从 addrmap.json 生成 C++ 与 Python 侧的地址映射常量。

addrmap.json 是唯一真值源。三个 trace 产生者（gem5 host probe、Vortex tap、
CoralNPU 设备库）以及全部下游 Python 工具都必须看到同一份映射，否则 trace 里
的地址无法互相比对，"异构" 就退化成三条不相干的 trace。

用法:
    scripts/gen_addrmap.py              # 写入生成文件
    scripts/gen_addrmap.py --check      # 只校验生成文件是否与 json 同步（CI 用）
"""

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON_PATH = os.path.join(ROOT, "addrmap.json")
H_PATH = os.path.join(ROOT, "libhettrace", "include", "hettrace", "addrmap.h")
PY_PATH = os.path.join(ROOT, "tools", "hettrace", "addrmap.py")

BANNER = "本文件由 scripts/gen_addrmap.py 从 addrmap.json 生成，请勿手改。"

LEVELS = {"post_llc": 0, "pre_cache": 1, "axi_master": 2}


def load():
    with open(JSON_PATH) as f:
        m = json.load(f)
    for r in m["regions"]:
        r["base_i"] = int(r["base"], 16)
        r["size_i"] = int(r["size"], 16)
    m["dram_window"]["base_i"] = int(m["dram_window"]["base"], 16)
    m["dram_window"]["size_i"] = int(m["dram_window"]["size"], 16)
    return m


def validate(m):
    """映射自身的健全性检查 —— 生成前必须过。"""
    errs = []
    bits = m["addr_bits"]
    limit = 1 << bits

    regs = sorted(m["regions"], key=lambda r: r["base_i"])
    for r in regs:
        end = r["base_i"] + r["size_i"]
        if end > limit:
            errs.append(
                "region %s 结束于 0x%x，超出 %d 位可寻址范围 0x%x"
                % (r["name"], end, bits, limit)
            )
    for a, b in zip(regs, regs[1:]):
        a_end = a["base_i"] + a["size_i"]
        if a_end > b["base_i"]:
            errs.append(
                "region %s [0x%x,0x%x) 与 %s [0x%x,...) 重叠"
                % (a["name"], a["base_i"], a_end, b["name"], b["base_i"])
            )

    names = [s["name"] for s in m["sources"]]
    if len(set(names)) != len(names):
        errs.append("sources 中存在重名")
    ids = [s["id"] for s in m["sources"]]
    if len(set(ids)) != len(ids):
        errs.append("sources 中存在重复 id")
    for s in m["sources"]:
        if s["level"] not in LEVELS:
            errs.append("source %s 的 level %r 未知" % (s["name"], s["level"]))

    for r in m["regions"]:
        for acc in r["accessors"]:
            if acc not in names:
                errs.append("region %s 的 accessor %r 不是已知 source" % (r["name"], acc))

    # CoralNPU 的 DDR 判定区间必须覆盖所有标为 dram 的 region，否则 NPU 会把
    # 它们误判成 mailbox 访问。
    dw_lo = m["dram_window"]["base_i"]
    dw_hi = dw_lo + m["dram_window"]["size_i"]
    for r in m["regions"]:
        if r["kind"] != "dram":
            continue
        if not (r["base_i"] >= dw_lo and r["base_i"] + r["size_i"] <= dw_hi):
            errs.append(
                "dram region %s 落在 CoralNPU DDR 窗口 [0x%x,0x%x) 之外"
                % (r["name"], dw_lo, dw_hi)
            )

    shared = [r for r in m["regions"] if len(r["accessors"]) >= 3]
    if not shared:
        errs.append("没有任何 region 被三方共同访问 —— 异构 trace 将无信息量")

    return errs


def gen_h(m):
    L = []
    a = L.append
    a("// %s" % BANNER)
    a("//")
    a("// 统一物理地址空间。三个 trace 产生者共用。")
    a("")
    a("#ifndef HETTRACE_ADDRMAP_H_")
    a("#define HETTRACE_ADDRMAP_H_")
    a("")
    a("#include <cstdint>")
    a("#include <cstddef>")
    a("")
    a("namespace hettrace {")
    a("")
    a("constexpr int      kAddrBits       = %d;" % m["addr_bits"])
    a("constexpr uint64_t kTicksPerSecond = %dull;" % m["ticks_per_second"])
    a("")
    a("// ---- 源 ID ----")
    a("enum SrcId : uint16_t {")
    for s in m["sources"]:
        a("    kSrc%s = %d," % (s["name"].capitalize(), s["id"]))
    a("    kSrcCount = %d," % len(m["sources"]))
    a("};")
    a("")
    a("// tap 挂载层级。同一条 trace 里混用不同层级是无意义的，")
    a("// 因此每个源在文件头中显式声明自己的层级。")
    a("enum TapLevel : uint8_t {")
    for name, v in sorted(LEVELS.items(), key=lambda kv: kv[1]):
        a("    kLevel%s = %d," % ("".join(p.capitalize() for p in name.split("_")), v))
    a("};")
    a("")
    a("// 各源标称时钟（用于把源内 cycle 折算成全局 tick）")
    for s in m["sources"]:
        a(
            "constexpr uint64_t kClockPeriodTicks_%s = %dull;  // %d MHz"
            % (
                s["name"],
                m["ticks_per_second"] // (s["clock_mhz"] * 1000000),
                s["clock_mhz"],
            )
        )
    a("")
    a("// ---- 区域 ----")
    for r in m["regions"]:
        a("// %s: %s" % (r["name"], r.get("note", "").replace("\n", " ")))
        a("constexpr uint64_t k%sBase = 0x%xull;" % (camel(r["name"]), r["base_i"]))
        a("constexpr uint64_t k%sSize = 0x%xull;" % (camel(r["name"]), r["size_i"]))
        for sub in r.get("subregions", []):
            a(
                "constexpr uint64_t k%sAddr = 0x%xull;  // %s"
                % (
                    camel(sub["name"]),
                    r["base_i"] + int(sub["offset"], 16),
                    sub.get("note", "").replace("\n", " "),
                )
            )
        a("")
    a("// CoralNPU IsDdrAddress() 判定区间")
    a("constexpr uint64_t kDramWindowBase = 0x%xull;" % m["dram_window"]["base_i"])
    a("constexpr uint64_t kDramWindowSize = 0x%xull;" % m["dram_window"]["size_i"])
    a("")
    a("struct Region {")
    a("    const char* name;")
    a("    uint64_t    base;")
    a("    uint64_t    size;")
    a("    bool        is_dram;")
    a("};")
    a("")
    a("constexpr Region kRegions[] = {")
    for r in m["regions"]:
        a(
            '    { "%s", 0x%xull, 0x%xull, %s },'
            % (r["name"], r["base_i"], r["size_i"], "true" if r["kind"] == "dram" else "false")
        )
    a("};")
    a("constexpr size_t kNumRegions = sizeof(kRegions) / sizeof(kRegions[0]);")
    a("")
    a("// 返回 addr 所属区域名，未映射返回 nullptr。线性扫描；仅用于诊断路径，")
    a("// 不要放进 per-access 热路径。")
    a("inline const char* RegionOf(uint64_t addr) {")
    a("    for (size_t i = 0; i < kNumRegions; ++i) {")
    a("        if (addr >= kRegions[i].base &&")
    a("            addr <  kRegions[i].base + kRegions[i].size) {")
    a("            return kRegions[i].name;")
    a("        }")
    a("    }")
    a("    return nullptr;")
    a("}")
    a("")
    a("inline bool IsDram(uint64_t addr) {")
    a("    return addr >= kDramWindowBase &&")
    a("           addr <  kDramWindowBase + kDramWindowSize;")
    a("}")
    a("")
    a("inline bool IsShared(uint64_t addr) {")
    a("    return addr >= kSharedBufferBase &&")
    a("           addr <  kSharedBufferBase + kSharedBufferSize;")
    a("}")
    a("")
    a("}  // namespace hettrace")
    a("")
    a("#endif  // HETTRACE_ADDRMAP_H_")
    return "\n".join(L) + "\n"


def camel(s):
    return "".join(p.capitalize() for p in s.split("_"))


def gen_py(m):
    L = []
    a = L.append
    a('"""%s' % BANNER)
    a("")
    a('统一物理地址空间 —— Python 侧镜像。"""')
    a("")
    a("ADDR_BITS = %d" % m["addr_bits"])
    a("TICKS_PER_SECOND = %d" % m["ticks_per_second"])
    a("")
    a("LEVELS = {")
    for name, v in sorted(LEVELS.items(), key=lambda kv: kv[1]):
        a('    "%s": %d,' % (name, v))
    a("}")
    a("LEVEL_NAMES = {v: k for k, v in LEVELS.items()}")
    a("")
    a("# name -> (id, level, clock_mhz, clock_period_ticks)")
    a("SOURCES = {")
    for s in m["sources"]:
        a(
            '    "%s": (%d, "%s", %d, %d),'
            % (
                s["name"],
                s["id"],
                s["level"],
                s["clock_mhz"],
                m["ticks_per_second"] // (s["clock_mhz"] * 1000000),
            )
        )
    a("}")
    a("SRC_NAME_BY_ID = {v[0]: k for k, v in SOURCES.items()}")
    a("")
    a("# name -> (base, size, kind, accessors)")
    a("REGIONS = {")
    for r in m["regions"]:
        a(
            '    "%s": (0x%X, 0x%X, "%s", %r),'
            % (r["name"], r["base_i"], r["size_i"], r["kind"], tuple(r["accessors"]))
        )
    a("}")
    a("")
    a("DRAM_WINDOW = (0x%X, 0x%X)" % (m["dram_window"]["base_i"], m["dram_window"]["size_i"]))
    a("")
    shared = [r["name"] for r in m["regions"] if len(r["accessors"]) >= 3]
    a("# 三方共享区 —— 归并工具据此判定真实共享")
    a("SHARED_REGIONS = %r" % (tuple(shared),))
    a("")
    a("")
    a("def region_of(addr):")
    a('    """返回 addr 所属区域名，未映射返回 None。"""')
    a("    for name, (base, size, _kind, _acc) in REGIONS.items():")
    a("        if base <= addr < base + size:")
    a("            return name")
    a("    return None")
    a("")
    a("")
    a("def is_dram(addr):")
    a("    base, size = DRAM_WINDOW")
    a("    return base <= addr < base + size")
    a("")
    a("")
    a("def is_shared(addr):")
    a("    for name in SHARED_REGIONS:")
    a("        base, size, _kind, _acc = REGIONS[name]")
    a("        if base <= addr < base + size:")
    a("            return True")
    a("    return False")
    a("")
    a("")
    a("def may_access(src_name, addr):")
    a('    """该源是否被允许访问此地址。用于 validate 阶段发现地址映射违约。"""')
    a("    name = region_of(addr)")
    a("    if name is None:")
    a("        return False")
    a("    return src_name in REGIONS[name][3]")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验，不写入")
    args = ap.parse_args()

    m = load()
    errs = validate(m)
    if errs:
        for e in errs:
            sys.stderr.write("addrmap.json: %s\n" % e)
        return 2

    outputs = [(H_PATH, gen_h(m)), (PY_PATH, gen_py(m))]
    stale = []
    for path, text in outputs:
        if args.check:
            existing = None
            if os.path.exists(path):
                with open(path) as f:
                    existing = f.read()
            if existing != text:
                stale.append(path)
        else:
            d = os.path.dirname(path)
            if not os.path.isdir(d):
                os.makedirs(d)
            with open(path, "w") as f:
                f.write(text)
            print("wrote %s" % os.path.relpath(path, ROOT))

    if stale:
        for p in stale:
            sys.stderr.write(
                "生成文件已过期: %s（执行 scripts/gen_addrmap.py）\n"
                % os.path.relpath(p, ROOT)
            )
        return 1
    if args.check:
        print("addrmap: 生成文件与 addrmap.json 同步")
    return 0


if __name__ == "__main__":
    sys.exit(main())
