// e:\Verilog_HFT_FPGA\rtl\order_book.v
// BRAM-based Level 2 (BBO) Order Book in Verilog-2001.
// Updates Top-of-Book (Best Bid / Best Ask) upon receiving ITCH messages.
// Runs entirely in the clk_core domain.

`timescale 1ns / 1ps

module order_book #(
    parameter MAX_STOCKS = 1024
) (
    input wire clk,
    input wire rst_n,

    // Write Interface (from async_fifo, synchronous to clk)
    input wire        itch_msg_valid,
    input wire [15:0] itch_stock_locate,
    input wire        itch_side,       // 0 = Buy, 1 = Sell
    input wire [31:0] itch_shares,
    input wire [31:0] itch_price,

    // Read Interface (for strategy_engine, synchronous to clk)
    input wire [15:0] read_stock_locate,
    output wire [31:0] out_best_bid_price,
    output wire [31:0] out_best_bid_shares,
    output wire [31:0] out_best_ask_price,
    output wire [31:0] out_best_ask_shares,

    // Event Strobe (synchronous to clk)
    output reg        book_updated,
    output reg [15:0] updated_stock_locate
);

    // Memory Arrays (BRAM structures)
    reg [31:0] best_bid_price  [0:MAX_STOCKS-1];
    reg [31:0] best_bid_shares [0:MAX_STOCKS-1];
    reg [31:0] best_ask_price  [0:MAX_STOCKS-1];
    reg [31:0] best_ask_shares [0:MAX_STOCKS-1];

    // Asynchronous Read Lookups (Port B)
    wire [9:0] read_idx = read_stock_locate[9:0];
    assign out_best_bid_price  = best_bid_price[read_idx];
    assign out_best_bid_shares = best_bid_shares[read_idx];
    assign out_best_ask_price  = best_ask_price[read_idx];
    assign out_best_ask_shares = best_ask_shares[read_idx];

    // Write Index (Port A)
    wire [9:0] write_idx = itch_stock_locate[9:0];

    // Helper variables to read current state during write cycle
    reg [31:0] cur_bid_price;
    reg [31:0] cur_bid_shares;
    reg [31:0] cur_ask_price;
    reg [31:0] cur_ask_shares;

    integer i;

    // Sequential update block
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            book_updated <= 1'b0;
            updated_stock_locate <= 16'd0;

            // Clear memories
            for (i = 0; i < MAX_STOCKS; i = i + 1) begin
                best_bid_price[i]  <= 32'd0;
                best_bid_shares[i] <= 32'd0;
                best_ask_price[i]  <= 32'd0;
                best_ask_shares[i] <= 32'd0;
            end
        end else begin
            book_updated <= 1'b0;

            if (itch_msg_valid) begin // Message is valid from FIFO
                cur_bid_price  = best_bid_price[write_idx];
                cur_bid_shares = best_bid_shares[write_idx];
                cur_ask_price  = best_ask_price[write_idx];
                cur_ask_shares = best_ask_shares[write_idx];

                if (itch_side == 1'b0) begin // Buy Add Order
                    if (itch_price > cur_bid_price || cur_bid_price == 32'd0) begin
                        best_bid_price[write_idx]  <= itch_price;
                        best_bid_shares[write_idx] <= itch_shares;
                        book_updated <= 1'b1;
                        updated_stock_locate <= itch_stock_locate;
                    end else if (itch_price == cur_bid_price) begin
                        best_bid_shares[write_idx] <= cur_bid_shares + itch_shares;
                        book_updated <= 1'b1;
                        updated_stock_locate <= itch_stock_locate;
                    end
                end else begin // Sell Add Order
                    if (itch_price < cur_ask_price || cur_ask_price == 32'd0) begin
                        best_ask_price[write_idx]  <= itch_price;
                        best_ask_shares[write_idx] <= itch_shares;
                        book_updated <= 1'b1;
                        updated_stock_locate <= itch_stock_locate;
                    end else if (itch_price == cur_ask_price) begin
                        best_ask_shares[write_idx] <= cur_ask_shares + itch_shares;
                        book_updated <= 1'b1;
                        updated_stock_locate <= itch_stock_locate;
                    end
                end
            end
        end
    end

endmodule
