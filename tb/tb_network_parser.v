// e:\Verilog_HFT_FPGA\tb\tb_network_parser.v
// Native Verilog testbench for network_parser.v

`timescale 1ns / 1ps

module tb_network_parser;

    reg clk;
    reg rst_n;

    // Input AXI-Stream
    reg [63:0] s_axis_tdata;
    reg [7:0]  s_axis_tkeep;
    reg        s_axis_tvalid;
    reg        s_axis_tlast;
    wire       s_axis_tready;

    // Output AXI-Stream
    wire [63:0] m_axis_tdata;
    wire [7:0]  m_axis_tkeep;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;
    reg         m_axis_tready;

    // Status
    wire status_valid_packet;
    wire status_error;

    // Instantiate DUT
    network_parser #(
        .TARGET_UDP_PORT(16'h3039) // 12345
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready),
        .status_valid_packet(status_valid_packet),
        .status_error(status_error)
    );

    // Clock Generation (156.25 MHz -> 6.4ns cycle)
    always #3.2 clk = ~clk;

    // Test Procedure
    initial begin
        // Initialize signals
        clk = 0;
        rst_n = 0;
        s_axis_tdata = 0;
        s_axis_tkeep = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1;

        // VCD dumping
        $dumpfile("waveform.vcd");
        $dumpvars(0, tb_network_parser);

        // Reset
        #20;
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        #10;

        // ==========================================
        // TEST 1: Valid UDP Packet with 10 bytes payload
        // ==========================================
        $display("[TEST 1] Sending valid UDP packet (10 bytes payload: AA BB CC DD EE FF 01 02 03 04)");
        
        // Cycle 0: Dest MAC [5:0], Src MAC [5:4]
        // Dest: 00 11 22 33 44 55
        // Src: 66 77 88 99 aa bb -> Src[5:4] = 66 77
        // Word 0 (hex, little endian byte order): 77 66 55 44 33 22 11 00
        @(posedge clk);
        s_axis_tdata = 64'h7766554433221100;
        s_axis_tkeep = 8'hFF;
        s_axis_tvalid = 1;
        s_axis_tlast = 0;

        // Cycle 1: Src MAC [3:0], EtherType, Version/IHL, DSCP
        // Src[3:0] = 88 99 aa bb
        // EtherType = 08 00 (represented as 00 08 in little-endian order for index 4,5)
        // IP Version/IHL = 45, DSCP = 00
        // Word 1: 00 45 00 08 bb aa 99 88
        @(posedge clk);
        s_axis_tdata = 64'h00450008bbaa9988;

        // Cycle 2: IP TotLen, IP ID, IP Flags/Frag, TTL, IP Proto
        // IP TotLen = 20 + 8 + 10 = 38 (0x0026) -> Byte 16=00, Byte 17=26. Word index 0,1: 26 00
        // IP ID = 12 34 -> Word index 2,3: 34 12
        // Flags = 00 00 -> Word index 4,5: 00 00
        // TTL = 40 (0x40) -> Word index 6: 40
        // Proto = 17 (0x11, UDP) -> Word index 7: 11
        // Word 2: 11 40 00 00 34 12 00 26 (little endian)
        // Wait, IP TotLen in big-endian is 0x0026, so Byte 16 (first) is 0x00, Byte 17 (second) is 0x26.
        // Therefore, on s_axis_tdata: tdata[7:0] = Byte 16 = 0x00, tdata[15:8] = Byte 17 = 0x26.
        // So `{tdata[15:8], tdata[7:0]} = 16'h2600`.
        // Word 2: 11 40 00 00 34 12 26 00
        @(posedge clk);
        s_axis_tdata = 64'h1140000034122600;

        // Cycle 3: IP Checksum, Src IP, Dst IP [3:2]
        // Checksum = 00 00
        // Src IP = 192.168.1.10 -> c0 a8 01 0a -> index 2,3,4,5: 0a 01 a8 c0
        // Dst IP = 224.0.0.1 -> e0 00 00 01 -> Dst IP[3:2] = e0 00 -> index 6,7: 00 e0
        // Word 3: 00 e0 0a 01 a8 c0 00 00
        @(posedge clk);
        s_axis_tdata = 64'h00e00a01a8c00000;

        // Cycle 4: Dst IP [1:0], UDP Src Port, UDP Dst Port, UDP Length
        // Dst IP[1:0] = 00 01 -> index 0,1: 01 00
        // Src Port = 12344 (0x3038) -> index 2,3: 38 30
        // Dst Port = 12345 (0x3039) -> index 4,5: 39 30
        // UDP Length = 8 + 10 = 18 (0x0012) -> index 6,7: 12 00
        // Word 4: 12 00 39 30 38 30 00 01
        @(posedge clk);
        s_axis_tdata = 64'h1200393038300001;

        // Cycle 5: UDP Checksum, Payload [5:0]
        // Checksum = 00 00 -> index 0,1
        // Payload [5:0] = aa bb cc dd ee ff -> index 2,3,4,5,6,7
        // Word 5: ff ee dd cc bb aa 00 00
        @(posedge clk);
        s_axis_tdata = 64'hffeeddccbbaa0000;

        // Cycle 6: Payload [9:6], pad with 0s
        // Payload [9:6] = 01 02 03 04 -> index 0,1,2,3
        // Word 6: 00 00 00 00 04 03 02 01
        @(posedge clk);
        s_axis_tdata = 64'h0000000004030201;
        s_axis_tkeep = 8'h0F; // Only 4 bytes valid in this cycle (total 10 bytes payload)
        s_axis_tlast = 1;

        // Cycle 7: Finish
        @(posedge clk);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        s_axis_tkeep = 0;

        // Wait to verify output
        #100;

        // ==========================================
        // TEST 2: Invalid UDP Packet (Wrong Port)
        // ==========================================
        $display("[TEST 2] Sending UDP packet with wrong destination port (9999 instead of 12345)");
        
        @(posedge clk);
        s_axis_tdata = 64'h7766554433221100; // MACs
        s_axis_tkeep = 8'hFF;
        s_axis_tvalid = 1;

        @(posedge clk);
        s_axis_tdata = 64'h00450008bbaa9988; // MACs + IPv4 type

        @(posedge clk);
        s_axis_tdata = 64'h1140000034122600; // TTL, Proto

        @(posedge clk);
        s_axis_tdata = 64'h00e00a01a8c00000; // IPs

        // UDP Dst Port = 9999 (0x270f) -> index 4,5: 0f 27
        // Word 4: 12 00 0f 27 38 30 00 01
        @(posedge clk);
        s_axis_tdata = 64'h12000f2738300001;

        @(posedge clk);
        s_axis_tdata = 64'hffeeddccbbaa0000; // Checksum + Payload

        @(posedge clk);
        s_axis_tdata = 64'h0000000004030201; // Payload end
        s_axis_tkeep = 8'h0F;
        s_axis_tlast = 1;

        @(posedge clk);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;

        #100;
        $display("Simulation complete.");
        $finish;
    end

    // Monitor Output
    always @(posedge clk) begin
        if (m_axis_tvalid) begin
            $display("[MONITOR] Out Data: %h, Keep: %b, Last: %b", m_axis_tdata, m_axis_tkeep, m_axis_tlast);
        end
        if (status_error) begin
            $display("[MONITOR] Error status high!");
        end
    end

endmodule
