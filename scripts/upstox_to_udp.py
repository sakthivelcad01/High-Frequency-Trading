# e:/Verilog_HFT_FPGA/scripts/upstox_to_udp.py
# Real-Time Upstox API to UDP NASDAQ ITCH 5.0 Bridge
# Fetches live Indian market quotes and streams them into the FPGA UDP parser.

import os
import socket
import struct
import time
import requests

def load_access_token():
    # 1. Try to read from environment variable
    token = os.environ.get("UPSTOX_ACCESS_TOKEN")
    if token:
        return token
    
    # 2. Try to read from local .env file
    for env_path in [".env", "../.env", "scripts/.env"]:
        if os.path.exists(env_path):
            try:
                with open(env_path, "r") as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("UPSTOX_ACCESS_TOKEN="):
                            # Extract value after '=' and strip whitespace/quotes
                            val = line.split("=", 1)[1].strip()
                            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                                val = val[1:-1]
                            return val
            except Exception:
                pass
    return None

# ==========================================
# CONFIGURATION
# ==========================================
ACCESS_TOKEN = load_access_token()
INSTRUMENT = "NSE_EQ|INE002A01018"  # NSE: RELIANCE

# UDP target (FPGA Listening Port)
UDP_IP = "127.0.0.1"
UDP_PORT = 12345

# Mapping to our FPGA test configuration
FPGA_LOCATE_ID = 456       # Maps to AAPL in our strategy testbench config
FPGA_SYMBOL = b"AAPL    "  # 8-byte ASCII stock symbol

# Query interval (seconds)
POLL_INTERVAL = 0.5

# ==========================================
# FUNCTIONS
# ==========================================
def make_moldudp64_itch_packet(price_float, size_int, seq_num):
    """Encodes price and size into MoldUDP64 + NASDAQ ITCH 5.0 binary frame."""
    # Convert float price (e.g. 2450.55) to ITCH 5.0 32-bit integer (4 implied decimals)
    price_itch = int(price_float * 10000)
    
    # 1. MoldUDP64 Header (20 bytes)
    session_id = b"UPSTOXFEED"                # 10 bytes
    sequence_number = seq_num                 # 8 bytes (Q)
    message_count = 1                         # 2 bytes (H)
    
    # 2. ITCH Message Header
    msg_length = 36                           # 2 bytes (H) - ITCH Add Order size is 36
    msg_type = b"A"                           # 1 byte  - Add Order Message
    
    # 3. ITCH Add Order 'A' Message Body (35 bytes)
    stock_locate = FPGA_LOCATE_ID             # 2 bytes (H)
    tracking_number = 12                      # 2 bytes (H)
    timestamp = 1000000                       # 6 bytes - represented as 48-bit int (6B)
    order_id = 987654321                      # 8 bytes (Q)
    side = b"S"                               # 1 byte  - 'S' = Sell (representing Ask price limit)
    shares = size_int                         # 4 bytes (I)
    stock_symbol = FPGA_SYMBOL                # 8 bytes (8s)
    price = price_itch                        # 4 bytes (I)

    # Pack into binary using struct
    # Big-endian formatting is used for network protocols
    # Note: 48-bit timestamp split into 16-bit high and 32-bit low
    ts_high = (timestamp >> 32) & 0xFFFF
    ts_low = timestamp & 0xFFFFFFFF
    
    packet = struct.pack(
        ">10sQHHBHHHIQBI8sI",
        session_id,
        sequence_number,
        message_count,
        msg_length,
        msg_type[0],
        stock_locate,
        tracking_number,
        ts_high,
        ts_low,
        order_id,
        side[0],
        shares,
        stock_symbol,
        price
    )
    return packet

# ==========================================
# MAIN EXECUTION
# ==========================================
def main():
    print("====================================================")
    print("Upstox to UDP ITCH Bridge Starting...")
    print(f"Streaming data to {UDP_IP}:{UDP_PORT}")
    print(f"Monitoring Instrument: {INSTRUMENT}")
    print(f"Targeting FPGA Locate ID: {FPGA_LOCATE_ID} ({FPGA_SYMBOL.decode('ascii').strip()})")
    print("====================================================")
    
    if not ACCESS_TOKEN:
        print("[ERROR] No valid UPSTOX_ACCESS_TOKEN found!")
        print("Please create a '.env' file in the root folder of this project with:")
        print("  UPSTOX_ACCESS_TOKEN=your_token_here")
        print("Or set the UPSTOX_ACCESS_TOKEN environment variable in your shell.")
        return
    
    # Setup UDP Socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    # Headers for Upstox API v2 request
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {ACCESS_TOKEN}"
    }
    
    url = f"https://api.upstox.com/v2/market-quote/ltp?instrument_key={INSTRUMENT}"
    
    seq_num = 1
    
    try:
        while True:
            try:
                response = requests.get(url, headers=headers, timeout=5)
                if response.status_code == 200:
                    res_data = response.json()
                    
                    if "data" in res_data and len(res_data["data"]) > 0:
                        # Extract the stock info
                        # Key can be e.g. "NSE_EQ:RELIANCE"
                        key = list(res_data["data"].keys())[0]
                        stock_info = res_data["data"][key]
                        
                        price = stock_info["last_price"]
                        # Default size to 500 if volume is not present or 0
                        size = stock_info.get("volume", 500)
                        if size == 0:
                            size = 500
                            
                        print(f"[LIVE TICK] Symbol: {key} | LTP: {price} | Size: {size}")
                        
                        # Generate binary ITCH packet
                        packet = make_moldudp64_itch_packet(price, size, seq_num)
                        
                        # Stream packet over UDP loopback
                        sock.sendto(packet, (UDP_IP, UDP_PORT))
                        
                        print(f"  -> Sent MoldUDP64 seq {seq_num} (Length: {len(packet)} bytes)")
                        seq_num += 1
                    else:
                        print(f"[WARNING] API returned empty data: {res_data}")
                else:
                    print(f"[ERROR] HTTP {response.status_code}: {response.text}")
                    
            except requests.exceptions.RequestException as e:
                print(f"[CONNECTION ERROR] Failed to connect to Upstox API: {e}")
                
            time.sleep(POLL_INTERVAL)
            
    except KeyboardInterrupt:
        print("\nStopping Upstox UDP bridge. Goodbye!")
    finally:
        sock.close()

if __name__ == "__main__":
    main()
