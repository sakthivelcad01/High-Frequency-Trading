// e:\Verilog_HFT_FPGA\rtl\network_parser.v
// Ultra-Low Latency 10G/25G Ethernet UDP Parser in Verilog-2001
// Aligns UDP payload to AXI-Stream word boundary.

`timescale 1ns / 1ps

module network_parser #(
    parameter [15:0] TARGET_UDP_PORT = 16'h3039 // Default: 12345 (0x3039)
) (
    input wire clk,
    input wire rst_n,

    // Input AXI-Stream from MAC (64-bit, 156.25 MHz / 322.26 MHz)
    input wire [63:0] s_axis_tdata,
    input wire [7:0]  s_axis_tkeep,
    input wire        s_axis_tvalid,
    input wire        s_axis_tlast,
    output reg        s_axis_tready,

    // Output AXI-Stream of aligned UDP Payload
    output reg [63:0] m_axis_tdata,
    output reg [7:0]  m_axis_tkeep,
    output reg        m_axis_tvalid,
    output reg        m_axis_tlast,
    input wire        m_axis_tready,

    // Status Signals
    output reg        status_valid_packet,
    output reg        status_error
);

    // States definition
    localparam STATE_IDLE    = 3'd0;
    localparam STATE_HDR     = 3'd1;
    localparam STATE_PAYLOAD = 3'd2;
    localparam STATE_EXTRA   = 3'd3;
    localparam STATE_DROP    = 3'd4;

    reg [2:0] state;
    reg [2:0] cycle_cnt;

    // Registers to store previous cycle data for alignment shifting
    reg [63:0] prev_tdata;
    reg [7:0]  prev_tkeep_mapped;

    // Target UDP Port in Network Byte Order
    wire [15:0] target_port_nbo = {TARGET_UDP_PORT[7:0], TARGET_UDP_PORT[15:8]};

    // Ready signal handling
    always @(*) begin
        if (state == STATE_EXTRA)
            s_axis_tready = 1'b0; // Cannot accept new data while flushing extra cycle
        else
            s_axis_tready = m_axis_tready;
    end

    // Main Sequential Block
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            cycle_cnt <= 3'd0;
            prev_tdata <= 64'd0;
            prev_tkeep_mapped <= 8'd0;
            m_axis_tdata <= 64'd0;
            m_axis_tkeep <= 8'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;
            status_valid_packet <= 1'b0;
            status_error <= 1'b0;
        end else begin
            // Default strobe outputs
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    status_valid_packet <= 1'b0;
                    status_error <= 1'b0;
                    cycle_cnt <= 3'd0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        state <= STATE_HDR;
                        cycle_cnt <= 3'd1;
                    end
                end

                STATE_HDR: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        cycle_cnt <= cycle_cnt + 3'd1;

                        // Check for early packet termination
                        if (s_axis_tlast && (cycle_cnt < 3'd5)) begin
                            status_error <= 1'b1;
                            state <= STATE_IDLE;
                        end else begin
                            case (cycle_cnt)
                                3'd1: begin
                                    // Byte 12-13: EtherType (expect 0x0800 for IPv4)
                                    // Byte 14: Version & IHL (expect 0x45)
                                    if (s_axis_tdata[47:32] != 16'h0008 || s_axis_tdata[55:48] != 8'h45) begin
                                        state <= STATE_DROP;
                                    end
                                end
                                3'd2: begin
                                    // Byte 23: Protocol (expect 0x11 for UDP)
                                    if (s_axis_tdata[63:56] != 8'h11) begin
                                        state <= STATE_DROP;
                                    end
                                end
                                3'd3: begin
                                    // Can extract/check IP addresses here if needed
                                end
                                3'd4: begin
                                    // Byte 36-37: UDP Dest Port
                                    if (s_axis_tdata[47:32] != target_port_nbo) begin
                                        state <= STATE_DROP;
                                    end
                                end
                                3'd5: begin
                                    // Byte 40-41: UDP Checksum
                                    // Byte 42-47: First 6 bytes of UDP payload
                                    prev_tdata <= s_axis_tdata;
                                    status_valid_packet <= 1'b1;
                                    
                                    if (s_axis_tlast) begin
                                        // Extremely short UDP packet ending in cycle 5
                                        // Payload length is <= 6 bytes
                                        m_axis_tvalid <= 1'b1;
                                        m_axis_tlast <= 1'b1;
                                        
                                        // Calculate output keep: payload starts at Byte 2 of s_axis_tdata
                                        // If tkeep has N bytes valid:
                                        // payload size = N - 2
                                        if (s_axis_tkeep[2] == 0) begin
                                            // Malformed: tkeep indicates less than 3 bytes valid (no payload)
                                            m_axis_tvalid <= 1'b0;
                                            status_error <= 1'b1;
                                        end else begin
                                            m_axis_tdata <= {16'h0000, s_axis_tdata[63:16]};
                                            m_axis_tkeep <= (s_axis_tkeep >> 2);
                                        end
                                        state <= STATE_IDLE;
                                    end else begin
                                        state <= STATE_PAYLOAD;
                                    end
                                end
                                default: state <= STATE_DROP;
                            endcase
                        end
                    end
                end

                STATE_PAYLOAD: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        prev_tdata <= s_axis_tdata;
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata <= {s_axis_tdata[15:0], prev_tdata[63:16]};

                        if (s_axis_tlast) begin
                            // If only 1 or 2 bytes are valid in this final cycle
                            if (s_axis_tkeep[2] == 1'b0) begin
                                m_axis_tlast <= 1'b1;
                                m_axis_tkeep <= s_axis_tkeep[1] ? 8'hFF : 8'h7F;
                                state <= STATE_IDLE;
                            end else begin
                                // 3 to 8 bytes valid: we need an extra cycle to flush the remainder
                                m_axis_tlast <= 1'b0;
                                m_axis_tkeep <= 8'hFF;
                                prev_tkeep_mapped <= (s_axis_tkeep >> 2);
                                state <= STATE_EXTRA;
                            end
                        end else begin
                            m_axis_tkeep <= 8'hFF;
                        end
                    end
                end

                STATE_EXTRA: begin
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast <= 1'b1;
                        m_axis_tdata <= {16'h0000, prev_tdata[63:16]};
                        m_axis_tkeep <= prev_tkeep_mapped;
                        state <= STATE_IDLE;
                    end
                end

                STATE_DROP: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (s_axis_tlast) begin
                            state <= STATE_IDLE;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
