// e:\Verilog_HFT_FPGA\rtl\strategy_engine.v
// Quantitative Strategy Engine & Pre-Trade Risk check in Verilog-2001.
// Compares BBO book prices against host parameters and checks risk limits.

`timescale 1ns / 1ps

module strategy_engine #(
    parameter MAX_STOCKS = 1024,
    parameter [31:0] RISK_MAX_SHARES = 32'd5000,       // Safe share count threshold
    parameter [31:0] RISK_MAX_PRICE  = 32'd5000000,    // Safe price threshold ($500.0000)
    parameter [31:0] RISK_MAX_TRADES = 32'd5           // Max trade loop execution count
) (
    input wire clk,
    input wire rst_n,

    // Host Config Interface (for loading trading limits)
    input wire        host_write_enable,
    input wire [15:0] host_stock_locate,
    input wire [31:0] host_buy_trigger_price,  // Trigger buy if ask_price <= buy_trigger
    input wire [31:0] host_sell_trigger_price, // Trigger sell if bid_price >= sell_trigger
    input wire [31:0] host_order_size,
    input wire [63:0] host_stock_symbol,       // 8-byte ASCII stock symbol configure

    // Book Inputs (from order_book)
    input wire        book_updated,
    input wire [15:0] updated_stock_locate,
    input wire [31:0] best_bid_price,
    input wire [31:0] best_bid_shares,
    input wire [31:0] best_ask_price,
    input wire [31:0] best_ask_shares,

    // Order Output Gateway (to OUCH Encoder)
    output reg        order_out_valid,
    output reg        order_out_side,      // 0 = Buy, 1 = Sell
    output reg [15:0] order_out_locate,
    output reg [31:0] order_out_shares,
    output reg [31:0] order_out_price,
    output reg [63:0] order_out_symbol,    // 8-byte ASCII Stock Symbol output

    // Risk and Status Outputs
    output reg        status_risk_violation,
    output reg [31:0] stats_trades_executed
);

    // Strategy Parameters Memory (loaded by Host)
    reg [31:0] target_buy_trigger  [0:MAX_STOCKS-1];
    reg [31:0] target_sell_trigger [0:MAX_STOCKS-1];
    reg [31:0] target_order_size   [0:MAX_STOCKS-1];
    reg [63:0] target_stock_symbol [0:MAX_STOCKS-1]; // 8-byte ASCII stock symbols

    // Local Variables for comparison logic
    reg [31:0] config_buy_price;
    reg [31:0] config_sell_price;
    reg [31:0] config_order_size;

    reg [31:0] proposed_shares;
    reg [31:0] proposed_price;
    reg        proposed_side;
    reg        strategy_matched;

    integer i;

    // Sequential Evaluation & Configuration
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            order_out_valid <= 1'b0;
            order_out_side  <= 1'b0;
            order_out_locate <= 16'd0;
            order_out_shares <= 32'd0;
            order_out_price  <= 32'd0;
            order_out_symbol <= 64'd0;
            status_risk_violation <= 1'b0;
            stats_trades_executed <= 32'd0;

            // Clear memories
            for (i = 0; i < MAX_STOCKS; i = i + 1) begin
                target_buy_trigger[i]  <= 32'd0;
                target_sell_trigger[i] <= 32'd0;
                target_order_size[i]   <= 32'd0;
                target_stock_symbol[i] <= 64'd0;
            end
        end else begin
            order_out_valid <= 1'b0; // Default output strobe
            status_risk_violation <= 1'b0;

            // 1. Host Parameter Writing
            if (host_write_enable) begin
                $display("[RTL STRATEGY WRITE] raw_locate=%d buy_trig=%d size=%d", host_stock_locate, host_buy_trigger_price, host_order_size);
                target_buy_trigger[host_stock_locate[9:0]]  <= host_buy_trigger_price;
                target_sell_trigger[host_stock_locate[9:0]] <= host_sell_trigger_price;
                target_order_size[host_stock_locate[9:0]]   <= host_order_size;
                target_stock_symbol[host_stock_locate[9:0]] <= host_stock_symbol;
            end

            // 2. Strategy evaluation when the order book updates
            if (book_updated) begin
                $display("[RTL STRATEGY READ] book_locate=%d target_buy_trigger=%d", updated_stock_locate, target_buy_trigger[updated_stock_locate[9:0]]);
                config_buy_price  = target_buy_trigger[updated_stock_locate[9:0]];
                config_sell_price = target_sell_trigger[updated_stock_locate[9:0]];
                config_order_size = target_order_size[updated_stock_locate[9:0]];

                strategy_matched = 1'b0;
                proposed_shares  = 32'd0;
                proposed_price   = 32'd0;
                proposed_side    = 1'b0;

                // Check BUY Strategy: Market Ask price <= Target buy price
                if (best_ask_price > 32'd0 && best_ask_price <= config_buy_price && config_buy_price > 32'd0) begin
                    strategy_matched = 1'b1;
                    proposed_side    = 1'b0; // Buy
                    proposed_price   = best_ask_price;
                    // Buy size = min(our target size, available market shares)
                    proposed_shares  = (config_order_size < best_ask_shares) ? config_order_size : best_ask_shares;
                end
                
                // Check SELL Strategy: Market Bid price >= Target sell price
                else if (best_bid_price >= config_sell_price && config_sell_price > 32'd0) begin
                    strategy_matched = 1'b1;
                    proposed_side    = 1'b1; // Sell
                    proposed_price   = best_bid_price;
                    // Sell size = min(our target size, available market shares)
                    proposed_shares  = (config_order_size < best_bid_shares) ? config_order_size : best_bid_shares;
                end

                // 3. Pre-Trade Risk Checks
                if (strategy_matched) begin
                    if (proposed_shares > 32'd0 &&
                        proposed_shares <= RISK_MAX_SHARES &&
                        proposed_price <= RISK_MAX_PRICE &&
                        stats_trades_executed < RISK_MAX_TRADES) begin
                        
                        // Risk Check Passed - Generate Order Out
                        order_out_valid  <= 1'b1;
                        order_out_side   <= proposed_side;
                        order_out_locate <= updated_stock_locate;
                        order_out_shares <= proposed_shares;
                        order_out_price  <= proposed_price;
                        order_out_symbol <= target_stock_symbol[updated_stock_locate[9:0]];
                        stats_trades_executed <= stats_trades_executed + 32'd1;
                    end else begin
                        // Risk Check Blocked Order
                        status_risk_violation <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
