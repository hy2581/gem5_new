`timescale 1ns/1ps

// Simplified functional DFI/PHY + memory simulator placeholder.
//
// The signal set below is intentionally much smaller than real DFI.  It is a
// correctness seam between MC and a byte-addressed storage model: one command,
// fixed latency, then one response.  Replace this module with a DFI VIP/PHY and
// DRAM simulator when protocol timing, training, banks, rows, refresh, and
// performance become part of the objective.

module dfi_memory_model #(
    parameter integer ADDR_WIDTH  = 32,
    parameter integer DATA_WIDTH  = 64,
    parameter [ADDR_WIDTH-1:0] BASE_ADDR = 32'h9000_0000,
    parameter integer MEM_BYTES   = 4096,
    parameter integer DFI_LATENCY = 4
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      dfi_cmd_valid,
    output wire                      dfi_cmd_ready,
    input  wire                      dfi_cmd_write,
    input  wire [ADDR_WIDTH-1:0]     dfi_cmd_addr,
    input  wire [DATA_WIDTH-1:0]     dfi_cmd_wdata,
    input  wire [DATA_WIDTH/8-1:0]   dfi_cmd_wstrb,

    output reg                       dfi_rsp_valid,
    input  wire                      dfi_rsp_ready,
    output reg  [DATA_WIDTH-1:0]     dfi_rsp_rdata,
    output reg  [1:0]                dfi_rsp_resp,

    output reg  [31:0]               read_count,
    output reg  [31:0]               write_count
);
    localparam integer STRB_WIDTH = DATA_WIDTH / 8;
    localparam [1:0] ST_IDLE   = 2'd0;
    localparam [1:0] ST_WAIT   = 2'd1;
    localparam [1:0] ST_RETURN = 2'd2;

    reg [1:0] state;
    integer latency_countdown;
    integer i;
    reg [7:0] memory [0:MEM_BYTES-1];

    function automatic [DATA_WIDTH-1:0] read_word;
        input integer byte_offset;
        integer byte_index;
        begin
            read_word = {DATA_WIDTH{1'b0}};
            for (byte_index = 0; byte_index < STRB_WIDTH;
                 byte_index = byte_index + 1)
                read_word[byte_index*8 +: 8] = memory[byte_offset + byte_index];
        end
    endfunction

    assign dfi_cmd_ready = (state == ST_IDLE);

    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1)
            memory[i] = 8'h00;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            latency_countdown  <= 0;
            dfi_rsp_valid      <= 1'b0;
            dfi_rsp_rdata      <= {DATA_WIDTH{1'b0}};
            dfi_rsp_resp       <= 2'b00;
            read_count         <= 32'd0;
            write_count        <= 32'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (dfi_cmd_valid && dfi_cmd_ready) begin
                        latency_countdown <= DFI_LATENCY;
                        dfi_rsp_rdata     <= {DATA_WIDTH{1'b0}};
                        if (dfi_cmd_addr < BASE_ADDR ||
                            dfi_cmd_addr > (BASE_ADDR + MEM_BYTES - STRB_WIDTH)) begin
                            dfi_rsp_resp <= 2'b11; // AXI DECERR equivalent
                        end else begin
                            dfi_rsp_resp <= 2'b00;
                            if (dfi_cmd_write) begin
                                for (i = 0; i < STRB_WIDTH; i = i + 1) begin
                                    if (dfi_cmd_wstrb[i])
                                        memory[(dfi_cmd_addr - BASE_ADDR) + i]
                                            <= dfi_cmd_wdata[i*8 +: 8];
                                end
                                write_count <= write_count + 1'b1;
                            end else begin
                                dfi_rsp_rdata <= read_word(dfi_cmd_addr - BASE_ADDR);
                                read_count    <= read_count + 1'b1;
                            end
                        end
                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (latency_countdown > 0)
                        latency_countdown <= latency_countdown - 1;
                    else begin
                        dfi_rsp_valid <= 1'b1;
                        state         <= ST_RETURN;
                    end
                end

                ST_RETURN: begin
                    if (dfi_rsp_valid && dfi_rsp_ready) begin
                        dfi_rsp_valid <= 1'b0;
                        state         <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
