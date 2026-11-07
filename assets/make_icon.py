#!/usr/bin/env python3
"""Draw the Ghost app icon as a 1024x1024 PNG (macOS squircle + ghost)."""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# --- macOS-style rounded square with a vertical gradient -------------------
pad = 100
box = (pad, pad, S - pad, S - pad)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(box, radius=185, fill=255)
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
top, bot = (72, 61, 139), (30, 27, 75)         # indigo → deep navy
for y in range(S):
    t = y / S
    c = tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)) + (255,)
    gd.line([(0, y), (S, y)], fill=c)
img.paste(grad, (0, 0), mask)

# --- soft shadow under the ghost -------------------------------------------
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sh).ellipse((300, 790, 724, 860), fill=(0, 0, 0, 110))
sh = sh.filter(ImageFilter.GaussianBlur(28))
img.alpha_composite(sh)

# --- ghost body: dome + wavy hem, semi-transparent white ---------------------
cx, top_y, w, bottom = 512, 250, 420, 790
left, right = cx - w // 2, cx + w // 2
pts = []
# dome (semicircle)
for i in range(0, 181):
    a = math.radians(180 + i)
    pts.append((cx + (w / 2) * math.cos(a), top_y + w / 2 + (w / 2) * math.sin(a)))
# right side down
pts.append((right, bottom - 40))
# wavy hem, right → left (4 scallops)
n = 4
for i in range(n * 2 + 1):
    x = right - (w / (n * 2)) * i
    y = bottom - 40 + (0 if i % 2 == 0 else 38)
    pts.append((x, y))
pts.append((left, bottom - 40))

body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(body).polygon(pts, fill=(255, 255, 255, 235))
img.alpha_composite(body)

# --- "transparency" cue: a faint checker patch showing through the belly ----
chk = Image.new("RGBA", (S, S), (0, 0, 0, 0))
cd = ImageDraw.Draw(chk)
sz = 34
for yy in range(560, 720, sz):
    for xx in range(400, 624, sz):
        if ((xx - 400) // sz + (yy - 560) // sz) % 2 == 0:
            cd.rectangle((xx, yy, xx + sz - 1, yy + sz - 1), fill=(120, 110, 190, 90))
chk_mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(chk_mask).rounded_rectangle((400, 560, 624, 720), radius=30, fill=255)
img.paste(Image.alpha_composite(img, chk), (0, 0), chk_mask)

# --- eyes --------------------------------------------------------------------
for ex in (445, 579):
    d = ImageDraw.Draw(img)
    d.ellipse((ex - 38, 420, ex + 38, 500), fill=(30, 27, 75, 255))
    d.ellipse((ex - 14, 436, ex + 10, 460), fill=(255, 255, 255, 230))

img.save("icon_1024.png")
print("wrote icon_1024.png")
