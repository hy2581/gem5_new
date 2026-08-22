IVERILOG ?= iverilog
VVP      ?= vvp
BUILD    := build
SIMV     := $(BUILD)/storage_chain_simv

RTL := \
  rtl/axi_to_memreq.sv \
  rtl/rv_delay.sv \
  rtl/ucie_link_model.sv \
  rtl/mc_model.sv \
  rtl/dfi_memory_model.sv \
  rtl/storage_chain_top.sv
TB := tb/tb_storage_chain.sv

.PHONY: all test clean

all: test

test: $(SIMV)
	$(VVP) $(SIMV)

$(SIMV): $(RTL) $(TB) | $(BUILD)
	$(IVERILOG) -g2012 -Wall -Wimplicit -s tb_storage_chain -o $@ $(RTL) $(TB)

$(BUILD):
	mkdir -p $@

clean:
	rm -f $(SIMV)
	-@rmdir $(BUILD) 2>/dev/null || true
