`timescale 1ns/1ps

// Minimal memory-controller model.
//
// It accepts one project-local memory request, waits a configurable scheduling
// delay, issues one simplified DFI command, and returns the response with all
// source/AXI/tag metadata intact.  There is intentionally no bank scheduler,
// row policy, refresh, QoS, or reordering in this first correctness model.

module mc_model #(
    parameter integer ADDR_WIDTH       = 32,
    parameter integer DATA_WIDTH       = 64,
    parameter integer ID_WIDTH         = 4,
    parameter integer USER_WIDTH       = 2,
    parameter integer TAG_WIDTH        = 16,
    parameter integer SCHEDULE_LATENCY = 2
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      req_valid,
    output wire                      req_ready,
    input  wire [USER_WIDTH-1:0]     req_src,
    input  wire [ID_WIDTH-1:0]       req_axi_id,
    input  wire [TAG_WIDTH-1:0]      req_tag,
    input  wire                      req_write,
    input  wire [ADDR_WIDTH-1:0]     req_addr,
    input  wire [DATA_WIDTH-1:0]     req_wdata,
    input  wire [DATA_WIDTH/8-1:0]   req_wstrb,

    output reg                       rsp_valid,
    input  wire                      rsp_ready,
    output reg  [USER_WIDTH-1:0]     rsp_src,
    output reg  [ID_WIDTH-1:0]       rsp_axi_id,
    output reg  [TAG_WIDTH-1:0]      rsp_tag,
    output reg                       rsp_write,
    output reg  [DATA_WIDTH-1:0]     rsp_rdata,
    output reg  [1:0]                rsp_resp,

    // Simplified functional DFI-like command/response boundary.
    output wire                      dfi_cmd_valid,
    input  wire                      dfi_cmd_ready,
    output wire                      dfi_cmd_write,
    output wire [ADDR_WIDTH-1:0]     dfi_cmd_addr,
    output wire [DATA_WIDTH-1:0]     dfi_cmd_wdata,
    output wire [DATA_WIDTH/8-1:0]   dfi_cmd_wstrb,

    input  wire                      dfi_rsp_valid,
    output wire                      dfi_rsp_ready,
    input  wire [DATA_WIDTH-1:0]     dfi_rsp_rdata,
    input  wire [1:0]                dfi_rsp_resp,

    output reg [31:0]                command_count
);
    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_SCHED  = 3'd1;
    localparam [2:0] ST_DFI    = 3'd2;
    localparam [2:0] ST_WAIT   = 3'd3;
    localparam [2:0] ST_RETURN = 3'd4;

    reg [2:0] state;
    integer schedule_countdown;

    reg [USER_WIDTH-1:0] pending_src;
    reg [ID_WIDTH-1:0] pending_axi_id;
    reg [TAG_WIDTH-1:0] pending_tag;
    reg pending_write;
    reg [ADDR_WIDTH-1:0] pending_addr;
    reg [DATA_WIDTH-1:0] pending_wdata;
    reg [DATA_WIDTH/8-1:0] pending_wstrb;

    assign req_ready      = (state == ST_IDLE);
    assign dfi_cmd_valid  = (state == ST_DFI);
    assign dfi_cmd_write  = pending_write;
    assign dfi_cmd_addr   = pending_addr;
    assign dfi_cmd_wdata  = pending_wdata;
    assign dfi_cmd_wstrb  = pending_wstrb;
    assign dfi_rsp_ready  = (state == ST_WAIT);

    always @(posedge clk) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            schedule_countdown <= 0;
            pending_src        <= {USER_WIDTH{1'b0}};
            pending_axi_id     <= {ID_WIDTH{1'b0}};
            pending_tag        <= {TAG_WIDTH{1'b0}};
            pending_write      <= 1'b0;
            pending_addr       <= {ADDR_WIDTH{1'b0}};
            pending_wdata      <= {DATA_WIDTH{1'b0}};
            pending_wstrb      <= {(DATA_WIDTH/8){1'b0}};
            rsp_valid          <= 1'b0;
            rsp_src            <= {USER_WIDTH{1'b0}};
            rsp_axi_id         <= {ID_WIDTH{1'b0}};
            rsp_tag            <= {TAG_WIDTH{1'b0}};
            rsp_write          <= 1'b0;
            rsp_rdata          <= {DATA_WIDTH{1'b0}};
            rsp_resp           <= 2'b00;
            command_count      <= 32'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        pending_src        <= req_src;
                        pending_axi_id     <= req_axi_id;
                        pending_tag        <= req_tag;
                        pending_write      <= req_write;
                        pending_addr       <= req_addr;
                        pending_wdata      <= req_wdata;
                        pending_wstrb      <= req_wstrb;
                        schedule_countdown <= SCHEDULE_LATENCY;
                        state              <= ST_SCHED;
                    end
                end

                ST_SCHED: begin
                    if (schedule_countdown > 0)
                        schedule_countdown <= schedule_countdown - 1;
                    else
                        state <= ST_DFI;
                end

                ST_DFI: begin
                    if (dfi_cmd_valid && dfi_cmd_ready) begin
                        command_count <= command_count + 1'b1;
                        state         <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (dfi_rsp_valid && dfi_rsp_ready) begin
                        rsp_src    <= pending_src;
                        rsp_axi_id <= pending_axi_id;
                        rsp_tag    <= pending_tag;
                        rsp_write  <= pending_write;
                        rsp_rdata  <= dfi_rsp_rdata;
                        rsp_resp   <= dfi_rsp_resp;
                        rsp_valid  <= 1'b1;
                        state      <= ST_RETURN;
                    end
                end

                ST_RETURN: begin
                    if (rsp_valid && rsp_ready) begin
                        rsp_valid <= 1'b0;
                        state     <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
