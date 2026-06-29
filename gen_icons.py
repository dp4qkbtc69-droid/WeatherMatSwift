#!/usr/bin/env python3
"""
WeatherMat app icon generator — v3
Three 1024×1024 PNGs:
  icon_light.png   — clear sky-blue gradient, warm sun + white cloud
  icon_dark.png    — rich blue gradient, glowing sun + pale cloud
  icon_tinted.png  — flat neutral grey, single-color (iOS applies tint)
"""

import math, os
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__),
                   "WeatherMat/Assets.xcassets/AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)

S = 1024   # canvas size

# ── colour helpers ────────────────────────────────────────────────────────────

def lerp(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))

def with_alpha(rgb, a):
    return rgb[:3] + (a,)


# ── gradient background ───────────────────────────────────────────────────────

def draw_gradient(img, top, bot):
    """Vertical linear gradient, drawn onto img in-place."""
    draw = ImageDraw.Draw(img)
    for y in range(S):
        r, g, b = lerp(top, bot, y / S)
        draw.line([(0, y), (S, y)], fill=(r, g, b, 255))


# ── sun (disc + rounded rays + soft glow) ────────────────────────────────────

def draw_sun(img, cx, cy, radius, disc_col, glow_col=None, n_rays=8,
             ray_gap=14, ray_len=95, ray_w=20):
    over = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d    = ImageDraw.Draw(over)

    # soft glow
    if glow_col:
        gr = int(radius * 1.6)
        d.ellipse([(cx-gr, cy-gr), (cx+gr, cy+gr)], fill=glow_col)
        blurred = over.filter(ImageFilter.GaussianBlur(radius // 2))
        img.paste(blurred, (0, 0), blurred)
        over  = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        d     = ImageDraw.Draw(over)

    # rays with rounded caps
    for i in range(n_rays):
        angle  = math.radians(i * 360 / n_rays - 22.5)   # 22.5° offset = nice diagonal
        inner  = radius + ray_gap
        outer  = radius + ray_gap + ray_len
        x1 = cx + math.cos(angle) * inner
        y1 = cy + math.sin(angle) * inner
        x2 = cx + math.cos(angle) * outer
        y2 = cy + math.sin(angle) * outer
        d.line([(x1, y1), (x2, y2)], fill=disc_col, width=ray_w)
        r = ray_w // 2
        for px, py in ((x1, y1), (x2, y2)):
            d.ellipse([(px-r, py-r), (px+r, py+r)], fill=disc_col)

    # disc
    d.ellipse([(cx-radius, cy-radius), (cx+radius, cy+radius)], fill=disc_col)
    img.alpha_composite(over)


# ── cloud ─────────────────────────────────────────────────────────────────────

def draw_cloud(img, cx, cy, s, color):
    """
    Cloud drawn as overlapping circles — no hard rectangle edges.
    s = scale (1.0 → ~290px wide, ~170px tall)
    """
    over = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d    = ImageDraw.Draw(over)

    def ell(dx, dy, r):
        x, y, rr = int(cx + dx*s), int(cy + dy*s), int(r*s)
        d.ellipse([(x-rr, y-rr), (x+rr, y+rr)], fill=color)

    # bottom body (wide flat base)
    ell(  0,  55, 95)
    ell(-75,  60, 78)
    ell( 75,  55, 85)

    # top bumps
    ell(  0,  -5, 88)   # centre dome
    ell(-78,  22, 68)   # left dome
    ell( 80,  15, 75)   # right dome
    ell(-32, -62, 55)   # left top
    ell( 42, -65, 62)   # right top

    img.alpha_composite(over)


# ── assemble one icon ─────────────────────────────────────────────────────────

def make_icon(variant: str):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 255))

    # Layout — big optimistic sun, with a small fair-weather cloud for depth.
    SUN_CX,   SUN_CY   = 440, 420
    SUN_R              = 190
    CLOUD_CX, CLOUD_CY = 620, 585
    CLOUD_S            = 0.58   # scale: cloud ~168px wide

    if variant == "light":
        draw_gradient(img, ( 45, 172, 245), (  8, 104, 206))
        sun_disc  = (255, 213,  79, 255)
        sun_glow  = (255, 236, 150, 105)
        cloud_col = (255, 255, 255, 226)

    elif variant == "dark":
        draw_gradient(img, (  6,  77, 170), (  5,  35,  95))
        sun_disc  = (255, 220,  92, 255)
        sun_glow  = (255, 217, 105, 110)
        cloud_col = (207, 233, 255, 222)

    else:  # tinted — flat grey; iOS recolours it
        draw_gradient(img, (145, 145, 145), ( 95,  95,  95))
        sun_disc  = (225, 225, 225, 255)
        sun_glow  = None
        cloud_col = (195, 195, 195, 230)

    draw_sun(img, SUN_CX, SUN_CY, SUN_R,
             disc_col=sun_disc, glow_col=sun_glow,
             n_rays=8, ray_gap=16, ray_len=90, ray_w=20)

    draw_cloud(img, CLOUD_CX, CLOUD_CY, CLOUD_S, cloud_col)

    path = os.path.join(OUT, f"icon_{variant}.png")
    # App Store Connect rejects large app icons that contain an alpha channel.
    img.convert("RGB").save(path, "PNG")
    print(f"  ✓  {path}")


if __name__ == "__main__":
    print("Generating WeatherMat app icons …")
    for v in ("light", "dark", "tinted"):
        make_icon(v)
    print("Done.")
