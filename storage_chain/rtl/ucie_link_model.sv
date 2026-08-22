`timescale 1ns/1ps

// Transaction-level UCIe placeholder.
//
// This model deliberately does not claim UCIe protocol compliance: there are
// no flits, credits, CRC/retry, link training, sideband, or lane model.  It is
// a pair of lossless ready/valid delay channels used to prove the request and
// response plumbing before a real UCIe adapter is available.

module ucie_link_model #(
    parameter integer ADDR_WIDTH   = 32,
    parameter integer DATA_WIDTH   = 64,
    parameter integer ID_WIDTH     = 4,
    parameter integer USER_WIDTH   = 2,
    parameter integer TAG_WIDTH    = 16,
    parameter integer LINK_LATENCY = 3
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // Request entering the near-side adapter
    input  wire                      in_req_valid,
    output wire                      in_req_ready,
    input  wire [USER_WIDTH-1:0]     in_req_src,
    input  wire [ID_WIDTH-1:0]       in_req_axi_id,
    input  wire [TAG_WIDTH-1:0]      in_req_tag,
    input  wire                      in_req_write,
    input  wire [ADDR_WIDTH-1:0]     in_req_addr,
    input  wire [DATA_WIDTH-1:0]     in_req_wdata,
    input  wire [DATA_WIDTH/8-1:0]   in_req_wstrb,

    // Request leaving the far-side adapter toward MC
    output wire                      out_req_valid,
    input  wire                      out_req_ready,
    output wire [USER_WIDTH-1:0]     out_req_src,
    output wire [ID_WIDTH-1:0]       out_req_axi_id,
    output wire [TAG_WIDTH-1:0]      out_req_tag,
    output wire                      out_req_write,
    output wire [ADDR_WIDTH-1:0]     out_req_addr,
    output wire [DATA_WIDTH-1:0]     out_req_wdata,
    output wire [DATA_WIDTH/8-1:0]   out_req_wstrb,

    // Response entering from MC
    input  wire                      in_rsp_valid,
    output wire                      in_rsp_ready,
    input  wire [USER_WIDTH-1:0]     in_rsp_src,
    input  wire [ID_WIDTH-1:0]       in_rsp_axi_id,
    input  wire [TAG_WIDTH-1:0]      in_rsp_tag,
    input  wire                      in_rsp_write,
    input  wire [DATA_WIDTH-1:0]     in_rsp_rdata,
    input  wire [1:0]                in_rsp_resp,

    // Response delivered back to the AXI front-end
    output wire                      out_rsp_valid,
    input  wire                      out_rsp_ready,
    output wire [USER_WIDTH-1:0]     out_rsp_src,
    output wire [ID_WIDTH-1:0]       out_rsp_axi_id,
    output wire [TAG_WIDTH-1:0]      out_rsp_tag,
    output wire                      out_rsp_write,
    output wire [DATA_WIDTH-1:0]     out_rsp_rdata,
    output wire [1:0]                out_rsp_resp,

    output reg [31:0]                request_count,
    output reg [31:0]                response_count
);
    localparam integer STRB_WIDTH = DATA_WIDTH / 8;
    localparam integer REQ_WIDTH = USER_WIDTH + ID_WIDTH + TAG_WIDTH + 1 +
                                   ADDR_WIDTH + DATA_WIDTH + STRB_WIDTH;
    localparam integer RSP_WIDTH = USER_WIDTH + ID_WIDTH + TAG_WIDTH + 1 +
                                   DATA_WIDTH + 2;

    wire [REQ_WIDTH-1:0] req_payload_in;
    wire [REQ_WIDTH-1:0] req_payload_out;
    wire [RSP_WIDTH-1:0] rsp_payload_in;
    wire [RSP_WIDTH-1:0] rsp_payload_out;

    assign req_payload_in = {
        in_req_src, in_req_axi_id, in_req_tag, in_req_write,
        in_req_addr, in_req_wdata, in_req_wstrb
    };
    assign {
        out_req_src, out_req_axi_id, out_req_tag, out_req_write,
        out_req_addr, out_req_wdata, out_req_wstrb
    } = req_payload_out;

    assign rsp_payload_in = {
        in_rsp_src, in_rsp_axi_id, in_rsp_tag, in_rsp_write,
        in_rsp_rdata, in_rsp_resp
    };
    assign {
        out_rsp_src, out_rsp_axi_id, out_rsp_tag, out_rsp_write,
        out_rsp_rdata, out_rsp_resp
    } = rsp_payload_out;

    rv_delay #(
        .WIDTH(REQ_WIDTH),
        .LATENCY(LINK_LATENCY)
    ) request_path (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_req_valid), .in_ready(in_req_ready),
        .in_payload(req_payload_in),
        .out_valid(out_req_valid), .out_ready(out_req_ready),
        .out_payload(req_payload_out)
    );

    rv_delay #(
        .WIDTH(RSP_WIDTH),
        .LATENCY(LINK_LATENCY)
    ) response_path (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_rsp_valid), .in_ready(in_rsp_ready),
        .in_payload(rsp_payload_in),
        .out_valid(out_rsp_valid), .out_ready(out_rsp_ready),
        .out_payload(rsp_payload_out)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            request_count  <= 32'd0;
            response_count <= 32'd0;
        end else begin
            if (in_req_valid && in_req_ready)
                request_count <= request_count + 1'b1;
            if (in_rsp_valid && in_rsp_ready)
                response_count <= response_count + 1'b1;
        end
    end
endmodule
