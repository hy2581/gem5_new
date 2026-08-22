# 顶层 Makefile —— 只做本仓库自己的事。
#
# 三个仿真器的构建**不在**这里：gem5 用 SCons、CoralNPU 用 bazel、Vortex 用它自己
# 的 Makefile，各有自己的配置与产物目录，包一层只会把错误信息埋掉一层。要构建它们
# 见 docs/04-integration.md。
#
# 这里能做的是"不需要任何仿真器就能验的部分"：生成物是否与 addrmap.json 同步、两套
# 自测是否过。CI 应该先跑 `make check`，因为它快且能挡掉最隐晦的一类错误。

PROJ    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
PYTHON  ?= python3
CXX     ?= g++
BUILD   := build

.PHONY: all check check-addrmap addrmap test test-tools test-writer \
        test-storage-chain install install-gem5 install-vortex \
        install-coralnpu clean help

all: check

help:
	@echo "make check          - addrmap 同步性 + 两套自测（不需要仿真器）"
	@echo "make addrmap        - 从 addrmap.json 重新生成 C++/Python 侧的地址表"
	@echo "make check-addrmap  - 只校验生成物是否过期，不写文件"
	@echo "make test           - test-tools + test-writer"
	@echo "make test-storage-chain - AXI -> UCIe -> MC -> DFI -> memory 端到端仿真"
	@echo "make install        - 把本项目装进三棵树（需要 GEM5_HOME 等环境变量）"
	@echo "make clean          - 删掉本项目在 $(BUILD)/ 下的产物（不动别人的东西）"
	@echo ""
	@echo "仿真器的构建与端到端测试见 docs/04-integration.md"

check: check-addrmap test

# ---- addrmap ---------------------------------------------------------------
# 生成物过期是本仓库里最隐晦的一类错误：C++ 侧和 Python 侧会对"哪个地址属于哪个
# 区域"给出不同答案，而两边都不报错。所以 check 的第一步就是它。
addrmap:
	$(PYTHON) scripts/gen_addrmap.py

check-addrmap:
	@$(PYTHON) scripts/gen_addrmap.py --check

# ---- 自测 ------------------------------------------------------------------
test: test-tools test-writer

test-storage-chain:
	$(MAKE) -C storage_chain test

# 不用 pytest：少一个依赖，在只有 gem5 自带 python 的机器上也能跑。脚本自己数
# 检查项、自己定退出码。
test-tools:
	@PYTHONPATH=$(PROJ)/tools $(PYTHON) tools/tests/test_tools.py

test-writer: $(BUILD)/test_writer
	@$(BUILD)/test_writer

$(BUILD)/test_writer: libhettrace/tests/test_writer.cc \
                      $(wildcard libhettrace/include/hettrace/*.h) | $(BUILD)
	$(CXX) -std=c++17 -Wall -Wextra -Ilibhettrace/include -o $@ $<

$(BUILD):
	mkdir -p $@

# ---- 安装 ------------------------------------------------------------------
# 三个安装脚本各自幂等、各自支持 --revert。这里只是并列调用，不加逻辑 —— 脚本里
# 的环境变量校验和错误信息比 Makefile 能给的清楚得多。
install: install-gem5 install-vortex install-coralnpu

install-gem5:
	./gem5int/install.sh

# Vortex 要跑两个脚本且顺序不能反：先给 Vortex 树打补丁，再把打过补丁的 gem5 侧
# 源码装进 gem5（那份源码的 source-of-truth 在 Vortex 树里）。理由见
# docs/04-integration.md。
install-vortex:
	./vortexint/install.sh
	@echo "接着跑（顺序不能反）: GEM5_HOME=\$$GEM5_HOME \$$VORTEX_HOME/sim/simx/gem5/install.sh"

install-coralnpu:
	./coralnpuint/install.sh

# 逐个删自己的产物，不是 `rm -rf $(BUILD)`。$(BUILD) 是 .gitignore 里的目录，别人
# （比如在项目里顺手跑一次 gem5 的 scons）完全可能往里放几个 G 的中间产物，一句
# rm -rf 会把那些一起端掉，而 make clean 是所有人都会随手敲的命令。
# 加了新产物就在这里加一行；rmdir 不带 -p、失败也不算错，目录非空就说明里面还有
# 不属于我们的东西，那就该留着。
clean:
	rm -f $(BUILD)/test_writer
	$(MAKE) -C storage_chain clean
	-@rmdir $(BUILD) 2>/dev/null || true
