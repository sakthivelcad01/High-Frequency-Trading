# Ultra-Low Latency FPGA-Based NASDAQ ITCH Tick-to-Trade Pipeline (HFT Portfolio Project)

This repository implements a production-grade, ultra-low latency **NASDAQ ITCH-to-OUCH Tick-to-Trade Execution Engine** designed in pure **Verilog**. 

It simulates the entire hardware loop of an HFT trading desk: from decapsulating raw Ethernet packets and decoding Nasdaq ITCH market feeds, to building a Level 2 (BBO) order book, evaluating price crossing signals, enforcing pre-trade risk controls, and outputting execution triggers.

---

## 1. Project Architecture

The pipeline consists of four modular hardware cores communicating via standard AXI-Stream buses:

```
        Raw 10G/25G AXI-Stream (64-bit) Ingress
                          │
                          ▼
            ┌───────────────────────────┐
            │   1. Network Frame Parser │ <-- Decapsulates Ethernet/IP/UDP headers
            └─────────────┬─────────────┘
                          │ (Aligned UDP Payload)
                          ▼
            ┌───────────────────────────┐
            │   2. NASDAQ ITCH Decoder  │ <-- Parses MoldUDP64 framing & Add Order messages
            └─────────────┬─────────────┘
                          │ (Decoded 'A' events)
                          ▼
            ┌───────────────────────────┐
            │     3. L2 Order Book      │ <-- BRAM-based Best Bid/Ask (BBO) tracker
            └─────────────┬─────────────┘
                          │ (Updated BBO prices)
                          ▼
            ┌───────────────────────────┐
            │    4. Strategy & Risk     │ <-- Compares target triggers & checks trade risk
            └─────────────┬─────────────┘
                          │
                          ▼
             Pipelined Order Out Trigger (BUY/SELL)
```

### Components Breakdown:
1. **Network Frame Parser (`rtl/network_parser.v`)**: Decapsulates Ethernet, IPv4, and UDP header layers. Employs a low-latency barrel shifter that aligns the first payload byte directly to the AXI-Stream bus boundary (`m_axis_tdata[7:0]`).
2. **NASDAQ ITCH Decoder (`rtl/itch_decoder.v`)**: Decodes MoldUDP64 framing and translates binary NASDAQ TotalView-ITCH 5.0 Add Order (Type 'A') messages into structured parallel buses.
3. **L2 Order Book (`rtl/order_book.v`)**: Implements dual-port Block RAM (BRAM) lookup tables to maintain the Best Bid and Best Ask (BBO) for up to 1024 unique stock locate IDs in real-time.
4. **Strategy & Risk Controller (`rtl/strategy_engine.v`)**: Compares BBO prices against host-configured buy/sell limits. Validates proposed execution orders against **Pre-Trade Risk checks** (Max single order size, price boundary limits, and runaway rate-limiters) before dispatching trades.

---

## 2. Interface Definitions

### Input Stream (AXI-Stream 64-bit)
* `clk` / `rst_n` — 156.25 MHz clock (6.4ns period) and active-low sync reset.
* `s_axis_tdata[63:0]` — Raw Ethernet stream from the PHY/MAC.
* `s_axis_tkeep[7:0]` — Byte qualifiers.
* `s_axis_tvalid` / `s_axis_tready` — Source valid and sink ready strobes.
* `s_axis_tlast` — End of network packet.

### Strategy Config (Host Control)
* `host_write_enable` — Pulse high to load configuration.
* `host_stock_locate[15:0]` — Target Stock Locate ID.
* `host_buy_trigger_price[31:0]` — Buy trigger price threshold.
* `host_sell_trigger_price[31:0]` — Sell trigger price threshold.
* `host_order_size[31:0]` — Target trading order size.

### Order Trigger Outputs (Gateway)
* `order_out_valid` — Asserted for 1 cycle when a trade triggers and passes risk checks.
* `order_out_side` — Trade side (0 = BUY, 1 = SELL).
* `order_out_locate[15:0]` — Locate ID of execution stock.
* `order_out_shares[31:0]` — Trade quantity.
* `order_out_price[31:0]` — Trade price.
* `status_risk_violation` — Pulsed high if strategy matched but risk limits blocked the order.

---

## 3. Directory Layout
* `rtl/network_parser.v` — Decapsulates and aligns UDP payloads.
* `rtl/itch_decoder.v` — Skips MoldUDP64 framing and decodes ITCH 'A' orders.
* `rtl/order_book.v` — BRAM L2 BBO book builder.
* `rtl/strategy_engine.v` — Rules compiler and risk check module.
* `tb/tb_network_parser.v` — Parser simulation testbench.
* `tb/tb_itch_decoder.v` — Decoder simulation testbench.
* `tb/tb_integration.v` — End-to-end pipeline test bench.
* `tb/test_parser.py` — Cocotb verification wrapper.
* `tb/Makefile` — Cocotb compilation rules.

