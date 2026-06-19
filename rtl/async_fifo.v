// e:\Verilog_HFT_FPGA\rtl\async_fifo.v
// Parameterized Asynchronous Gray-Code Dual-Clock FIFO in Verilog-2001.
// Handles safe Clock Domain Crossing (CDC) of data buses.

`timescale 1ns / 1ps

module async_fifo #(
    parameter WIDTH = 81,
    parameter ADDR_WIDTH = 4,
    parameter DEPTH = 16
) (
    // Write Domain (wclk)
    input wire              wclk,
    input wire              wrst_n,
    input wire              winc,
    input wire [WIDTH-1:0]  wdata,
    output reg              wfull,

    // Read Domain (rclk)
    input wire              rclk,
    input wire              rrst_n,
    input wire              rinc,
    output wire [WIDTH-1:0] rdata,
    output reg              rempty
);

    // FIFO Memory array
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers
    reg [ADDR_WIDTH:0] wptr_bin;
    reg [ADDR_WIDTH:0] rptr_bin;
    reg [ADDR_WIDTH:0] wptr_gray;
    reg [ADDR_WIDTH:0] rptr_gray;

    // Synchronizers: 2-stage registers for Gray-coded pointers
    reg [ADDR_WIDTH:0] wptr_gray_sync_r1;
    reg [ADDR_WIDTH:0] wptr_gray_sync_r2;
    reg [ADDR_WIDTH:0] rptr_gray_sync_w1;
    reg [ADDR_WIDTH:0] rptr_gray_sync_w2;

    // Helper wires
    wire [ADDR_WIDTH:0] wptr_bin_next;
    wire [ADDR_WIDTH:0] rptr_bin_next;
    wire [ADDR_WIDTH:0] wptr_gray_next;
    wire [ADDR_WIDTH:0] rptr_gray_next;

    // ==========================================================
    // WRITE PORT LOGIC (wclk domain)
    // ==========================================================
    
    // Write if enabled and not full
    always @(posedge wclk) begin
        if (winc && !wfull) begin
            mem[wptr_bin[ADDR_WIDTH-1:0]] <= wdata;
        end
    end

    // Binary and Gray Pointer generation
    assign wptr_bin_next  = wptr_bin + (winc && !wfull);
    assign wptr_gray_next = wptr_bin_next ^ (wptr_bin_next >> 1);

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wptr_bin  <= 0;
            wptr_gray <= 0;
        end else begin
            wptr_bin  <= wptr_bin_next;
            wptr_gray <= wptr_gray_next;
        end
    end

    // Synchronize rptr_gray to wclk domain
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rptr_gray_sync_w1 <= 0;
            rptr_gray_sync_w2 <= 0;
        end else begin
            rptr_gray_sync_w1 <= rptr_gray;
            rptr_gray_sync_w2 <= rptr_gray_sync_w1;
        end
    end

    // Full Flag Generation
    // FIFO is full when write and read pointers are opposite in the 2 MSBs of Gray code,
    // and equal in the lower bits.
    wire wfull_val = (wptr_gray_next == {~rptr_gray_sync_w2[ADDR_WIDTH:ADDR_WIDTH-1], rptr_gray_sync_w2[ADDR_WIDTH-2:0]});

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wfull <= 1'b0;
        end else begin
            wfull <= wfull_val;
        end
    end

    // ==========================================================
    // READ PORT LOGIC (rclk domain)
    // ==========================================================

    // Asynchronous read from memory (registered in Port B output elsewhere)
    assign rdata = mem[rptr_bin[ADDR_WIDTH-1:0]];

    // Binary and Gray Pointer generation
    assign rptr_bin_next  = rptr_bin + (rinc && !rempty);
    assign rptr_gray_next = rptr_bin_next ^ (rptr_bin_next >> 1);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rptr_bin  <= 0;
            rptr_gray <= 0;
        end else begin
            rptr_bin  <= rptr_bin_next;
            rptr_gray <= rptr_gray_next;
        end
    end

    // Synchronize wptr_gray to rclk domain
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wptr_gray_sync_r1 <= 0;
            wptr_gray_sync_r2 <= 0;
        end else begin
            wptr_gray_sync_r1 <= wptr_gray;
            wptr_gray_sync_r2 <= wptr_gray_sync_r1;
        end
    end

    // Empty Flag Generation
    // FIFO is empty when Gray write pointer matches Gray read pointer in the read domain.
    wire rempty_val = (rptr_gray_next == wptr_gray_sync_r2);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rempty <= 1'b1;
        end else begin
            rempty <= rempty_val;
        end
    end

endmodule
