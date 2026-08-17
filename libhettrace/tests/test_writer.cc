// libhettrace 自测。无外部依赖，g++ 直接编译运行。
//
//   make test-writer （在仓库根目录）
//   或  g++ -std=c++17 -I../include test_writer.cc -o t && ./t

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "hettrace/addrmap.h"
#include "hettrace/record.h"
#include "hettrace/writer.h"

using namespace hettrace;

static int g_failed = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        ++g_checks;                                                         \
        if (!(cond)) {                                                      \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,    \
                         msg);                                              \
            ++g_failed;                                                     \
        }                                                                   \
    } while (0)

static std::string g_dir;

static std::vector<Record> ReadBin(const std::string& path, FileHeader* out_h) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) return {};
    FileHeader h;
    if (std::fread(&h, sizeof(h), 1, f) != 1) {
        std::fclose(f);
        return {};
    }
    if (out_h != nullptr) *out_h = h;
    std::vector<Record> recs;
    Record r;
    while (std::fread(&r, sizeof(r), 1, f) == 1) recs.push_back(r);
    std::fclose(f);
    return recs;
}

// ---------------------------------------------------------------------------

static void TestDisabledWhenNoEnv() {
    unsetenv("HETTRACE_DIR");
    TraceWriter w;
    bool ok = w.Open(kSrcHost, "host", kLevelPostLlc, kClockPeriodTicks_host);
    CHECK(!ok, "HETTRACE_DIR 未设置时 Open 应返回 false");
    CHECK(!w.is_open(), "未设置时应保持关闭");
    // 关闭状态下 Emit 必须是安全的 no-op
    w.Emit(0, kSharedBufferBase, 64, kRead, 0);
    CHECK(w.stats().emitted == 0, "关闭状态不应产生记录");
}

static void TestHeaderAndRoundTrip() {
    setenv("HETTRACE_DIR", g_dir.c_str(), 1);
    setenv("HETTRACE_FORMAT", "bin", 1);
    unsetenv("HETTRACE_FILTER");

    {
        TraceWriter w;
        CHECK(w.Open(kSrcVortex, "vortex", kLevelPostLlc,
                     kClockPeriodTicks_vortex),
              "Open 应成功");
        w.Emit(1000, kSharedBufferBase, 64, kRead, 7);
        w.Emit(2000, kSharedBufferBase + 64, 64, kWrite, 7);
        w.Emit(3000, kVortexVramBase, 32, kRead, 9);
    }  // 析构应 Flush + 写 meta

    FileHeader h;
    std::vector<Record> recs = ReadBin(g_dir + "/vortex.hettrace", &h);

    CHECK(std::memcmp(h.magic, kMagic, 8) == 0, "magic 应匹配");
    CHECK(h.version == kFormatVersion, "version 应匹配");
    CHECK(h.record_size == sizeof(Record), "record_size 应为 32");
    CHECK(h.ticks_per_second == kTicksPerSecond, "ticks_per_second 应匹配");
    CHECK(h.clock_period_ticks == kClockPeriodTicks_vortex,
          "clock_period_ticks 应匹配");
    CHECK(h.src_id == kSrcVortex, "src_id 应匹配");
    CHECK(h.level == kLevelPostLlc, "level 应匹配");
    CHECK((h.flags & kHdrFilteredDram) != 0, "默认应为 dram 过滤");
    CHECK(std::strcmp(h.name, "vortex") == 0, "name 应匹配");

    CHECK(recs.size() == 3, "应有 3 条记录");
    if (recs.size() == 3) {
        CHECK(recs[0].tick == 1000 && recs[0].addr == kSharedBufferBase &&
                  recs[0].size == 64 && recs[0].op == kRead &&
                  recs[0].ctx == 7 && recs[0].seq == 0,
              "记录 0 字段应往返一致");
        CHECK(recs[1].op == kWrite && recs[1].seq == 1, "记录 1 应为写且 seq=1");
        CHECK(recs[2].addr == kVortexVramBase && recs[2].seq == 2,
              "记录 2 应往返一致");
        CHECK(recs[0].src_id == kSrcVortex, "src_id 应写入每条记录");
    }
}

static void TestDramFilter() {
    setenv("HETTRACE_DIR", g_dir.c_str(), 1);
    setenv("HETTRACE_FORMAT", "bin", 1);
    unsetenv("HETTRACE_FILTER");  // 默认 dram

    TraceWriter w;
    w.Open(kSrcCoralnpu, "npu_filt", kLevelAxiMaster,
           kClockPeriodTicks_coralnpu);
    w.Emit(10, kSharedBufferBase, 16, kRead, 0);   // DRAM 窗口内 -> 保留
    w.Emit(20, kNpuTcmAddr, 4, kRead, 0);          // TCM -> 过滤
    w.Emit(30, kVortexCpBase, 4, kWrite, 0);       // CP 寄存器 -> 过滤
    w.Emit(40, kNpuMailboxBase, 16, kWrite, 0);    // mailbox 在 DRAM 窗口外 -> 过滤
    w.Emit(50, kNpuWorkBase, 16, kWrite, 0);       // DRAM 窗口内 -> 保留
    w.Close();

    CHECK(w.stats().emitted == 2, "dram 过滤后应剩 2 条");
    CHECK(w.stats().filtered == 3, "应过滤掉 3 条");
    CHECK(w.stats().unmapped == 0, "全部地址均应已映射");
}

