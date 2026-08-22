`timescale 1ns/1ps

module tb_storage_chain;
    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 64;
    localparam integer ID_WIDTH   = 4;
    localparam integer USER_WIDTH = 2;
    localparam [ADDR_WIDTH-1:0] MEM_BASE = 32'h9000_0000;

    localparam [USER_WIDTH-1:0] SRC_CPU = 2'd0;
    localparam [USER_WIDTH-1:0] SRC_NPU = 2'd1;
    localparam [USER_WIDTH-1:0] SRC_GPU = 2'd2;

    reg clk;
    reg rst_n;

    reg  [ID_WIDTH-1:0]     awid;
    reg  [ADDR_WIDTH-1:0]   awaddr;
    reg  [7:0]              awlen;
    reg  [2:0]              awsize;
    reg  [1:0]              awburst;
    reg  [USER_WIDTH-1:0]   awuser;
    reg                     awvalid;
    wire                    awready;

    reg  [DATA_WIDTH-1:0]   wdata;
    reg  [DATA_WIDTH/8-1:0] wstrb;
    reg                     wlast;
    reg                     wvalid;
    wire                    wready;

    wire [ID_WIDTH-1:0]     bid;
    wire [1:0]              bresp;
    wire                    bvalid;
    reg                     bready;

    reg  [ID_WIDTH-1:0]     arid;
    reg  [ADDR_WIDTH-1:0]   araddr;
    reg  [7:0]              arlen;
    reg  [2:0]              arsize;
    reg  [1:0]              arburst;
    reg  [USER_WIDTH-1:0]   aruser;
    reg                     arvalid;
    wire                    arready;

    wire [ID_WIDTH-1:0]     rid;
    wire [DATA_WIDTH-1:0]   rdata;
    wire [1:0]              rresp;
    wire                    rlast;
    wire                    rvalid;
    reg                     rready;

    wire [31:0] axi_beat_count;
    wire [31:0] ucie_request_count;
    wire [31:0] ucie_response_count;
    wire [31:0] mc_command_count;
    wire [31:0] memory_read_count;
    wire [31:0] memory_write_count;

    storage_chain_top #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH(ID_WIDTH), .USER_WIDTH(USER_WIDTH),
        .LINK_LATENCY(3), .MC_LATENCY(2), .DFI_LATENCY(4),
        .MEM_BASE(MEM_BASE), .MEM_BYTES(4096)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awburst(awburst),
        .s_axi_awuser(awuser), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(arsize), .s_axi_arburst(arburst),
        .s_axi_aruser(aruser), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .axi_beat_count(axi_beat_count),
        .ucie_request_count(ucie_request_count),
        .ucie_response_count(ucie_response_count),
        .mc_command_count(mc_command_count),
        .memory_read_count(memory_read_count),
        .memory_write_count(memory_write_count)
    );

    always #5 clk = ~clk;

    task automatic send_aw;
        input [USER_WIDTH-1:0] src;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input integer beats;
        begin
            @(negedge clk);
            awuser  = src;
            awid    = id;
            awaddr  = addr;
            awlen   = beats - 1;
            awsize  = 3;      // 8 bytes on a 64-bit bus
            awburst = 2'b01;  // INCR
            awvalid = 1'b1;
            @(posedge clk);
            while (!awready)
                @(posedge clk);
            @(negedge clk);
            awvalid = 1'b0;
        end
    endtask

    task automatic send_w;
        input [DATA_WIDTH-1:0] data;
        input [DATA_WIDTH/8-1:0] strb;
        input last;
        begin
            @(negedge clk);
            wdata  = data;
            wstrb  = strb;
            wlast  = last;
            wvalid = 1'b1;
            @(posedge clk);
            while (!wready)
                @(posedge clk);
            @(negedge clk);
            wvalid = 1'b0;
            wlast  = 1'b0;
        end
    endtask

    task automatic wait_b;
        input [ID_WIDTH-1:0] expected_id;
        begin
            while (!bvalid)
                @(posedge clk);
            if (bid !== expected_id || bresp !== 2'b00)
                $fatal(1, "bad AXI B response: id=%0d resp=%0b", bid, bresp);
            @(negedge clk);
            bready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    task automatic axi_write_burst;
        input [USER_WIDTH-1:0] src;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input integer beats;
        input [DATA_WIDTH-1:0] seed;
        integer beat;
        begin
            $display("[XPU->AXI] src=%0d WRITE addr=0x%08x beats=%0d", src, addr, beats);
            send_aw(src, id, addr, beats);
            for (beat = 0; beat < beats; beat = beat + 1)
                send_w(seed + beat, {DATA_WIDTH/8{1'b1}}, beat == beats - 1);
            wait_b(id);
        end
    endtask

    task automatic axi_write_one;
        input [USER_WIDTH-1:0] src;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        input [DATA_WIDTH/8-1:0] strb;
        begin
            $display("[XPU->AXI] src=%0d WRITE addr=0x%08x strb=0x%02x", src, addr, strb);
            send_aw(src, id, addr, 1);
            send_w(data, strb, 1'b1);
            wait_b(id);
        end
    endtask

    task automatic send_ar;
        input [USER_WIDTH-1:0] src;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input integer beats;
        begin
            @(negedge clk);
            aruser  = src;
            arid    = id;
            araddr  = addr;
            arlen   = beats - 1;
            arsize  = 3;
            arburst = 2'b01;
            arvalid = 1'b1;
            @(posedge clk);
            while (!arready)
                @(posedge clk);
            @(negedge clk);
            arvalid = 1'b0;
        end
    endtask

    task automatic axi_read_check;
        input [USER_WIDTH-1:0] src;
        input [ID_WIDTH-1:0] id;
        input [ADDR_WIDTH-1:0] addr;
        input integer beats;
        input [DATA_WIDTH-1:0] seed;
        integer beat;
        reg [DATA_WIDTH-1:0] held_data;
        begin
            $display("[XPU->AXI] src=%0d READ  addr=0x%08x beats=%0d", src, addr, beats);
            send_ar(src, id, addr, beats);
            for (beat = 0; beat < beats; beat = beat + 1) begin
                while (!rvalid)
                    @(posedge clk);
                if (rid !== id || rresp !== 2'b00)
                    $fatal(1, "bad AXI R response: id=%0d resp=%0b", rid, rresp);
                if (rdata !== seed + beat)
                    $fatal(1, "read mismatch beat=%0d got=0x%016x expected=0x%016x",
                           beat, rdata, seed + beat);
                if (rlast !== (beat == beats - 1))
                    $fatal(1, "AXI RLAST mismatch on beat %0d", beat);

                // Deliberately apply read backpressure on the first beat and
                // require R payload to remain stable while RREADY is low.
                if (beat == 0) begin
                    held_data = rdata;
                    repeat (2) begin
                        @(posedge clk);
                        if (!rvalid || rdata !== held_data)
                            $fatal(1, "AXI R channel changed under backpressure");
                    end
                end

                @(negedge clk);
                rready = 1'b1;
                @(posedge clk);
                @(negedge clk);
                rready = 1'b0;
            end
        end
    endtask

    initial begin
        clk     = 1'b0;
        rst_n   = 1'b0;
        awid    = 0;
        awaddr  = 0;
        awlen   = 0;
        awsize  = 0;
        awburst = 0;
        awuser  = 0;
        awvalid = 0;
        wdata   = 0;
        wstrb   = 0;
        wlast   = 0;
        wvalid  = 0;
        bready  = 0;
        arid    = 0;
        araddr  = 0;
        arlen   = 0;
        arsize  = 0;
        arburst = 0;
        aruser  = 0;
        arvalid = 0;
        rready  = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // CPU produces data; NPU consumes it through the complete chain.
        axi_write_burst(SRC_CPU, 4'h1, MEM_BASE + 32'h100, 4,
                        64'hc000_0000_0000_0100);
        axi_read_check(SRC_NPU, 4'h2, MEM_BASE + 32'h100, 4,
                       64'hc000_0000_0000_0100);

        // GPU produces a second burst; CPU reads it back.
        axi_write_burst(SRC_GPU, 4'h3, MEM_BASE + 32'h200, 2,
                        64'h6000_0000_0000_0200);
        axi_read_check(SRC_CPU, 4'h4, MEM_BASE + 32'h200, 2,
                       64'h6000_0000_0000_0200);

        // Byte strobes: GPU replaces only the low 32 bits of a CPU word.
        axi_write_one(SRC_CPU, 4'h5, MEM_BASE + 32'h300,
                      64'h1122_3344_5566_7788, 8'hff);
        axi_write_one(SRC_GPU, 4'h6, MEM_BASE + 32'h300,
                      64'hdead_beef_cafe_babe, 8'h0f);
        axi_read_check(SRC_NPU, 4'h7, MEM_BASE + 32'h300, 1,
                       64'h1122_3344_cafe_babe);

        repeat (5) @(posedge clk);
        if (axi_beat_count !== 15 || ucie_request_count !== 15 ||
            ucie_response_count !== 15 || mc_command_count !== 15)
            $fatal(1, "stage count mismatch AXI=%0d UCIeReq=%0d UCIeRsp=%0d MC=%0d",
                   axi_beat_count, ucie_request_count,
                   ucie_response_count, mc_command_count);
        if (memory_write_count !== 8 || memory_read_count !== 7)
            $fatal(1, "memory count mismatch writes=%0d reads=%0d",
                   memory_write_count, memory_read_count);

        $display("CHAIN PASS: AXI beats=%0d, UCIe req/rsp=%0d/%0d, MC cmds=%0d, DFI writes/reads=%0d/%0d",
                 axi_beat_count, ucie_request_count, ucie_response_count,
                 mc_command_count, memory_write_count, memory_read_count);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "storage-chain simulation timeout");
    end
endmodule
