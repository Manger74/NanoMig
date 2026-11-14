#!/usr/bin/env python3
# compare.py: checks the frame dumps of tb_osd_hdmi.v
#  - osd_hdmi text pixels against the buffer contents (u8g2 page layout)
#  - osd_hdmi centered in the active area
#  - osd_hdmi shape (text, border, shadow) identical to the osd_u8g2 reference
import sys

sw, sh = int(sys.argv[1]), int(sys.argv[2])
with_ref = len(sys.argv) < 4 or sys.argv[3] != "noref"

R, G, B = 0xa0, 0x50, 0xc0                    # picture source in the testbench

def classes(r, g, b, white, tint):
    return { (r, g, b): '.', (white,) * 3: 'W',
             (r >> 3, g >> 3, tint + (b >> 3)): 'o',      # OSD background
             (r >> 4, g >> 4, tint + (b >> 4)): 'O',      # OSD background with shadow
             (r >> 1, g >> 1, b >> 1): 's' }              # shadow outside the OSD

def load(name, cls, div):
    img = {}
    for line in open(name):
        x, y, r, g, b = map(int, line.split())
        img[(x, y)] = cls[(r // div, g // div, b // div)]   # KeyError: unexpected colour
    return img

def bbox(img):
    pts = [p for p, c in img.items() if c != '.']
    return min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts)

new = load("new.txt", classes(R, G, B, 0xff, 64), 1)
mem = [int(l) for l in open("buffer.txt")]
x0, y0, x1, y1 = bbox(new)
tx, ty = x0 + 4, y0 + 4                         # text area starts after the border
err = 0

# centered in the active area
if (tx, ty) != (sw // 2 - 128, sh // 2 - 64):
    print(f"FAIL: text origin {tx},{ty} expected {sw//2-128},{sh//2-64}"); err += 1

# osd area incl. border 264x136, shadow extends it by 8 to the right/bottom
if (x1 - x0 + 1, y1 - y0 + 1) != (264 + 8, 136 + 8):
    print(f"FAIL: osd size {x1-x0+1}x{y1-y0+1}"); err += 1

# every text pixel against the buffer
for y in range(128):
    for x in range(256):
        bit = (mem[(y // 16) * 128 + x // 2] >> ((y // 2) % 8)) & 1
        c = new[(tx + x, ty + y)]
        if (c == 'W') != bool(bit):
            if err < 10: print(f"FAIL: pixel {x},{y} is {c}, bit {bit}")
            err += 1

if with_ref:
    ref = load("ref.txt", classes(R >> 2, G >> 2, B >> 2, 63, 16), 4)
    rx0, ry0, _, _ = bbox(ref)
    diff = 0
    for y in range(y1 - y0 + 1):
        for x in range(x1 - x0 + 1):
            a = new.get((x0 + x, y0 + y)); b = ref.get((rx0 + x, ry0 + y))
            if a != b:
                if diff < 10: print(f"diff at osd {x},{y}: new {a} ref {b}")
                diff += 1
    print(f"reference osd_u8g2 at {rx0},{ry0}, osd_hdmi at {x0},{y0}: {diff} differing pixels")
    err += diff

print("PASS" if err == 0 else f"FAIL ({err})")
sys.exit(err != 0)