static void TestFilterAll() {
    setenv("HETTRACE_DIR", g_dir.c_str(), 1);
    setenv("HETTRACE_FILTER", "all", 1);

    TraceWriter w;
    w.Open(kSrcCoralnpu, "npu_all", kLevelAxiMaster, kClockPeriodTicks_coralnpu);
    w.Emit(10, kSharedBufferBase, 16, kRead, 0);
    w.Emit(20, kNpuTcmAddr, 4, kRead, 0);
    w.Emit(30, 0xdeadbeef, 4, kWrite, 0);  // 未映射
    w.Close();
    unsetenv("HETTRACE_FILTER");

    CHECK(w.stats().emitted == 3, "filter=all 应全部保留");
    CHECK(w.stats().filtered == 0, "filter=all 不应过滤");
    CHECK(w.stats().unmapped == 1, "应计出 1 条未映射");

    FileHeader h;
    std::vector<Record> recs = ReadBin(g_dir + "/npu_all.hettrace", &h);
    CHECK((h.flags & kHdrFilteredDram) == 0, "filter=all 时头部不应置过滤位");
    CHECK(recs.size() == 3, "应写出 3 条");
    if (recs.size() == 3) {
        CHECK((recs[2].flags & kFlagUnmapped) != 0,
              "未映射记录应带 kFlagUnmapped");
    }
}

static void TestNonMonotonicDetected() {
    setenv("HETTRACE_DIR", g_dir.c_str(), 1);
    TraceWriter w;
    w.Open(kSrcHost, "host_mono", kLevelPostLlc, kClockPeriodTicks_host);
    w.Emit(100, kSharedBufferBase, 8, kRead, 0);
    w.Emit(90, kSharedBufferBase, 8, kRead, 0);   // 回退
    w.Emit(200, kSharedBufferBase, 8, kRead, 0);
    w.Close();
    CHECK(w.stats().non_monotonic == 1, "应检出 1 次 tick 回退");
    CHECK(w.stats().first_tick == 100, "first_tick 应为 100");
    CHECK(w.stats().last_tick == 200, "last_tick 应为 200");
}

// AXI burst 展开是最容易出错的一处：hw_primitives.h 里每拍回调都带同一个
// 首地址，不展开就会得到 N 条相同地址的记录。
static void TestBurstExpansion() {
    setenv("HETTRACE_DIR", g_dir.c_str(), 1);
    TraceWriter w;
    w.Open(kSrcCoralnpu, "npu_burst", kLevelAxiMaster,
           kClockPeriodTicks_coralnpu);
    // axi_len=3 => 4 拍; axi_size=4 => 每拍 16 字节
    w.EmitBurst(500, kSharedBufferBase, /*axi_len=*/3, /*axi_size=*/4, kRead, 2);
    w.Close();

    CHECK(w.stats().emitted == 4, "len=3 应展开为 4 拍");
    CHECK(w.stats().bytes == 64, "4 拍 × 16 字节 = 64");

    std::vector<Record> recs = ReadBin(g_dir + "/npu_burst.hettrace", nullptr);
    CHECK(recs.size() == 4, "应写出 4 条");
    if (recs.size() == 4) {
        for (uint32_t i = 0; i < 4; ++i) {
            CHECK(recs[i].addr == kSharedBufferBase + i * 16,
                  "burst 地址应按拍递增");
            CHECK(recs[i].size == 16, "每拍 16 字节");
        }
        CHECK((recs[0].flags & kFlagBurstBeat) == 0, "首拍不应带 BurstBeat");
        CHECK((recs[1].flags & kFlagBurstBeat) != 0, "非首拍应带 BurstBeat");
    }
}

static void TestTextFormat() {
    setenv("HETTRACE_DIR", g_dir.c_str(), 1);
    setenv("HETTRACE_FORMAT", "text", 1);
    {
        TraceWriter w;
        w.Open(kSrcHost, "host_txt", kLevelPostLlc, kClockPeriodTicks_host);
        w.Emit(4242, kSharedBufferBase + 0x100, 64, kWrite, 3);
    }
    setenv("HETTRACE_FORMAT", "bin", 1);

    FILE* f = std::fopen((g_dir + "/host_txt.hettrace.txt").c_str(), "r");
    CHECK(f != nullptr, "文本 trace 文件应存在");
    if (f == nullptr) return;
    char line[512];
    std::string body;
    int ncomment = 0;
    while (std::fgets(line, sizeof(line), f) != nullptr) {
        if (line[0] == '#') {
            ++ncomment;
            continue;
        }
        body = line;
    }
    std::fclose(f);
    CHECK(ncomment == 5, "文本头应为 5 行注释");
    CHECK(body.find("4242") != std::string::npos, "应含 tick");
    CHECK(body.find(" W ") != std::string::npos, "写应记为 W");
    CHECK(body.find("0x90000100") != std::string::npos, "应含十六进制地址");
}

