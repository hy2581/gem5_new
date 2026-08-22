`timescale 1ns/1ps

// End-to-end correctness demonstrator:
//
//   XPU AXI -> transaction packet -> UCIe-like delay -> MC
//           -> simplified DFI -> byte-addressed memory model
//
// The AXI slave pins are the replacement boundary for a real CPU/NPU/GPU
// initiator or an AXI interconnect that combines the three initiators.

module storage_chain_top #(
    parameter integer ADDR_WIDTH       = 32,
    parameter integer DATA_WIDTH       = 64,
    parameter integer ID_WIDTH         = 4,
    parameter integer USER_WIDTH       = 2,
    parameter integer TAG_WIDTH        = 16,
    parameter integer LINK_LATENCY     = 3,
    parameter integer MC_LATENCY       = 2,
    parameter integer DFI_LATENCY      = 4,
    parameter [ADDR_WIDTH-1:0] MEM_BASE = 32'h9000_0000,
    parameter integer MEM_BYTES        = 4096
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire [ID_WIDTH-1:0]       s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [7:0]                s_axi_awlen,
    input  wire [2:0]                s_axi_awsize,
    input  wire [1:0]                s_axi_awburst,
    input  wire [USER_WIDTH-1:0]     s_axi_awuser,
    input  wire                      s_axi_awvalid,
    output wire                      s_axi_awready,

    input  wire [DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]   s_axi_wstrb,
    input  wire                      s_axi_wlast,
    input  wire                      s_axi_wvalid,
    output wire                      s_axi_wready,

    output wire [ID_WIDTH-1:0]       s_axi_bid,
    output wire [1:0]                s_axi_bresp,
    output wire                      s_axi_bvalid,
    input  wire                      s_axi_bready,

    input  wire [ID_WIDTH-1:0]       s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire [7:0]                s_axi_arlen,
    input  wire [2:0]                s_axi_arsize,
    input  wire [1:0]                s_axi_arburst,
    input  wire [USER_WIDTH-1:0]     s_axi_aruser,
    input  wire                      s_axi_arvalid,
    output wire                      s_axi_arready,

    output wire [ID_WIDTH-1:0]       s_axi_rid,
    output wire [DATA_WIDTH-1:0]     s_axi_rdata,
    output wire [1:0]                s_axi_rresp,
    output wire                      s_axi_rlast,
    output wire                      s_axi_rvalid,
    input  wire                      s_axi_rready,

    output wire [31:0]               axi_beat_count,
    output wire [31:0]               ucie_request_count,
    output wire [31:0]               ucie_response_count,
    output wire [31:0]               mc_command_count,
    output wire [31:0]               memory_read_count,
    output wire [31:0]               memory_write_count
);
    wire                    near_req_valid;
    wire                    near_req_ready;
    wire [USER_WIDTH-1:0]   near_req_src;
    wire [ID_WIDTH-1:0]     near_req_axi_id;
    wire [TAG_WIDTH-1:0]    near_req_tag;
    wire                    near_req_write;
    wire [ADDR_WIDTH-1:0]   near_req_addr;
    wire [DATA_WIDTH-1:0]   near_req_wdata;
    wire [DATA_WIDTH/8-1:0] near_req_wstrb;

    wire                    near_rsp_valid;
    wire                    near_rsp_ready;
    wire [USER_WIDTH-1:0]   near_rsp_src;
    wire [ID_WIDTH-1:0]     near_rsp_axi_id;
    wire [TAG_WIDTH-1:0]    near_rsp_tag;
    wire                    near_rsp_write;
    wire [DATA_WIDTH-1:0]   near_rsp_rdata;
    wire [1:0]              near_rsp_resp;

    wire                    far_req_valid;
    wire                    far_req_ready;
    wire [USER_WIDTH-1:0]   far_req_src;
    wire [ID_WIDTH-1:0]     far_req_axi_id;
    wire [TAG_WIDTH-1:0]    far_req_tag;
    wire                    far_req_write;
    wire [ADDR_WIDTH-1:0]   far_req_addr;
    wire [DATA_WIDTH-1:0]   far_req_wdata;
    wire [DATA_WIDTH/8-1:0] far_req_wstrb;

    wire                    far_rsp_valid;
    wire                    far_rsp_ready;
    wire [USER_WIDTH-1:0]   far_rsp_src;
    wire [ID_WIDTH-1:0]     far_rsp_axi_id;
    wire [TAG_WIDTH-1:0]    far_rsp_tag;
    wire                    far_rsp_write;
    wire [DATA_WIDTH-1:0]   far_rsp_rdata;
    wire [1:0]              far_rsp_resp;

    wire                    dfi_cmd_valid;
    wire                    dfi_cmd_ready;
    wire                    dfi_cmd_write;
    wire [ADDR_WIDTH-1:0]   dfi_cmd_addr;
    wire [DATA_WIDTH-1:0]   dfi_cmd_wdata;
    wire [DATA_WIDTH/8-1:0] dfi_cmd_wstrb;
    wire                    dfi_rsp_valid;
    wire                    dfi_rsp_ready;
    wire [DATA_WIDTH-1:0]   dfi_rsp_rdata;
    wire [1:0]              dfi_rsp_resp;

    axi_to_memreq #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH(ID_WIDTH), .USER_WIDTH(USER_WIDTH), .TAG_WIDTH(TAG_WIDTH)
    ) axi_frontend (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen), .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst), .s_axi_awuser(s_axi_awuser),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen), .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst), .s_axi_aruser(s_axi_aruser),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp), .s_axi_rlast(s_axi_rlast),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .req_valid(near_req_valid), .req_ready(near_req_ready),
        .req_src(near_req_src), .req_axi_id(near_req_axi_id),
        .req_tag(near_req_tag), .req_write(near_req_write),
        .req_addr(near_req_addr), .req_wdata(near_req_wdata),
        .req_wstrb(near_req_wstrb),
        .rsp_valid(near_rsp_valid), .rsp_ready(near_rsp_ready),
        .rsp_src(near_rsp_src), .rsp_axi_id(near_rsp_axi_id),
        .rsp_tag(near_rsp_tag), .rsp_write(near_rsp_write),
        .rsp_rdata(near_rsp_rdata), .rsp_resp(near_rsp_resp),
        .accepted_beat_count(axi_beat_count)
    );

    ucie_link_model #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH(ID_WIDTH), .USER_WIDTH(USER_WIDTH), .TAG_WIDTH(TAG_WIDTH),
        .LINK_LATENCY(LINK_LATENCY)
    ) ucie_link (
        .clk(clk), .rst_n(rst_n),
        .in_req_valid(near_req_valid), .in_req_ready(near_req_ready),
        .in_req_src(near_req_src), .in_req_axi_id(near_req_axi_id),
        .in_req_tag(near_req_tag), .in_req_write(near_req_write),
        .in_req_addr(near_req_addr), .in_req_wdata(near_req_wdata),
        .in_req_wstrb(near_req_wstrb),
        .out_req_valid(far_req_valid), .out_req_ready(far_req_ready),
        .out_req_src(far_req_src), .out_req_axi_id(far_req_axi_id),
        .out_req_tag(far_req_tag), .out_req_write(far_req_write),
        .out_req_addr(far_req_addr), .out_req_wdata(far_req_wdata),
        .out_req_wstrb(far_req_wstrb),
        .in_rsp_valid(far_rsp_valid), .in_rsp_ready(far_rsp_ready),
        .in_rsp_src(far_rsp_src), .in_rsp_axi_id(far_rsp_axi_id),
        .in_rsp_tag(far_rsp_tag), .in_rsp_write(far_rsp_write),
        .in_rsp_rdata(far_rsp_rdata), .in_rsp_resp(far_rsp_resp),
        .out_rsp_valid(near_rsp_valid), .out_rsp_ready(near_rsp_ready),
        .out_rsp_src(near_rsp_src), .out_rsp_axi_id(near_rsp_axi_id),
        .out_rsp_tag(near_rsp_tag), .out_rsp_write(near_rsp_write),
        .out_rsp_rdata(near_rsp_rdata), .out_rsp_resp(near_rsp_resp),
        .request_count(ucie_request_count),
        .response_count(ucie_response_count)
    );

    mc_model #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH(ID_WIDTH), .USER_WIDTH(USER_WIDTH), .TAG_WIDTH(TAG_WIDTH),
        .SCHEDULE_LATENCY(MC_LATENCY)
    ) memory_controller (
        .clk(clk), .rst_n(rst_n),
        .req_valid(far_req_valid), .req_ready(far_req_ready),
        .req_src(far_req_src), .req_axi_id(far_req_axi_id),
        .req_tag(far_req_tag), .req_write(far_req_write),
        .req_addr(far_req_addr), .req_wdata(far_req_wdata),
        .req_wstrb(far_req_wstrb),
        .rsp_valid(far_rsp_valid), .rsp_ready(far_rsp_ready),
        .rsp_src(far_rsp_src), .rsp_axi_id(far_rsp_axi_id),
        .rsp_tag(far_rsp_tag), .rsp_write(far_rsp_write),
        .rsp_rdata(far_rsp_rdata), .rsp_resp(far_rsp_resp),
        .dfi_cmd_valid(dfi_cmd_valid), .dfi_cmd_ready(dfi_cmd_ready),
        .dfi_cmd_write(dfi_cmd_write), .dfi_cmd_addr(dfi_cmd_addr),
        .dfi_cmd_wdata(dfi_cmd_wdata), .dfi_cmd_wstrb(dfi_cmd_wstrb),
        .dfi_rsp_valid(dfi_rsp_valid), .dfi_rsp_ready(dfi_rsp_ready),
        .dfi_rsp_rdata(dfi_rsp_rdata), .dfi_rsp_resp(dfi_rsp_resp),
        .command_count(mc_command_count)
    );

    dfi_memory_model #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .BASE_ADDR(MEM_BASE), .MEM_BYTES(MEM_BYTES),
        .DFI_LATENCY(DFI_LATENCY)
    ) storage_model (
        .clk(clk), .rst_n(rst_n),
        .dfi_cmd_valid(dfi_cmd_valid), .dfi_cmd_ready(dfi_cmd_ready),
        .dfi_cmd_write(dfi_cmd_write), .dfi_cmd_addr(dfi_cmd_addr),
        .dfi_cmd_wdata(dfi_cmd_wdata), .dfi_cmd_wstrb(dfi_cmd_wstrb),
        .dfi_rsp_valid(dfi_rsp_valid), .dfi_rsp_ready(dfi_rsp_ready),
        .dfi_rsp_rdata(dfi_rsp_rdata), .dfi_rsp_resp(dfi_rsp_resp),
        .read_count(memory_read_count), .write_count(memory_write_count)
    );

endmodule
