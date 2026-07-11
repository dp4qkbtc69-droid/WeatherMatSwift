#!/usr/bin/env python3
"""
WeatherMat watch app icon generator.
Single 1024×1024 PNG, same sun+cloud motif and blue gradient as the iPhone
icon (see gen_icons.py), but bolder/simplified: no thin rays, bigger shapes,
so it stays legible once cropped to the small circular watch icon.
"""

import os
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__),
                    "WeatherMatWatch/App/Assets.xcassets/AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)

S = 1024


def lerp(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def draw_gradient(img, top, bot):
    draw = ImageDraw.Draw(img)
    for y in range(S):
        r, g, b = lerp(top, bot, y / S)
        draw.line([(0, y), (S, y)], fill=(r, g, b, 255))


def draw_sun_disc(img, cx, cy, radius, disc_col, glow_col):
    over = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    gr = int(radius * 1.55)
    d.ellipse([(cx - gr, cy - gr), (cx + gr, cy + gr)], fill=glow_col)
    blurred = over.filter(ImageFilter.GaussianBlur(radius // 3))
    img.paste(blurred, (0, 0), blurred)

    over = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    d.ellipse([(cx - radius, cy - radius), (cx + radius, cy + radius)], fill=disc_col)
    img.alpha_composite(over)


def draw_cloud(img, cx, cy, s, color):
    over = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)

    def ell(dx, dy, r):
        x, y, rr = int(cx + dx * s), int(cy + dy * s), int(r * s)
        d.ellipse([(x - rr, y - rr), (x + rr, y + rr)], fill=color)

    ell(0, 55, 95)
    ell(-75, 60, 78)
    ell(75, 55, 85)
    ell(0, -5, 88)
    ell(-78, 22, 68)
    ell(80, 15, 75)
    ell(-32, -62, 55)
    ell(42, -65, 62)

    img.alpha_composite(over)


def make_icon():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 255))

    # Same palette as the iPhone icon's default (light) variant, but bigger,
    # more centred shapes and no thin rays — those vanish at watch-icon size.
    draw_gradient(img, (45, 172, 245), (8, 104, 206))
    sun_disc = (255, 213, 79, 255)
    sun_glow = (255, 236, 150, 130)
    cloud_col = (255, 255, 255, 235)

    SUN_CX, SUN_CY = 470, 430
    SUN_R = 235
    CLOUD_CX, CLOUD_CY = 610, 620
    CLOUD_S = 0.78

    draw_sun_disc(img, SUN_CX, SUN_CY, SUN_R, sun_disc, sun_glow)
    draw_cloud(img, CLOUD_CX, CLOUD_CY, CLOUD_S, cloud_col)

    path = os.path.join(OUT, "icon_watch.png")
    img.convert("RGB").save(path, "PNG")
    print(f"  ✓  {path}")


if __name__ == "__main__":
    print("Generating WeatherMat watch app icon …")
    make_icon()
    print("Done.")