static void TestMetaSidecar() {
    setenv("HETTRACE_DIR", g_dir.c_str(), 1);
    setenv("HETTRACE_FORMAT", "bin", 1);
    {
        TraceWriter w;
        w.Open(kSrcVortex, "vortex_meta", kLevelPostLlc,
               kClockPeriodTicks_vortex);
        for (int i = 0; i < 10; ++i) {
            w.Emit(1000 + i, kSharedBufferBase + i * 64, 64, kRead, 1);
        }
    }
    FILE* f = std::fopen((g_dir + "/vortex_meta.hettrace.meta.json").c_str(), "r");
    CHECK(f != nullptr, "meta 侧车文件应存在");
    if (f == nullptr) return;
    std::string all;
    char buf[256];
    while (std::fgets(buf, sizeof(buf), f) != nullptr) all += buf;
    std::fclose(f);
    CHECK(all.find("\"emitted\": 10") != std::string::npos,
          "meta 应记录 emitted=10");
    CHECK(all.find("\"bytes\": 640") != std::string::npos,
          "meta 应记录 bytes=640");
    CHECK(all.find("\"name\": \"vortex_meta\"") != std::string::npos,
          "meta 应含源名");
}

// 缓冲区必须能正确跨越多次 flush —— 这是长跑 trace 的常见丢数据点。
static void TestFlushAcrossBuffer() {
    setenv("HETTRACE_DIR", g_dir.c_str(), 1);
    setenv("HETTRACE_BUFSZ", "8", 1);
    const int N = 100;
    {
        TraceWriter w;
        w.Open(kSrcHost, "host_flush", kLevelPostLlc, kClockPeriodTicks_host);
        for (int i = 0; i < N; ++i) {
            w.Emit(i, kSharedBufferBase + i * 8, 8, kRead, 0);
        }
    }
    unsetenv("HETTRACE_BUFSZ");

    std::vector<Record> recs = ReadBin(g_dir + "/host_flush.hettrace", nullptr);
    CHECK(recs.size() == static_cast<size_t>(N), "跨 flush 不应丢记录");
    bool seq_ok = true;
    for (size_t i = 0; i < recs.size(); ++i) {
        if (recs[i].seq != i) seq_ok = false;
    }
    CHECK(seq_ok, "seq 应连续无洞");
}

static void TestAddrMapSanity() {
    // shared_buffer 必须在 DRAM 窗口内且三方可达，否则整个工程无意义。
    CHECK(IsDram(kSharedBufferBase), "shared_buffer 应在 DRAM 窗口内");
    CHECK(IsShared(kSharedBufferBase), "IsShared 应识别 shared_buffer");
    CHECK(!IsShared(kNpuWorkBase), "npu_work 不应被判为共享");
    // CoralNPU 只有 32 位地址；所有 DRAM 区域必须在 4GiB 以内。
    for (size_t i = 0; i < kNumRegions; ++i) {
        if (!kRegions[i].is_dram) continue;
        CHECK(kRegions[i].base + kRegions[i].size <= (1ull << kAddrBits),
              "DRAM 区域必须落在 CoralNPU 的 32 位可寻址范围内");
    }
    CHECK(std::strcmp(RegionOf(kSharedBufferBase), "shared_buffer") == 0,
          "RegionOf 应返回 shared_buffer");
    CHECK(RegionOf(0xdeadbeef) == nullptr, "未映射地址应返回 nullptr");
}

int main() {
    // 外部指定 HETTRACE_DIR 时用它 —— tools/tests 的互操作用例靠这个拿到产物，
    // 交叉验证 Python 侧能否原样读出 C++ 写的记录。
    char tmpl[] = "/tmp/hettrace_test_XXXXXX";
    const char* env_dir = std::getenv("HETTRACE_DIR");
    if (env_dir != nullptr && env_dir[0] != '\0') {
        g_dir = env_dir;
    } else {
        const char* d = mkdtemp(tmpl);
        if (d == nullptr) {
            std::fprintf(stderr, "mkdtemp 失败\n");
            return 1;
        }
        g_dir = d;
    }

    TestDisabledWhenNoEnv();
    TestHeaderAndRoundTrip();
    TestDramFilter();
    TestFilterAll();
    TestNonMonotonicDetected();
    TestBurstExpansion();
    TestTextFormat();
    TestMetaSidecar();
    TestFlushAcrossBuffer();
    TestAddrMapSanity();

    std::printf("libhettrace: %d 项检查, %d 项失败\n", g_checks, g_failed);
    if (g_failed == 0) {
        std::printf("产物保留在 %s\n", g_dir.c_str());
    }
    return g_failed == 0 ? 0 : 1;
}
