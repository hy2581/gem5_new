`timescale 1ns/1ps

// AXI4 slave front-end for the storage-chain demonstrator.
//
// Supported subset:
//   * aligned INCR bursts
//   * one transaction outstanding at a time
//   * independent AW/W handshakes and full backpressure
//   * byte write strobes
//   * AxUSER carries the XPU source id (CPU/NPU/GPU)
//
// This module is the boundary that the real XPU-to-AXI implementation plugs
// into.  The downstream request/response channel is a project-local memory
// transaction packet, not DFI and not a UCIe flit.

module axi_to_memreq #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 64,
    parameter integer ID_WIDTH   = 4,
    parameter integer USER_WIDTH = 2,
    parameter integer TAG_WIDTH  = 16
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // AXI write address channel
    input  wire [ID_WIDTH-1:0]       s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [7:0]                s_axi_awlen,
    input  wire [2:0]                s_axi_awsize,
    input  wire [1:0]                s_axi_awburst,
    input  wire [USER_WIDTH-1:0]     s_axi_awuser,
    input  wire                      s_axi_awvalid,
    output wire                      s_axi_awready,

    // AXI write data channel
    input  wire [DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]   s_axi_wstrb,
    input  wire                      s_axi_wlast,
    input  wire                      s_axi_wvalid,
    output wire                      s_axi_wready,

    // AXI write response channel
    output reg  [ID_WIDTH-1:0]       s_axi_bid,
    output reg  [1:0]                s_axi_bresp,
    output reg                       s_axi_bvalid,
    input  wire                      s_axi_bready,

    // AXI read address channel
    input  wire [ID_WIDTH-1:0]       s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire [7:0]                s_axi_arlen,
    input  wire [2:0]                s_axi_arsize,
    input  wire [1:0]                s_axi_arburst,
    input  wire [USER_WIDTH-1:0]     s_axi_aruser,
    input  wire                      s_axi_arvalid,
    output wire                      s_axi_arready,

    // AXI read data channel
    output reg  [ID_WIDTH-1:0]       s_axi_rid,
    output reg  [DATA_WIDTH-1:0]     s_axi_rdata,
    output reg  [1:0]                s_axi_rresp,
    output reg                       s_axi_rlast,
    output reg                       s_axi_rvalid,
    input  wire                      s_axi_rready,

    // Project-local memory request channel
    output reg                       req_valid,
    input  wire                      req_ready,
    output reg  [USER_WIDTH-1:0]     req_src,
    output reg  [ID_WIDTH-1:0]       req_axi_id,
    output reg  [TAG_WIDTH-1:0]      req_tag,
    output reg                       req_write,
    output reg  [ADDR_WIDTH-1:0]     req_addr,
    output reg  [DATA_WIDTH-1:0]     req_wdata,
    output reg  [DATA_WIDTH/8-1:0]   req_wstrb,

    // Project-local memory response channel
    input  wire                      rsp_valid,
    output wire                      rsp_ready,
    input  wire [USER_WIDTH-1:0]     rsp_src,
    input  wire [ID_WIDTH-1:0]       rsp_axi_id,
    input  wire [TAG_WIDTH-1:0]      rsp_tag,
    input  wire                      rsp_write,
    input  wire [DATA_WIDTH-1:0]     rsp_rdata,
    input  wire [1:0]                rsp_resp,

    output reg  [31:0]               accepted_beat_count
);

    localparam integer STRB_WIDTH = DATA_WIDTH / 8;
    localparam integer MAX_AXSIZE = $clog2(STRB_WIDTH);

    localparam [3:0] ST_IDLE    = 4'd0;
    localparam [3:0] ST_WR_DATA = 4'd1;
    localparam [3:0] ST_WR_REQ  = 4'd2;
    localparam [3:0] ST_WR_RSP  = 4'd3;
    localparam [3:0] ST_WR_B    = 4'd4;
    localparam [3:0] ST_RD_REQ  = 4'd5;
    localparam [3:0] ST_RD_RSP  = 4'd6;
    localparam [3:0] ST_RD_DATA = 4'd7;

    reg [3:0] state;
    reg [TAG_WIDTH-1:0] next_tag;
    reg [TAG_WIDTH-1:0] pending_tag;

    reg [ID_WIDTH-1:0] write_id;
    reg [USER_WIDTH-1:0] write_src;
    reg [ADDR_WIDTH-1:0] write_addr;
    reg [7:0] write_len;
    reg [7:0] write_beat;
    reg [2:0] write_size;
    reg [1:0] write_resp_accum;
    reg pending_wlast;

    reg [ID_WIDTH-1:0] read_id;
    reg [USER_WIDTH-1:0] read_src;
    reg [ADDR_WIDTH-1:0] read_addr;
    reg [7:0] read_len;
    reg [7:0] read_beat;
    reg [2:0] read_size;

    wire [ADDR_WIDTH-1:0] write_step = {{(ADDR_WIDTH-1){1'b0}}, 1'b1} << write_size;
    wire [ADDR_WIDTH-1:0] read_step  = {{(ADDR_WIDTH-1){1'b0}}, 1'b1} << read_size;

    // Write address wins if AW and AR arrive together.  Keeping ARREADY low in
    // that case prevents two handshakes while the front-end is single-issue.
    assign s_axi_awready = (state == ST_IDLE);
    assign s_axi_arready = (state == ST_IDLE) && !s_axi_awvalid;
    assign s_axi_wready  = (state == ST_WR_DATA);
    assign rsp_ready     = (state == ST_WR_RSP) || (state == ST_RD_RSP);

    always @(posedge clk) begin
        if (!rst_n) begin
            state               <= ST_IDLE;
            next_tag            <= {TAG_WIDTH{1'b0}};
            pending_tag         <= {TAG_WIDTH{1'b0}};
            req_valid           <= 1'b0;
            req_src             <= {USER_WIDTH{1'b0}};
            req_axi_id          <= {ID_WIDTH{1'b0}};
            req_tag             <= {TAG_WIDTH{1'b0}};
            req_write           <= 1'b0;
            req_addr            <= {ADDR_WIDTH{1'b0}};
            req_wdata           <= {DATA_WIDTH{1'b0}};
            req_wstrb           <= {STRB_WIDTH{1'b0}};
            s_axi_bid           <= {ID_WIDTH{1'b0}};
            s_axi_bresp         <= 2'b00;
            s_axi_bvalid        <= 1'b0;
            s_axi_rid           <= {ID_WIDTH{1'b0}};
            s_axi_rdata         <= {DATA_WIDTH{1'b0}};
            s_axi_rresp         <= 2'b00;
            s_axi_rlast         <= 1'b0;
            s_axi_rvalid        <= 1'b0;
            write_id            <= {ID_WIDTH{1'b0}};
            write_src           <= {USER_WIDTH{1'b0}};
            write_addr          <= {ADDR_WIDTH{1'b0}};
            write_len           <= 8'd0;
            write_beat          <= 8'd0;
            write_size          <= 3'd0;
            write_resp_accum    <= 2'b00;
            pending_wlast       <= 1'b0;
            read_id             <= {ID_WIDTH{1'b0}};
            read_src            <= {USER_WIDTH{1'b0}};
            read_addr           <= {ADDR_WIDTH{1'b0}};
            read_len            <= 8'd0;
            read_beat           <= 8'd0;
            read_size           <= 3'd0;
            accepted_beat_count <= 32'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (s_axi_awvalid && s_axi_awready) begin
                        if (s_axi_awburst != 2'b01)
                            $fatal(1, "AXI front-end supports INCR writes only");
                        if ({29'd0, s_axi_awsize} > MAX_AXSIZE)
                            $fatal(1, "AXI write size exceeds data bus width");
                        write_id         <= s_axi_awid;
                        write_src        <= s_axi_awuser;
                        write_addr       <= s_axi_awaddr;
                        write_len        <= s_axi_awlen;
                        write_beat       <= 8'd0;
                        write_size       <= s_axi_awsize;
                        write_resp_accum <= 2'b00;
                        state            <= ST_WR_DATA;
                    end else if (s_axi_arvalid && s_axi_arready) begin
                        if (s_axi_arburst != 2'b01)
                            $fatal(1, "AXI front-end supports INCR reads only");
                        if ({29'd0, s_axi_arsize} > MAX_AXSIZE)
                            $fatal(1, "AXI read size exceeds data bus width");
                        read_id      <= s_axi_arid;
                        read_src     <= s_axi_aruser;
                        read_addr    <= s_axi_araddr;
                        read_len     <= s_axi_arlen;
                        read_beat    <= 8'd0;
                        read_size    <= s_axi_arsize;
                        req_src      <= s_axi_aruser;
                        req_axi_id   <= s_axi_arid;
                        req_tag      <= next_tag;
                        pending_tag  <= next_tag;
                        req_write    <= 1'b0;
                        req_addr     <= s_axi_araddr;
                        req_wdata    <= {DATA_WIDTH{1'b0}};
                        req_wstrb    <= {STRB_WIDTH{1'b0}};
                        req_valid    <= 1'b1;
                        next_tag     <= next_tag + 1'b1;
                        state        <= ST_RD_REQ;
                    end
                end

                ST_WR_DATA: begin
                    if (s_axi_wvalid && s_axi_wready) begin
                        if (s_axi_wlast != (write_beat == write_len))
                            $fatal(1, "AXI WLAST does not match AWLEN");
                        req_src      <= write_src;
                        req_axi_id   <= write_id;
                        req_tag      <= next_tag;
                        pending_tag  <= next_tag;
                        req_write    <= 1'b1;
                        req_addr     <= write_addr;
                        req_wdata    <= s_axi_wdata;
                        req_wstrb    <= s_axi_wstrb;
                        req_valid    <= 1'b1;
                        pending_wlast <= s_axi_wlast;
                        next_tag     <= next_tag + 1'b1;
                        state        <= ST_WR_REQ;
                    end
                end

                ST_WR_REQ: begin
                    if (req_valid && req_ready) begin
                        req_valid           <= 1'b0;
                        accepted_beat_count <= accepted_beat_count + 1'b1;
                        state               <= ST_WR_RSP;
                    end
                end

                ST_WR_RSP: begin
                    if (rsp_valid && rsp_ready) begin
                        if (!rsp_write || rsp_tag != pending_tag ||
                            rsp_src != write_src || rsp_axi_id != write_id)
                            $fatal(1, "write response metadata mismatch");
                        if (rsp_resp != 2'b00)
                            write_resp_accum <= rsp_resp;
                        if (pending_wlast) begin
                            s_axi_bid    <= write_id;
                            s_axi_bresp  <= (rsp_resp != 2'b00) ? rsp_resp : write_resp_accum;
                            s_axi_bvalid <= 1'b1;
                            state        <= ST_WR_B;
                        end else begin
                            write_addr <= write_addr + write_step;
                            write_beat <= write_beat + 1'b1;
                            state      <= ST_WR_DATA;
                        end
                    end
                end

                ST_WR_B: begin
                    if (s_axi_bvalid && s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        state        <= ST_IDLE;
                    end
                end

                ST_RD_REQ: begin
                    if (req_valid && req_ready) begin
                        req_valid           <= 1'b0;
                        accepted_beat_count <= accepted_beat_count + 1'b1;
                        state               <= ST_RD_RSP;
                    end
                end

                ST_RD_RSP: begin
                    if (rsp_valid && rsp_ready) begin
                        if (rsp_write || rsp_tag != pending_tag ||
                            rsp_src != read_src || rsp_axi_id != read_id)
                            $fatal(1, "read response metadata mismatch");
                        s_axi_rid    <= read_id;
                        s_axi_rdata  <= rsp_rdata;
                        s_axi_rresp  <= rsp_resp;
                        s_axi_rlast  <= (read_beat == read_len);
                        s_axi_rvalid <= 1'b1;
                        state        <= ST_RD_DATA;
                    end
                end

                ST_RD_DATA: begin
                    if (s_axi_rvalid && s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        if (s_axi_rlast) begin
                            s_axi_rlast <= 1'b0;
                            state       <= ST_IDLE;
                        end else begin
                            read_addr   <= read_addr + read_step;
                            read_beat   <= read_beat + 1'b1;
                            req_src     <= read_src;
                            req_axi_id  <= read_id;
                            req_tag     <= next_tag;
                            pending_tag <= next_tag;
                            req_write   <= 1'b0;
                            req_addr    <= read_addr + read_step;
                            req_wdata   <= {DATA_WIDTH{1'b0}};
                            req_wstrb   <= {STRB_WIDTH{1'b0}};
                            req_valid   <= 1'b1;
                            next_tag    <= next_tag + 1'b1;
                            state       <= ST_RD_REQ;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
