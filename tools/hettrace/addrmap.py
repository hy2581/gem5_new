"""本文件由 scripts/gen_addrmap.py 从 addrmap.json 生成，请勿手改。

统一物理地址空间 —— Python 侧镜像。"""

ADDR_BITS = 32
TICKS_PER_SECOND = 1000000000000

LEVELS = {
    "post_llc": 0,
    "pre_cache": 1,
    "axi_master": 2,
}
LEVEL_NAMES = {v: k for k, v in LEVELS.items()}

# name -> (id, level, clock_mhz, clock_period_ticks)
SOURCES = {
    "host": (0, "post_llc", 2000, 500),
    "vortex": (1, "post_llc", 1000, 1000),
    "coralnpu": (2, "axi_master", 500, 2000),
}
SRC_NAME_BY_ID = {v[0]: k for k, v in SOURCES.items()}

# name -> (base, size, kind, accessors)
REGIONS = {
    "boot_rom": (0x0, 0x10000000, "rom", ('host',)),
    "npu_slave": (0x10000000, 0x10000000, "mmio", ('host',)),
    "vortex_cp": (0x20000000, 0x200, "mmio", ('host',)),
    "npu_pio": (0x30000000, 0x1000, "mmio", ('host',)),
    "host_heap": (0x80000000, 0x10000000, "dram", ('host',)),
    "shared_buffer": (0x90000000, 0x10000000, "dram", ('host', 'vortex', 'coralnpu')),
    "vortex_vram": (0xA0000000, 0x10000000, "dram", ('host', 'vortex')),
    "npu_work": (0xB0000000, 0x10000000, "dram", ('host', 'coralnpu')),
    "npu_mailbox": (0xC0000000, 0x10, "mmio", ('host', 'coralnpu')),
}

DRAM_WINDOW = (0x80000000, 0x40000000)

# 三方共享区 —— 归并工具据此判定真实共享
SHARED_REGIONS = ('shared_buffer',)


def region_of(addr):
    """返回 addr 所属区域名，未映射返回 None。"""
    for name, (base, size, _kind, _acc) in REGIONS.items():
        if base <= addr < base + size:
            return name
    return None


def is_dram(addr):
    base, size = DRAM_WINDOW
    return base <= addr < base + size


def is_shared(addr):
    for name in SHARED_REGIONS:
        base, size, _kind, _acc = REGIONS[name]
        if base <= addr < base + size:
            return True
    return False


def may_access(src_name, addr):
    """该源是否被允许访问此地址。用于 validate 阶段发现地址映射违约。"""
    name = region_of(addr)
    if name is None:
        return False
    return src_name in REGIONS[name][3]
