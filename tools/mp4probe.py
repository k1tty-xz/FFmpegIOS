#!/usr/bin/env python3
"""Minimal MP4 box parser: codec, resolution, duration, bitrate. No ffmpeg.

Walks the moov/trak/.../stsd tree to pull the video sample-entry fourcc
('avc1' = H.264, 'hvc1'/'hev1' = HEVC), the track dimensions from tkhd, and
the duration from mvhd. Bitrate is derived from file size / duration.

Usage: python3 mp4probe.py file1.mp4 [file2.mp4 ...]
"""
import struct, sys, os

CONTAINERS = {b'moov', b'trak', b'mdia', b'minf', b'stbl', b'edts',
              b'udta', b'mvex', b'moof', b'traf'}

def walk(data, start, end, depth=0):
    """Yield (type, payload_start, payload_end) for boxes in [start, end)."""
    off = start
    while off + 8 <= end:
        size = struct.unpack('>I', data[off:off+4])[0]
        btype = data[off+4:off+8]
        header = 8
        if size == 1:                      # 64-bit largesize
            size = struct.unpack('>Q', data[off+8:off+16])[0]
            header = 16
        elif size == 0:                    # extends to end of file
            size = end - off
        if size < header:
            break
        yield btype, off + header, off + size, depth
        if btype in CONTAINERS:
            yield from walk(data, off + header, off + size, depth + 1)
        off += size

def fixed16_16(b):
    return struct.unpack('>I', b)[0] / 65536.0

def probe(path):
    with open(path, 'rb') as f:
        data = f.read()
    size = len(data)

    duration = None          # seconds (from mvhd)
    video_codec = None
    width = height = None

    for btype, s, e, _ in walk(data, 0, size):
        if btype == b'mvhd':
            version = data[s]
            if version == 1:
                timescale = struct.unpack('>I', data[s+20:s+24])[0]
                dur = struct.unpack('>Q', data[s+24:s+32])[0]
            else:
                timescale = struct.unpack('>I', data[s+12:s+16])[0]
                dur = struct.unpack('>I', data[s+16:s+20])[0]
            if timescale:
                duration = dur / timescale
        elif btype == b'tkhd':
            version = data[s]
            base = s + (32 if version == 1 else 20)
            # width/height are the last two 16.16 fixed-point fields
            w = fixed16_16(data[s + (size_off := (84 if version == 1 else 76)) - 8: s + size_off - 4]) if False else None
            # simpler: tkhd width/height are the final 8 bytes of the box payload
            w = fixed16_16(data[e-8:e-4])
            h = fixed16_16(data[e-4:e])
            if w and h:
                width, height = int(w), int(h)
        elif btype == b'stsd':
            # stsd: 4 version/flags + 4 entry_count, then sample entries
            entry = s + 8
            if entry + 8 <= e:
                fourcc = data[entry+4:entry+8]
                if fourcc in (b'avc1', b'avc3', b'hvc1', b'hev1', b'mp4v'):
                    video_codec = fourcc.decode('latin1')
                    # VisualSampleEntry: width/height at offset +24/+26 (uint16)
                    vw = struct.unpack('>H', data[entry+8+24:entry+8+26])[0]
                    vh = struct.unpack('>H', data[entry+8+26:entry+8+28])[0]
                    if vw and vh:
                        width, height = vw, vh

    codec_name = {
        'avc1': 'H.264', 'avc3': 'H.264',
        'hvc1': 'HEVC',  'hev1': 'HEVC',
        'mp4v': 'MPEG-4',
    }.get(video_codec, video_codec or '?')

    bitrate = (size * 8 / duration) if duration else None
    return {
        'path': path, 'size': size, 'duration': duration,
        'codec': codec_name, 'fourcc': video_codec,
        'width': width, 'height': height, 'bitrate': bitrate,
    }

def human(n):
    for u in ('B', 'KB', 'MB', 'GB'):
        if n < 1024: return f'{n:.1f}{u}'
        n /= 1024
    return f'{n:.1f}TB'

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 mp4probe.py FILE.mp4 [...]'); sys.exit(1)
    for p in sys.argv[1:]:
        if not os.path.exists(p):
            print(f'{p}: not found'); continue
        i = probe(p)
        dur = f"{i['duration']:.1f}s" if i['duration'] else '?'
        br  = f"{i['bitrate']/1e6:.2f} Mbit/s" if i['bitrate'] else '?'
        res = f"{i['width']}x{i['height']}" if i['width'] else '?'
        print(f"\n{os.path.basename(p)}")
        print(f"  codec    : {i['codec']} ({i['fourcc']})")
        print(f"  resolution: {res}")
        print(f"  duration : {dur}")
        print(f"  size     : {human(i['size'])}")
        print(f"  bitrate  : {br}   <- the real efficiency number")
