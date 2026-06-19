// e:\Verilog_HFT_FPGA\tb\tb_integration.v
// Top-level native Verilog integration testbench verifying the multi-clock HFT FPGA pipeline with Async FIFO CDC.

`timescale 1ns / 1ps

module tb_integration;

    // Clocks and Resets
    reg clk_rx;
    reg rst_rx_n;
    reg clk_core;
    reg rst_core_n;

    // Raw AXI-Stream inputs to the Network Parser (clk_rx domain)
    reg [63:0] s_axis_tdata;
    reg [7:0]  s_axis_tkeep;
    reg        s_axis_tvalid;
    reg        s_axis_tlast;
    wire       s_axis_tready;

    // Parser to Decoder signals (clk_rx domain)
    wire [63:0] parsed_tdata;
    wire [7:0]  parsed_tkeep;
    wire        parsed_tvalid;
    wire        parsed_tlast;
    wire        parsed_tready;

    // Decoder to Book signals (clk_rx domain)
    wire        itch_msg_valid;
    wire [7:0]  itch_msg_type;
    wire [15:0] itch_stock_locate;
    wire        itch_side;
    wire [31:0] itch_shares;
    wire [63:0] itch_symbol;
    wire [31:0] itch_price;
    wire [15:0] itch_stock_locate_dec;

    // FIFO Wiring Signals (CDC Boundary)
    wire [80:0] fifo_wdata;
    wire [80:0] fifo_rdata;
    wire        fifo_winc;
    wire        fifo_rinc;
    wire        fifo_wfull;
    wire        fifo_rempty;

    assign fifo_wdata = {itch_stock_locate_dec, itch_side, itch_shares, itch_price};
    assign fifo_winc  = itch_msg_valid && (itch_msg_type == 8'h41);
    assign fifo_rinc  = !fifo_rempty;

    // Book to Strategy signals (clk_core domain)
    wire [15:0] read_stock_locate;
    wire [31:0] best_bid_price;
    wire [31:0] best_bid_shares;
    wire [31:0] best_ask_price;
    wire [31:0] best_ask_shares;
    wire        book_updated;
    wire [15:0] updated_stock_locate;

    // Host Config interface for Strategy Engine (clk_core domain)
    reg         host_write_enable;
    reg  [15:0] host_stock_locate;
    reg  [31:0] host_buy_trigger_price;
    reg  [31:0] host_sell_trigger_price;
    reg  [31:0] host_order_size;
    reg  [63:0] host_stock_symbol;

    // Output Gateway orders (clk_core domain)
    wire        order_out_valid;
    wire        order_out_side;
    wire [15:0] order_out_locate;
    wire [31:0] order_out_shares;
    wire [31:0] order_out_price;
    wire [63:0] order_out_symbol;
    wire        status_risk_violation;
    wire [31:0] stats_trades_executed;

    // OUCH Encoder AXI-Stream interface (clk_core domain)
    wire [63:0] ouch_tdata;
    wire [7:0]  ouch_tkeep;
    wire        ouch_tvalid;
    wire        ouch_tlast;
    reg         ouch_tready;
    wire        ouch_busy;

    // 1. Instantiate Network Parser (clocked by clk_rx)
    network_parser #(
        .TARGET_UDP_PORT(16'h3039) // 12345
    ) parser_inst (
        .clk(clk_rx),
        .rst_n(rst_rx_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(parsed_tdata),
        .m_axis_tkeep(parsed_tkeep),
        .m_axis_tvalid(parsed_tvalid),
        .m_axis_tlast(parsed_tlast),
        .m_axis_tready(parsed_tready),
        .status_valid_packet(),
        .status_error()
    );

    // 2. Instantiate ITCH Decoder (clocked by clk_rx)
    itch_decoder decoder_inst (
        .clk(clk_rx),
        .rst_n(rst_rx_n),
        .s_axis_tdata(parsed_tdata),
        .s_axis_tkeep(parsed_tkeep),
        .s_axis_tvalid(parsed_tvalid),
        .s_axis_tlast(parsed_tlast),
        .s_axis_tready(parsed_tready),
        .itch_msg_valid(itch_msg_valid),
        .itch_msg_type(itch_msg_type),
        .itch_order_id(),
        .itch_side(itch_side),
        .itch_shares(itch_shares),
        .itch_symbol(itch_symbol),
        .itch_price(itch_price),
        .itch_stock_locate(itch_stock_locate_dec)
    );

    // 3. Instantiate Asynchronous Gray-Code FIFO (CDC boundary)
    async_fifo #(
        .WIDTH(81),
        .ADDR_WIDTH(4),
        .DEPTH(16)
    ) cdc_fifo_inst (
        .wclk(clk_rx),
        .wrst_n(rst_rx_n),
        .winc(fifo_winc),
        .wdata(fifo_wdata),
        .wfull(fifo_wfull),
        
        .rclk(clk_core),
        .rrst_n(rst_core_n),
        .rinc(fifo_rinc),
        .rdata(fifo_rdata),
        .rempty(fifo_rempty)
    );

    // Link read index of Book to Strategy query locate index
    assign read_stock_locate = updated_stock_locate;

    // 4. Instantiate L2 Order Book (clocked entirely by clk_core)
    order_book book_inst (
        .clk(clk_core),
        .rst_n(rst_core_n),
        .itch_msg_valid(!fifo_rempty),
        .itch_stock_locate(fifo_rdata[80:65]),
        .itch_side(fifo_rdata[64]),
        .itch_shares(fifo_rdata[63:32]),
        .itch_price(fifo_rdata[31:0]),
        
        .read_stock_locate(read_stock_locate),
        .out_best_bid_price(best_bid_price),
        .out_best_bid_shares(best_bid_shares),
        .out_best_ask_price(best_ask_price),
        .out_best_ask_shares(best_ask_shares),
        .book_updated(book_updated),
        .updated_stock_locate(updated_stock_locate)
    );

    // 5. Instantiate Strategy Engine & Risk check (clocked by clk_core)
    strategy_engine strategy_inst (
        .clk(clk_core),
        .rst_n(rst_core_n),
        .host_write_enable(host_write_enable),
        .host_stock_locate(host_stock_locate),
        .host_buy_trigger_price(host_buy_trigger_price),
        .host_sell_trigger_price(host_sell_trigger_price),
        .host_order_size(host_order_size),
        .host_stock_symbol(host_stock_symbol),
        .book_updated(book_updated),
        .updated_stock_locate(updated_stock_locate),
        .best_bid_price(best_bid_price),
        .best_bid_shares(best_bid_shares),
        .best_ask_price(best_ask_price),
        .best_ask_shares(best_ask_shares),
        .order_out_valid(order_out_valid),
        .order_out_side(order_out_side),
        .order_out_locate(order_out_locate),
        .order_out_shares(order_out_shares),
        .order_out_price(order_out_price),
        .order_out_symbol(order_out_symbol),
        .status_risk_violation(status_risk_violation),
        .stats_trades_executed(stats_trades_executed)
    );

    // 6. Instantiate OUCH Encoder (clocked by clk_core)
    ouch_encoder ouch_encoder_inst (
        .clk(clk_core),
        .rst_n(rst_core_n),
        .order_out_valid(order_out_valid),
        .order_out_side(order_out_side),
        .order_out_locate(order_out_locate),
        .order_out_symbol(order_out_symbol),
        .order_out_shares(order_out_shares),
        .order_out_price(order_out_price),
        .m_axis_ouch_tdata(ouch_tdata),
        .m_axis_ouch_tkeep(ouch_tkeep),
        .m_axis_ouch_tvalid(ouch_tvalid),
        .m_axis_ouch_tlast(ouch_tlast),
        .m_axis_ouch_tready(ouch_tready),
        .ouch_busy(ouch_busy)
    );

    // Clock Generators
    // clk_rx: 156.25 MHz (6.4ns period)
    always #3.2 clk_rx = ~clk_rx;
    // clk_core: 250.00 MHz (4.0ns period)
    always #2.0 clk_core = ~clk_core;

    // Test sequence
    initial begin
        clk_rx = 0;
        clk_core = 0;
        rst_rx_n = 0;
        rst_core_n = 0;
        s_axis_tdata = 0;
        s_axis_tkeep = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        host_write_enable = 0;
        host_stock_locate = 0;
        host_buy_trigger_price = 0;
        host_sell_trigger_price = 0;
        host_order_size = 0;
        host_stock_symbol = 64'd0;
        ouch_tready = 1;

        // Waveform setup
        $dumpfile("waveform_integration.vcd");
        $dumpvars(0, tb_integration);

        #20;
        @(posedge clk_rx);
        rst_rx_n = 1;
        @(posedge clk_core);
        rst_core_n = 1;
        #10;

        // ==========================================================
        // STEP 1: Configure Strategy Engine from Host (clk_core domain)
        // Config: Locate ID = 456 (AAPL). Target Buy Price = $151.00.
        // Target order size = 1000 shares.
        // ==========================================================
        $display("[INTEGRATION TEST] Step 1: Loading strategy configurations...");
        @(posedge clk_core);
        host_write_enable = 1;
        host_stock_locate = 16'd456;
        host_buy_trigger_price = 32'd1510000;  // $151.0000
        host_sell_trigger_price = 32'd1550000; // $155.0000
        host_order_size = 32'd1000;
        host_stock_symbol = 64'h4141504c20202020; // "AAPL    " in big-endian ASCII
        @(posedge clk_core);
        host_write_enable = 0;

        // ==========================================================
        // STEP 2: Stream UDP packet containing Add Order ITCH Sell (clk_rx domain)
        // Packet: AAPL (Locate 456) Ask price is $150.00 (implied cross).
        // ==========================================================
        $display("[INTEGRATION TEST] Step 2: Streaming UDP packet containing ITCH Add Order (Sell AAPL @ $150.00)...");

        // Ethernet Destination MAC / Source MAC bytes 0-7
        @(posedge clk_rx);
        s_axis_tdata = 64'h7766554433221100;
        s_axis_tkeep = 8'hFF;
        s_axis_tvalid = 1;
        s_axis_tlast = 0;

        // Cycle 1: MAC bytes 8-11, EtherType (0800), IP version/length starting
        @(posedge clk_rx);
        s_axis_tdata = 64'h00450008bbaa9988;

        // Cycle 2: IP total length (20 + 8 + 58 = 86 bytes -> 0x0056), ID, Flags, Proto (UDP = 0x11)
        // Length network byte order: 00 56 -> little endian indices 0,1: 56 00
        @(posedge clk_rx);
        s_axis_tdata = 64'h1140000034125600;

        // Cycle 3: IP Checksum, Src IP, Dst IP [3:2]
        @(posedge clk_rx);
        s_axis_tdata = 64'h00e00a01a8c00000;

        // Cycle 4: Dst IP [1:0], UDP Ports (Src: 12344, Dst: 12345), UDP Length (8 + 58 = 66 -> 0x0042)
        // Dst port: 3039 (12345) -> little endian: 39 30
        @(posedge clk_rx);
        s_axis_tdata = 64'h4200393038300001;

        // Cycle 5: UDP Checksum, MoldUDP64 Session ID [5:0] (S E S S I O)
        @(posedge clk_rx);
        s_axis_tdata = 64'h4f49535345530000;

        // Cycle 6: MoldUDP64 Session ID [9:6] (N 1 2 3), Sequence Number [3:0]
        @(posedge clk_rx);
        s_axis_tdata = 64'h000000003332314e;

        // Cycle 7: SeqNum [7:4] (00 00 00 01), Message Count (00 01), Message Length (00 24)
        @(posedge clk_rx);
        s_axis_tdata = 64'h2400010001000000;

        // Cycle 8: Message Type ('A' = 41), Stock Locate MSB (01), Locate LSB (c8 -> 456), TrackNum (00 0c)
        // Timestamp MSB (00 00 00)
        @(posedge clk_rx);
        s_axis_tdata = 64'h0000000c00c80141;

        // Cycle 9: Timestamp [4:0] (00 0f 42 40), Order Reference ID [7:5] (00 00 00)
        @(posedge clk_rx);
        s_axis_tdata = 64'h3a0000000040420f;

        // Cycle 10: Order ID [4:0] (00 3a de 68 b1), Side (53 = 'S' for Sell), Shares [3:2] (00 00)
        @(posedge clk_rx);
        s_axis_tdata = 64'hf401000053b168de;

        // Cycle 11: Shares [1:0] (01 f4 = 500 shares), Stock Symbol ("AAPL    ")
        @(posedge clk_rx);
        s_axis_tdata = 64'h202020204c504141;

        // Cycle 12: Stock Symbol [7:6] (' ' ' '), Price [3:0] (00 16 e3 60 = 1500000)
        @(posedge clk_rx);
        s_axis_tdata = 64'h0000000060e31600;
        s_axis_tkeep = 8'h0F; // Only 4 bytes valid in this last cycle (price bytes)
        s_axis_tlast = 1;

        // Finish sending
        @(posedge clk_rx);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        s_axis_tkeep = 0;

        // Wait to monitor order execution
        #300;
        $display("[INTEGRATION TEST] Simulation complete.");
        $finish;
    end

    // Monitor OUCH Encoder Outbound Stream (clk_core domain)
    always @(posedge clk_core) begin
        if (ouch_tvalid && ouch_tready) begin
            $display("[OUCH MONITOR] Cycle Data: %h | Keep: %b | Last: %b", ouch_tdata, ouch_tkeep, ouch_tlast);
        end
    end

    // Trace states
    always @(posedge clk_core) begin
        if (host_write_enable) begin
            $display("[DEBUG WRITE] host_write_enable=%b | locate=%d | buy_trig=%d | sell_trig=%d | size=%d | symbol=%s",
                host_write_enable, host_stock_locate, host_buy_trigger_price, host_sell_trigger_price, host_order_size, host_stock_symbol);
        end
        if (decoder_inst.s_axis_tvalid && decoder_inst.s_axis_tready) begin
            $display("[DEBUG DECODER] RX tdata=%h keep=%b last=%b | write_ptr=%d msg_ptr=%d bytes_in_buf=%d state=%d",
                decoder_inst.s_axis_tdata, decoder_inst.s_axis_tkeep, decoder_inst.s_axis_tlast,
                decoder_inst.write_ptr, decoder_inst.msg_ptr, decoder_inst.bytes_in_buf, decoder_inst.state);
        end
        if (decoder_inst.state == 2'd2) begin // STATE_PARSE_MSG
            $display("[DEBUG DECODER STATE] msg_ptr=%d bytes_in_buf=%d remaining_msgs=%d",
                decoder_inst.msg_ptr, decoder_inst.bytes_in_buf, decoder_inst.remaining_msgs);
        end
        if (itch_msg_valid) begin
            $display("[DEBUG DECODER OUT] ITCH Msg Valid! Type=%c Symbol=%s Price=%d Side=%b Locate=%d Shares=%d",
                itch_msg_type, itch_symbol, itch_price, itch_side, itch_stock_locate_dec, itch_shares);
        end
        if (fifo_winc && !fifo_wfull) begin
            $display("[DEBUG FIFO] Pushed packet to Async FIFO: Locate=%d Price=%d Shares=%d Side=%b",
                itch_stock_locate_dec, itch_price, itch_shares, itch_side);
        end
        if (fifo_rinc && !fifo_rempty) begin
            $display("[DEBUG FIFO] Popped packet from Async FIFO: Locate=%d Price=%d Shares=%d Side=%b",
                fifo_rdata[80:65], fifo_rdata[31:0], fifo_rdata[63:32], fifo_rdata[64]);
        end
        if (book_updated) begin
            $display("[DEBUG BOOK] Book Updated! Locate=%d Bid=%d (x%d) Ask=%d (x%d)",
                updated_stock_locate, best_bid_price, best_bid_shares, best_ask_price, best_ask_shares);
            $display("[DEBUG STRATEGY EVAL] Locate=%d | config_buy_price=%d | config_sell_price=%d | config_size=%d",
                updated_stock_locate, strategy_inst.target_buy_trigger[updated_stock_locate[9:0]], 
                strategy_inst.target_sell_trigger[updated_stock_locate[9:0]], 
                strategy_inst.target_order_size[updated_stock_locate[9:0]]);
        end
        if (order_out_valid) begin
            $display("[ORDER ENGINE] order_out_valid ASSERTED!");
            $display("  Side: %s", (order_out_side == 1'b1) ? "SELL" : "BUY");
            $display("  Locate: %d", order_out_locate);
            $display("  Symbol: %s", order_out_symbol);
            $display("  Shares: %d", order_out_shares);
            $display("  Price: %d.%04d", order_out_price / 10000, order_out_price % 10000);
            $display("  Risk Check Status: APPROVED");
        end
        if (status_risk_violation) begin
            $display("[ORDER ENGINE] RISK VIOLATION BLOCKED ORDER!");
        end
    end

endmodule
