// e:\Verilog_HFT_FPGA\rtl\ouch_encoder.v
// NASDAQ OUCH 4.2 Enter Order ('O') Message Encoder in Verilog-2001.
// Formats strategy trigger outputs into standard binary AXI-Stream words.

`timescale 1ns / 1ps

module ouch_encoder (
    input wire clk,
    input wire rst_n,

    // Strategy Engine Trigger Inputs
    input wire        order_out_valid,
    input wire        order_out_side,      // 0 = Buy, 1 = Sell
    input wire [15:0] order_out_locate,
    input wire [63:0] order_out_symbol,    // 8-byte ASCII stock symbol
    input wire [31:0] order_out_shares,
    input wire [31:0] order_out_price,

    // Master AXI-Stream Interface (to TX MAC)
    output reg [63:0] m_axis_ouch_tdata,
    output reg [7:0]  m_axis_ouch_tkeep,
    output reg        m_axis_ouch_tvalid,
    output reg        m_axis_ouch_tlast,
    input wire        m_axis_ouch_tready,

    // Status Output
    output reg        ouch_busy
);

    // States
    localparam STATE_IDLE    = 3'd0;
    localparam STATE_CYCLE_0 = 3'd1;
    localparam STATE_CYCLE_1 = 3'd2;
    localparam STATE_CYCLE_2 = 3'd3;
    localparam STATE_CYCLE_3 = 3'd4;
    localparam STATE_CYCLE_4 = 3'd5;
    localparam STATE_CYCLE_5 = 3'd6;

    reg [2:0] state;

    // Latched Strategy Parameters
    reg        latched_side;
    reg [63:0] latched_symbol;
    reg [31:0] latched_shares;
    reg [31:0] latched_price;

    // Unique Order Token Counter
    reg [63:0] token_counter;

    // Map Side to ASCII
    wire [7:0] side_char = latched_side ? 8'h53 : 8'h42; // 'S' = Sell (0x53), 'B' = Buy (0x42)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            m_axis_ouch_tdata  <= 64'd0;
            m_axis_ouch_tkeep  <= 8'd0;
            m_axis_ouch_tvalid <= 1'b0;
            m_axis_ouch_tlast  <= 1'b0;
            ouch_busy          <= 1'b0;
            token_counter      <= 64'd1;
            latched_side       <= 1'b0;
            latched_symbol     <= 64'd0;
            latched_shares     <= 32'd0;
            latched_price      <= 32'd0;
        end else begin
            // Default AXI-Stream Control
            m_axis_ouch_tvalid <= 1'b0;
            m_axis_ouch_tlast  <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    ouch_busy <= 1'b0;
                    m_axis_ouch_tkeep <= 8'd0;
                    if (order_out_valid) begin
                        // Latch current order parameters
                        latched_side   <= order_out_side;
                        latched_symbol <= order_out_symbol;
                        latched_shares <= order_out_shares;
                        latched_price  <= order_out_price;
                        ouch_busy      <= 1'b1;
                        state          <= STATE_CYCLE_0;
                    end
                end

                STATE_CYCLE_0: begin
                    m_axis_ouch_tvalid <= 1'b1;
                    m_axis_ouch_tkeep  <= 8'hFF;
                    m_axis_ouch_tlast  <= 1'b0;
                    
                    // Byte 0: Type 'O' (0x4F)
                    // Byte 1-3: "TKN" (0x544B4E)
                    // Byte 4-7: token_counter[63:32] (big-endian)
                    m_axis_ouch_tdata  <= {
                        token_counter[39:32], token_counter[47:40], token_counter[55:48], token_counter[63:56],
                        8'h4E, 8'h4B, 8'h54, 8'h4F
                    };

                    if (m_axis_ouch_tready) begin
                        state <= STATE_CYCLE_1;
                    end
                end

                STATE_CYCLE_1: begin
                    m_axis_ouch_tvalid <= 1'b1;
                    m_axis_ouch_tkeep  <= 8'hFF;
                    m_axis_ouch_tlast  <= 1'b0;

                    // Byte 8-11: token_counter[31:0] (big-endian)
                    // Byte 12-14: spaces (0x202020)
                    // Byte 15: side_char ('B' or 'S')
                    m_axis_ouch_tdata  <= {
                        side_char, 8'h20, 8'h20, 8'h20,
                        token_counter[7:0], token_counter[15:8], token_counter[23:16], token_counter[31:24]
                    };

                    if (m_axis_ouch_tready) begin
                        state <= STATE_CYCLE_2;
                    end
                end

                STATE_CYCLE_2: begin
                    m_axis_ouch_tvalid <= 1'b1;
                    m_axis_ouch_tkeep  <= 8'hFF;
                    m_axis_ouch_tlast  <= 1'b0;

                    // Byte 16-19: shares (big-endian)
                    // Byte 20-23: symbol[63:32]
                    m_axis_ouch_tdata  <= {
                        latched_symbol[39:32], latched_symbol[47:40], latched_symbol[55:48], latched_symbol[63:56],
                        latched_shares[7:0], latched_shares[15:8], latched_shares[23:16], latched_shares[31:24]
                    };

                    if (m_axis_ouch_tready) begin
                        state <= STATE_CYCLE_3;
                    end
                end

                STATE_CYCLE_3: begin
                    m_axis_ouch_tvalid <= 1'b1;
                    m_axis_ouch_tkeep  <= 8'hFF;
                    m_axis_ouch_tlast  <= 1'b0;

                    // Byte 24-27: symbol[31:0]
                    // Byte 28-31: price (big-endian)
                    m_axis_ouch_tdata  <= {
                        latched_price[7:0], latched_price[15:8], latched_price[23:16], latched_price[31:24],
                        latched_symbol[7:0], latched_symbol[15:8], latched_symbol[23:16], latched_symbol[23:16] // Wait! symbol[23:16] was repeated, let's write it cleanly below
                    };
                    
                    // Let's write the correct slicing for symbol:
                    // Byte 24: symbol[31:24]
                    // Byte 25: symbol[23:16]
                    // Byte 26: symbol[15:8]
                    // Byte 27: symbol[7:0]
                    m_axis_ouch_tdata  <= {
                        latched_price[7:0], latched_price[15:8], latched_price[23:16], latched_price[31:24],
                        latched_symbol[7:0], latched_symbol[15:8], latched_symbol[23:16], latched_symbol[31:24]
                    };

                    if (m_axis_ouch_tready) begin
                        state <= STATE_CYCLE_4;
                    end
                end

                STATE_CYCLE_4: begin
                    m_axis_ouch_tvalid <= 1'b1;
                    m_axis_ouch_tkeep  <= 8'hFF;
                    m_axis_ouch_tlast  <= 1'b0;

                    // Byte 32-35: TIF "IOC " (0x494F4320)
                    // Byte 36: Display 'N' (0x4E)
                    // Byte 37: Capacity 'P' (0x50)
                    // Byte 38: ISO 'N' (0x4E)
                    // Byte 39: Min Qty high byte (0x00)
                    m_axis_ouch_tdata  <= {
                        8'h00, 8'h4E, 8'h50, 8'h4E,
                        8'h20, 8'h43, 8'h4F, 8'h49
                    };

                    if (m_axis_ouch_tready) begin
                        state <= STATE_CYCLE_5;
                    end
                end

                STATE_CYCLE_5: begin
                    m_axis_ouch_tvalid <= 1'b1;
                    m_axis_ouch_tkeep  <= 8'h1F; // Only 5 bytes valid (Bytes 40-44)
                    m_axis_ouch_tlast  <= 1'b1;

                    // Byte 40-42: Min Qty low bytes (0x000000)
                    // Byte 43: Cross Type ' ' (0x20)
                    // Byte 44: Customer Type ' ' (0x20)
                    // Byte 45-47: Pad zeros
                    m_axis_ouch_tdata  <= {
                        24'h000000,
                        8'h20, 8'h20,
                        24'h000000
                    };

                    if (m_axis_ouch_tready) begin
                        token_counter <= token_counter + 64'd1;
                        state         <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
