# e:/Verilog_HFT_FPGA/tb/test_parser.py
# Cocotb verification testbench for network_parser.v

import cocotb
from cocotb.triggers import Timer, RisingEdge, FallingEdge
from cocotb.clock import Clock

def make_ethernet_udp_packet(payload, dest_port=12345, ether_type=[0x08, 0x00], ip_proto=0x11):
    # Dest MAC (6 bytes)
    pkt = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
    # Src MAC (6 bytes)
    pkt += [0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb]
    # EtherType (2 bytes)
    pkt += ether_type
    # IP Header (20 bytes)
    pkt += [
        0x45, 0x00,                # Version/IHL, DSCP/ECN
        0x00, 20 + 8 + len(payload), # Total Length (will be split below)
        0x12, 0x34,                # Ident
        0x00, 0x00,                # Flags & Fragment
        0x40,                      # TTL
        ip_proto,                  # Protocol (0x11 = UDP)
        0x00, 0x00,                # Checksum
        192, 168, 1, 10,           # Source IP
        224, 0, 0, 1               # Destination IP
    ]
    # Adjust total length byte indexing
    total_len = 20 + 8 + len(payload)
    pkt[16] = (total_len >> 8) & 0xFF
    pkt[17] = total_len & 0xFF

    # UDP Header (8 bytes)
    pkt += [
        0x30, 0x38,                # Source Port (12344)
        (dest_port >> 8) & 0xFF,   # Dest Port
        dest_port & 0xFF,
        0x00, 8 + len(payload),    # UDP Length
        0x00, 0x00                 # UDP Checksum
    ]
    # Adjust UDP length bytes
    udp_len = 8 + len(payload)
    pkt[38] = (udp_len >> 8) & 0xFF
    pkt[39] = udp_len & 0xFF

    # Payload
    pkt += payload
    return pkt

def chunk_packet(pkt_bytes):
    chunks = []
    tkeep = []
    tlast = []
    for i in range(0, len(pkt_bytes), 8):
        chunk = pkt_bytes[i:i+8]
        val = 0
        keep_val = 0
        for b_idx, b in enumerate(chunk):
            val |= (b << (8 * b_idx))
            keep_val |= (1 << b_idx)
        chunks.append(val)
        tkeep.append(keep_val)
        tlast.append(0)
    if tlast:
        tlast[-1] = 1
    return chunks, tkeep, tlast

async def send_packet(dut, pkt_bytes):
    chunks, tkeep, tlast = chunk_packet(pkt_bytes)
    for c, k, l in zip(chunks, tkeep, tlast):
        dut.s_axis_tdata.value = c
        dut.s_axis_tkeep.value = k
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = l
        await RisingEdge(dut.clk)
        while dut.s_axis_tready.value == 0:
            await RisingEdge(dut.clk)
    
    # Idle state after packet transmission
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0

async def setup_dut(dut):
    # Start clock
    cocotb.start_soon(Clock(dut.clk, 6.4, units="ns").start()) # ~156.25 MHz
    
    # Apply reset
    dut.rst_n.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    
    await Timer(20, units="ns")
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

@cocotb.test()
async def test_valid_packet(dut):
    """Verify that a valid IPv4 UDP packet targeting the port is parsed and aligned correctly."""
    await setup_dut(dut)

    payload = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x01, 0x02, 0x03, 0x04] # 10 bytes
    pkt = make_ethernet_udp_packet(payload)
    
    # Start monitor task
    monitor_task = cocotb.start_soon(capture_payload(dut))
    
    await send_packet(dut, pkt)
    await Timer(50, units="ns") # Allow pipeline to drain
    
    captured = monitor_task.result()
    assert len(captured) == len(payload), f"Expected {len(payload)} bytes, got {len(captured)}"
    assert captured == payload, f"Expected {payload}, got {captured}"
    assert dut.status_valid_packet.value == 1, "status_valid_packet should be high"
    assert dut.status_error.value == 0, "status_error should be low"

@cocotb.test()
async def test_wrong_ether_type(dut):
    """Verify that packets with incorrect EtherType are ignored."""
    await setup_dut(dut)
    
    payload = [1, 2, 3, 4, 5]
    # Set EtherType to 0x0806 (ARP) instead of 0x0800
    pkt = make_ethernet_udp_packet(payload, ether_type=[0x08, 0x06])
    
    monitor_task = cocotb.start_soon(capture_payload(dut))
    await send_packet(dut, pkt)
    await Timer(50, units="ns")
    
    captured = monitor_task.result()
    assert len(captured) == 0, "No payload should be output for wrong EtherType"
    assert dut.status_valid_packet.value == 0, "status_valid_packet should remain low"

@cocotb.test()
async def test_wrong_udp_port(dut):
    """Verify that packets targeting non-configured UDP ports are dropped."""
    await setup_dut(dut)
    
    payload = [1, 2, 3, 4, 5]
    # Target port 9999 instead of 12345
    pkt = make_ethernet_udp_packet(payload, dest_port=9999)
    
    monitor_task = cocotb.start_soon(capture_payload(dut))
    await send_packet(dut, pkt)
    await Timer(50, units="ns")
    
    captured = monitor_task.result()
    assert len(captured) == 0, "No payload should be output for non-configured port"
    assert dut.status_valid_packet.value == 0

@cocotb.test()
async def test_very_short_payload(dut):
    """Verify parser behaves correctly when UDP payload fits entirely in Cycle 5 (<= 6 bytes)."""
    await setup_dut(dut)
    
    payload = [0xDE, 0xAD, 0xBE, 0xEF] # 4 bytes (fits in cycle 5)
    pkt = make_ethernet_udp_packet(payload)
    
    monitor_task = cocotb.start_soon(capture_payload(dut))
    await send_packet(dut, pkt)
    await Timer(50, units="ns")
    
    captured = monitor_task.result()
    assert captured == payload, f"Expected {payload}, got {captured}"
    assert dut.status_valid_packet.value == 1
    assert dut.status_error.value == 0

async def capture_payload(dut):
    """Helper task to monitor m_axis output and reconstruct the payload bytes."""
    payload_bytes = []
    
    # We run for a limited number of clock cycles to prevent infinite loops in failure cases
    for _ in range(50):
        await RisingEdge(dut.clk)
        if dut.m_axis_tvalid.value == 1:
            data = int(dut.m_axis_tdata.value)
            keep = int(dut.m_axis_tkeep.value)
            
            # Extract only the bytes indicated by keep
            for i in range(8):
                if (keep >> i) & 1:
                    payload_bytes.append((data >> (8 * i)) & 0xFF)
            
            if dut.m_axis_tlast.value == 1:
                break
    return payload_bytes
