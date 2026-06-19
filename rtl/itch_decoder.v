// e:\Verilog_HFT_FPGA\rtl\itch_decoder.v
// NASDAQ ITCH 5.0 Decoder in Verilog-2001
// Parses MoldUDP64 framing and decodes Add Order (Type 'A') messages.

`timescale 1ns / 1ps

module itch_decoder (
    input wire clk,
    input wire rst_n,

    // Input AXI-Stream from Network Parser
    input wire [63:0] s_axis_tdata,
    input wire [7:0]  s_axis_tkeep,
    input wire        s_axis_tvalid,
    input wire        s_axis_tlast,
    output wire       s_axis_tready,

    // Decoded ITCH Message Output Strobe
    output reg        itch_msg_valid,
    output reg [7:0]  itch_msg_type,
    output reg [63:0] itch_order_id,
    output reg        itch_side,       // 0 = Buy, 1 = Sell
    output reg [31:0] itch_shares,
    output reg [63:0] itch_symbol,     // 8-byte ASCII Stock Symbol
    output reg [31:0] itch_price,      // 4 implied decimal places
    output reg [15:0] itch_stock_locate
);

    // Circular buffer (128 bytes)
    reg [7:0] buf_mem [0:127];
    reg [6:0] write_ptr;
    reg [6:0] msg_ptr;

    // Buffer occupancy
    wire [6:0] bytes_in_buf = write_ptr - msg_ptr;

    // Flow control: assert ready if we have space for at least 4 cycles (32 bytes)
    assign s_axis_tready = (bytes_in_buf < 7'd96);

    // States
    localparam STATE_IDLE      = 2'd0;
    localparam STATE_MOLD_HDR  = 2'd1;
    localparam STATE_PARSE_MSG = 2'd2;

    reg [1:0] state;
    reg [15:0] remaining_msgs;

    // Temporary variables for parsing inside the sequential block
    reg [15:0] current_msg_len;
    reg [7:0]  current_msg_type;

    // Main Sequential Block
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            write_ptr <= 7'd0;
            msg_ptr <= 7'd0;
            remaining_msgs <= 16'd0;
            itch_msg_valid <= 1'b0;
            itch_msg_type <= 8'd0;
            itch_order_id <= 64'd0;
            itch_side <= 1'b0;
            itch_shares <= 32'd0;
            itch_symbol <= 64'd0;
            itch_price <= 32'd0;
            itch_stock_locate <= 16'd0;
        end else begin
            itch_msg_valid <= 1'b0; // Default strobe

            // 1. Write incoming stream to circular buffer
            if (s_axis_tvalid && s_axis_tready) begin
                // Write each byte based on tkeep
                if (s_axis_tkeep[0]) buf_mem[write_ptr]        <= s_axis_tdata[7:0];
                if (s_axis_tkeep[1]) buf_mem[write_ptr + 7'd1] <= s_axis_tdata[15:8];
                if (s_axis_tkeep[2]) buf_mem[write_ptr + 7'd2] <= s_axis_tdata[23:16];
                if (s_axis_tkeep[3]) buf_mem[write_ptr + 7'd3] <= s_axis_tdata[31:24];
                if (s_axis_tkeep[4]) buf_mem[write_ptr + 7'd4] <= s_axis_tdata[39:32];
                if (s_axis_tkeep[5]) buf_mem[write_ptr + 7'd5] <= s_axis_tdata[47:40];
                if (s_axis_tkeep[6]) buf_mem[write_ptr + 7'd6] <= s_axis_tdata[55:48];
                if (s_axis_tkeep[7]) buf_mem[write_ptr + 7'd7] <= s_axis_tdata[63:56];
                
                // Increment write pointer by number of active bytes
                // Normally keep is 8'hFF, so we add 8.
                if (s_axis_tkeep == 8'hFF)
                    write_ptr <= write_ptr + 7'd8;
                else begin
                    // Find actual count of set bits in tkeep
                    // (Simplified for packet termination cases where keep has consecutive 1s from bit 0)
                    if (s_axis_tkeep[7])      write_ptr <= write_ptr + 7'd8;
                    else if (s_axis_tkeep[6]) write_ptr <= write_ptr + 7'd7;
                    else if (s_axis_tkeep[5]) write_ptr <= write_ptr + 7'd6;
                    else if (s_axis_tkeep[4]) write_ptr <= write_ptr + 7'd5;
                    else if (s_axis_tkeep[3]) write_ptr <= write_ptr + 7'd4;
                    else if (s_axis_tkeep[2]) write_ptr <= write_ptr + 7'd3;
                    else if (s_axis_tkeep[1]) write_ptr <= write_ptr + 7'd2;
                    else if (s_axis_tkeep[0]) write_ptr <= write_ptr + 7'd1;
                end
            end

            // 2. Parser State Machine
            case (state)
                STATE_IDLE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        state <= STATE_MOLD_HDR;
                    end
                end

                STATE_MOLD_HDR: begin
                    // Wait until we have received the full 20-byte MoldUDP64 header
                    if (bytes_in_buf >= 7'd20) begin
                        // Extract Message Count (Bytes 18-19, big-endian)
                        remaining_msgs <= {buf_mem[msg_ptr + 7'd18], buf_mem[msg_ptr + 7'd19]};
                        
                        // Advance msg_ptr past the MoldUDP64 header
                        msg_ptr <= msg_ptr + 7'd20;
                        state <= STATE_PARSE_MSG;
                    end
                end

                STATE_PARSE_MSG: begin
                    if (remaining_msgs == 16'd0) begin
                        // All messages in this packet parsed, return to idle
                        state <= STATE_IDLE;
                    end else begin
                        // We need at least 2 bytes in the buffer to read the message length field
                        if (bytes_in_buf >= 7'd2) begin
                            // Extract Message Length (2 bytes, big-endian)
                            current_msg_len = {buf_mem[msg_ptr], buf_mem[msg_ptr + 7'd1]};

                            // Wait until the complete message (length field + message payload) is in the buffer
                            if (bytes_in_buf >= (current_msg_len + 7'd2)) begin
                                // Extract Message Type (1 byte, located at msg_ptr + 2)
                                current_msg_type = buf_mem[msg_ptr + 7'd2];

                                // Check if it is an Add Order (Type 'A') message
                                if (current_msg_type == 8'h41) begin // ASCII 'A'
                                    itch_msg_valid <= 1'b1;
                                    itch_msg_type <= 8'h41;
                                    
                                    // Extract fields based on ITCH 5.0 offsets (msg_ptr + 2 is Type 'A')
                                    // Stock Locate: Bytes 3-4 of the message
                                    itch_stock_locate <= {buf_mem[msg_ptr + 7'd3], buf_mem[msg_ptr + 7'd4]};
                                    
                                                                        // Order Reference ID: Bytes 11-18 of the message (64-bit big-endian)
                                    itch_order_id <= {
                                        buf_mem[msg_ptr + 7'd13], buf_mem[msg_ptr + 7'd14],
                                        buf_mem[msg_ptr + 7'd15], buf_mem[msg_ptr + 7'd16],
                                        buf_mem[msg_ptr + 7'd17], buf_mem[msg_ptr + 7'd18],
                                        buf_mem[msg_ptr + 7'd19], buf_mem[msg_ptr + 7'd20]
                                    };

                                    // Side: Byte 19 ('B' = Buy, 'S' = Sell)
                                    itch_side <= (buf_mem[msg_ptr + 7'd21] == 8'h53) ? 1'b1 : 1'b0;

                                    // Shares: Bytes 20-23 (32-bit big-endian)
                                    itch_shares <= {
                                        buf_mem[msg_ptr + 7'd22], buf_mem[msg_ptr + 7'd23],
                                        buf_mem[msg_ptr + 7'd24], buf_mem[msg_ptr + 7'd25]
                                    };

                                    // Stock Symbol: Bytes 24-31 (8 bytes ASCII)
                                    itch_symbol <= {
                                        buf_mem[msg_ptr + 7'd26], buf_mem[msg_ptr + 7'd27],
                                        buf_mem[msg_ptr + 7'd28], buf_mem[msg_ptr + 7'd29],
                                        buf_mem[msg_ptr + 7'd30], buf_mem[msg_ptr + 7'd31],
                                        buf_mem[msg_ptr + 7'd32], buf_mem[msg_ptr + 7'd33]
                                    };

                                    // Price: Bytes 32-35 (32-bit big-endian)
                                    itch_price <= {
                                        buf_mem[msg_ptr + 7'd34], buf_mem[msg_ptr + 7'd35],
                                        buf_mem[msg_ptr + 7'd36], buf_mem[msg_ptr + 7'd37]
                                    };
                                end

                                // Advance read pointer past this message (length field + message body)
                                msg_ptr <= msg_ptr + current_msg_len + 7'd2;
                                remaining_msgs <= remaining_msgs - 16'd1;
                            end
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
