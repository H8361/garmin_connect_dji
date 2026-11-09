#!/usr/bin/env python3
"""Generate minimal PNG launcher icons for the Connect IQ projects."""
import zlib, struct, os

def write_png(path, size, rgb):
    w = h = size
    row = b'\x00' + bytes(rgb) * w
    raw = row * h
    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', ihdr)
           + chunk(b'IDAT', zlib.compress(raw))
           + chunk(b'IEND', b''))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(png)
    print('OK', path, size)

# 深蓝底启动图标 (占位, 仅保证可编译; 上架前替换为正式设计)
write_png('datafield/resources/drawables/launcher.png', 51, (18, 68, 136, 255))
write_png('testapp/resources/drawables/launcher.png', 51, (18, 68, 136, 255))
