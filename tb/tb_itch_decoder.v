// e:\Verilog_HFT_FPGA\tb\tb_itch_decoder.v
// Native Verilog testbench for itch_decoder.v

`timescale 1ns / 1ps

module tb_itch_decoder;

    reg clk;
    reg rst_n;

    // Input AXI-Stream
    reg [63:0] s_axis_tdata;
    reg [7:0]  s_axis_tkeep;
    reg        s_axis_tvalid;
    reg        s_axis_tlast;
    wire       s_axis_tready;

    // Outputs
    wire        itch_msg_valid;
    wire [7:0]  itch_msg_type;
    wire [63:0] itch_order_id;
    wire        itch_side;
    wire [31:0] itch_shares;
    wire [63:0] itch_symbol;
    wire [31:0] itch_price;
    wire [15:0] itch_stock_locate;

    // Instantiate DUT
    itch_decoder dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .itch_msg_valid(itch_msg_valid),
        .itch_msg_type(itch_msg_type),
        .itch_order_id(itch_order_id),
        .itch_side(itch_side),
        .itch_shares(itch_shares),
        .itch_symbol(itch_symbol),
        .itch_price(itch_price),
        .itch_stock_locate(itch_stock_locate)
    );

    // Clock Generation (156.25 MHz -> 6.4ns cycle)
    always #3.2 clk = ~clk;

    // Test Procedure
    initial begin
        clk = 0;
        rst_n = 0;
        s_axis_tdata = 0;
        s_axis_tkeep = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;

        // VCD dumping
        $dumpfile("waveform_itch.vcd");
        $dumpvars(0, tb_itch_decoder);

        #20;
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        #10;

        // ========================================================
        // TEST: Send MoldUDP64 packet with 1 ITCH Add Order Message
        // ========================================================
        $display("[TEST] Sending MoldUDP64 packet containing NASDAQ ITCH Add Order 'A' Message...");
        
        // Cycle 0: MoldUDP64 Session Active Bytes 0-7
        // Let's use Session Active = "SESSION123" (10 bytes: 53 45 53 53 49 4f 4e 31)
        // Word 0 (little endian): 31 4e 4f 49 53 53 45 53
        @(posedge clk);
        s_axis_tdata = 64'h314e4f4953534553;
        s_axis_tkeep = 8'hFF;
        s_axis_tvalid = 1;
        s_axis_tlast = 0;

        // Cycle 1: Session Active Bytes 8-9 (32 33), Sequence Number Bytes 10-15 (00 00 00 00 00 00)
        // Word 1: 00 00 00 00 00 00 33 32
        @(posedge clk);
        s_axis_tdata = 64'h0000000000003332;

        // Cycle 2: SeqNum Bytes 16-17 (00 01), MsgCount (00 01), MsgLength (00 24), MsgType ('A' = 41), Locate MSB (01)
        // SeqNum [7:6] = 00 01
        // MsgCount = 00 01
        // MsgLength = 00 24 (36 bytes)
        // MsgType = 41 ('A')
        // Locate MSB = 01 (part of Stock Locate: 01 c8 = 456)
        // Word 2: 01 41 24 00 01 00 01 00
        @(posedge clk);
        s_axis_tdata = 64'h0141240001000100;

        // Cycle 3: Locate LSB (c8), TrackNum (00 0c = 12), Timestamp (00 00 00 0f 42 40)
        // Locate LSB = c8
        // TrackNum = 00 0c
        // Timestamp [5:1] = 00 00 00 0f 42
        // Word 3: 42 0f 00 00 00 0c 00 c8
        @(posedge clk);
        s_axis_tdata = 64'h420f0000000c00c8;

        // Cycle 4: Timestamp LSB (40), Order Reference ID (00 00 00 00 3a de 68 b1)
        // Timestamp LSB = 40
        // Order ID [7:1] = 00 00 00 00 3a de 68
        // Word 4: 68 de 3a 00 00 00 00 40
        @(posedge clk);
        s_axis_tdata = 64'h68de3a0000000040;

        // Cycle 5: Order ID LSB (b1), Side ('B' = 42), Shares (00 00 01 f4 = 500), Stock Symbol [7:6] ('A' 'A')
        // Order ID LSB = b1
        // Side = 42
        // Shares = 00 00 01 f4
        // Symbol [7:6] = 41 41 ("AA")
        // Word 5: 41 41 f4 01 00 00 42 b1
        @(posedge clk);
        s_axis_tdata = 64'h4141f401000042b1;

        // Cycle 6: Stock Symbol [5:0] ('P' 'L' ' ' ' ' ' ' ' '), Price MSB (00)
        // Symbol [5:0] = 50 4c 20 20 20 20 ("PL    ")
        // Price MSB = 00
        // Word 6: 00 20 20 20 20 4c 50 41
        // Wait, Symbol [5:0] is 6 bytes. AAPL    is:
        // Byte 0: A (41) - Cycle 5
        // Byte 1: A (41) - Cycle 5
        // Byte 2: P (50) - Cycle 6
        // Byte 3: L (4c) - Cycle 6
        // Byte 4: ' ' (20) - Cycle 6
        // Byte 5: ' ' (20) - Cycle 6
        // Byte 6: ' ' (20) - Cycle 6
        // Byte 7: ' ' (20) - Cycle 6
        // Price [3:2] = 00 16 (since price is 00 16 e3 60)
        // So Cycle 6 word should contain:
        // tdata[47:0] = PL    ("50 4c 20 20 20 20" in bytes) -> little endian representation: 20 20 20 20 4c 50
        // tdata[63:48] = Price [3:2] = 00 16 -> represented as 16 00
        // Word 6: 16 00 20 20 20 20 4c 50
        // Let's verify: Yes, Price [3] = 00, Price [2] = 16.
        @(posedge clk);
        s_axis_tdata = 64'h1600202020204c50;

        // Cycle 7: Price LSB (e3 60), pad with 0s
        // Price [1:0] = e3 60 -> represented as 60 e3 in little endian
        // Word 7: 00 00 00 00 00 00 60 e3
        @(posedge clk);
        s_axis_tdata = 64'h00000000000060e3;
        s_axis_tkeep = 8'h03; // Only 2 bytes valid (total 58 bytes UDP payload)
        s_axis_tlast = 1;

        // Finish sending
        @(posedge clk);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        s_axis_tkeep = 0;

        // Wait to monitor output
        #100;
        $display("Simulation complete.");
        $finish;
    end

    // Monitor Output
    always @(posedge clk) begin
        if (itch_msg_valid) begin
            $display("[DECODER MONITOR] Message Valid!");
            $display("  Locate: %d", itch_stock_locate);
            $display("  Order ID: %d", itch_order_id);
            $display("  Side: %s", (itch_side == 1'b1) ? "SELL" : "BUY");
            $display("  Shares: %d", itch_shares);
            $display("  Symbol: %s", itch_symbol);
            $display("  Price: %d.%04d", itch_price / 10000, itch_price % 10000);
        end
    end

endmodule
