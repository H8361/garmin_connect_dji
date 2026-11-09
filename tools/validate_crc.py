#!/usr/bin/env python3
"""Validate CRC16/CRC32 implementations against official DJI demo test frames."""

def crc16(data):
    # Reflected CRC-CCITT (poly 0x8408), init 0x3AA3, no final XOR (per custom_crc16.c)
    crc = 0x3AA3
    for b in data:
        crc ^= b & 0xFF
        for _ in range(8):
            crc = ((crc >> 1) ^ 0x8408) if (crc & 1) else (crc >> 1)
    return crc & 0xFFFF

def crc32(data):
    # Standard reflected CRC-32 (poly 0xEDB88320); init/xorout probed below
    for init, xorout in ((0xFFFFFFFF, 0xFFFFFFFF), (0xFFFFFFFF, 0), (0, 0)):
        crc = init
        for b in data:
            crc ^= b & 0xFF
            for _ in range(8):
                crc = ((crc >> 1) ^ 0xEDB88320) if (crc & 1) else (crc >> 1)
        if (crc ^ xorout) & 0xFFFFFFFF == EXPECTED32:
            return crc ^ xorout, (init, hex(xorout))
    return None, None

# --- Vector 1: mode switch example from protocol_data_segment_CN.md ---
frame = bytes.fromhex("AA" + "1B00" + "01" + "00" + "000000" + "0500" + "57EE" + "1D04" + "000033FF" + "0A" + "01473936" + "F4FAE1D0")
assert len(frame) == 27, len(frame)
c16 = crc16(frame[:10])
print("mode-switch frame:", frame.hex().upper())
print("  CRC16 calc=0x%04X expect=0x%04X  %s" % (c16, 0xEE57, "OK" if c16 == 0xEE57 else "MISMATCH"))
EXPECTED32 = int.from_bytes(frame[23:27], "little")
c32, params = crc32(frame[:23])
print("  CRC32 calc=%s expect=0x%08X params=%s" % (("0x%08X" % c32) if c32 else "None", 0xD0E1FAF4, params))

# --- Vector 2: connect frames from connect_cmd_frame.txt ---
import os
_here = os.path.dirname(os.path.abspath(__file__))
        lines = [l.strip() for l in open(os.path.join(_here, "connect_cmd_frame.txt")) if l.strip()]
for i, hexline in enumerate(lines[:3]):
    f = bytes.fromhex(hexline)
    total = f[1] | ((f[2] & 0x03) << 8)
    c16 = crc16(f[:10])
    exp16 = f[10] | (f[11] << 8)
    exp32 = int.from_bytes(f[-4:], "little")
    EXPECTED32 = exp32
    c32, params = crc32(f[:-4])
    ok16 = "OK" if c16 == exp16 else "MISMATCH"
    ok32 = "OK" if c32 == exp32 else "MISMATCH"
    print("connect[%d] len=%d data_len=%d CRC16 %s CRC32 %s params=%s" % (i, len(f), total, ok16, ok32, params))
    if i == 0:
        payload = f[12:-4]
        print("  DATA:", payload.hex().upper())
        print("  DATA[0:2]=%02X %02X payload_len=%d" % (payload[0], payload[1], len(payload) - 2))
