`timescale 1ns/1ps

// One-entry ready/valid delay element used by the functional UCIe placeholder.
module rv_delay #(
    parameter integer WIDTH   = 8,
    parameter integer LATENCY = 3
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             in_valid,
    output wire             in_ready,
    input  wire [WIDTH-1:0] in_payload,
    output wire             out_valid,
    input  wire             out_ready,
    output wire [WIDTH-1:0] out_payload
);
    reg full;
    reg [WIDTH-1:0] payload_q;
    integer remaining;

    assign in_ready    = !full;
    assign out_valid   = full && (remaining == 0);
    assign out_payload = payload_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            full      <= 1'b0;
            payload_q <= {WIDTH{1'b0}};
            remaining <= 0;
        end else if (!full) begin
            if (in_valid) begin
                full      <= 1'b1;
                payload_q <= in_payload;
                remaining <= LATENCY;
            end
        end else if (remaining > 0) begin
            remaining <= remaining - 1;
        end else if (out_ready) begin
            full <= 1'b0;
        end
    end
endmodule