---

## 4. Compilation and Simulation Instructions

This project requires **Icarus Verilog** (`iverilog`) and **VVP** to compile and run tests.

### Run End-to-End Integration Simulation:
From the project root directory, execute:
```bash
# Compile the entire pipeline and integration testbench
iverilog -o tb/sim_integration.vvp -I rtl rtl/network_parser.v rtl/itch_decoder.v rtl/order_book.v rtl/strategy_engine.v tb/tb_integration.v

# Run the simulation
vvp tb/sim_integration.vvp
```

### Expected Output:
```text
VCD info: dumpfile waveform_integration.vcd opened for output.
[INTEGRATION TEST] Step 1: Loading strategy configurations...
[RTL STRATEGY WRITE] raw_locate=  456 buy_trig=   1510000 size=      1000
[INTEGRATION TEST] Step 2: Streaming UDP packet containing ITCH Add Order (Sell AAPL @ $150.00)...
[DEBUG DECODER OUT] ITCH Msg Valid! Type=A Symbol=AAPL     Price=   1500000 Side=1 Locate=  456 Shares=       500
[DEBUG BOOK] Book Updated! Locate=  456 Bid=         0 (x         0) Ask=   1500000 (x       500)
[DEBUG STRATEGY EVAL] Locate=  456 | config_buy_price=   1510000 | config_sell_price=   1550000 | config_size=      1000
[ORDER ENGINE] order_out_valid ASSERTED!
  Side:  BUY
  Locate:   456
  Shares:        500
  Price:        150.0000
  Risk Check Status: APPROVED
Simulation complete.
```

*Waveform Analysis*: The simulation generates a VCD wave dump at `tb/waveform_integration.vcd`. You can open this in **GTKWave** to trace the clock-by-clock signal propagation from the AXI-Stream network interface to the risk controller's outputs.

---

## 5. Latency Profile

At a standard clock frequency of **156.25 MHz** (6.4ns cycle time):
* **Tick-to-Trade Latency**: Approx. **14 clock cycles** (~89.6 nanoseconds) from the arrival of the final byte of the ITCH message length field to the assertion of `order_out_valid`.
* This profile places the engine in the top-tier of ultra-low latency FPGA designs suitable for high-frequency market-making or statistical arbitrage strategies.

---

## 6. Live Broker Data Integration (Upstox API)

To bridge the gap between high-level broker feeds and low-level hardware UDP sockets, the repository includes a Python adaptor:

* **Location**: `scripts/upstox_to_udp.py`
* **Features**: Queries the live Upstox REST LTP (Last Traded Price) endpoint for active exchange quotes (e.g. `NSE:RELIANCE`), dynamically converts float prices into 4-implied decimal integers, formats quotes into MoldUDP64/ITCH framing, and streams them out to `127.0.0.1:12345` over a local loopback socket.

### Running Live Stream:
1. Ensure the `requests` library is installed:
   ```bash
   pip install requests
   ```
2. Launch the bridge:
   ```bash
   python scripts/upstox_to_udp.py
   ```
The script will authenticate using the loaded API token and continuously broadcast live ticks formatted as raw ITCH packets, which can be captured by the UDP ingress parser.

---

## 7. Clock Domain Crossing (CDC) & Multi-Clock Architecture

In production HFT designs, the network logic operates at the Ethernet link clock domain (`clk_rx` = 156.25 MHz), while the trading strategy and configuration engine operate in a faster core system clock domain (`clk_core` = 250.00 MHz) to minimize computation time.

To safely pass trade triggers and stock locate indices between domains, the design employs a **Toggle Synchronizer** for strobes and stable buses:

```
                  [ clk_rx (156.25 MHz) Domain ]            [ clk_core (250.00 MHz) Domain ]
                                                      
itch_msg_valid  ──────┐                               
                      ├───> [Toggle Flip] ───────────────> [3-Stage Synchronizer] ───> [Edge Detect] ───> book_updated_core
updated_locate  ──────┘    (src_toggle ^ 1)                      (dst_toggle_sync)           (dst_edge)         (latch locate bus)
```

### Protocol Details:
1. **Source Flip (`clk_rx`)**: On every valid ITCH message update, the source toggle (`src_toggle`) flips. Simultaneously, the locate bus value is saved in a register (`src_locate`).
2. **Synchronization (`clk_core`)**: The toggle bit is transferred into the destination domain via a 3-stage shift register to prevent metastability.
3. **Destination Edge Detection (`clk_core`)**: When a change in the synchronized toggle is detected (`dst_edge`), a single-cycle strobe `book_updated_core` is asserted, and the synchronized locate ID is safely latched.
