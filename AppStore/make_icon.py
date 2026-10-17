import numpy as np, colorsys, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2048
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-%s.otf"
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)

def screen(a, b): return 255 - (255 - a) * (255 - b) / 255

def orbit_bg():
    cx, cy = S * 0.5, S * 0.47
    r = np.clip(np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (S * 0.75), 0, 1)[..., None]
    img = np.array([18, 22, 52], np.float32) * (1 - r) + np.array([3, 3, 10], np.float32) * r
    # faint stars
    rng = np.random.default_rng(121)
    for _ in range(140):
        x, y = rng.uniform(0, S, 2); a = rng.uniform(0.15, 0.6); s = rng.uniform(1.5, 3.5)
        d2 = (xx - x) ** 2 + (yy - y) ** 2
        img = screen(img, np.array([220, 230, 255], np.float32)[None, None, :] * (np.exp(-d2 / (2 * s * s)) * a)[..., None])
    # a tilted orbit
    ang = np.radians(-18)
    X = (xx - cx) * np.cos(ang) - (yy - cy) * np.sin(ang)
    Y = (xx - cx) * np.sin(ang) + (yy - cy) * np.cos(ang)
    a_, b_ = S * 0.47, S * 0.13
    e = np.sqrt((X / a_) ** 2 + (Y / b_) ** 2)
    ring = np.exp(-((e - 1) * a_ / (S * 0.004)) ** 2) * 0.35
    img = screen(img, np.array([120, 170, 255], np.float32)[None, None, :] * ring[..., None])
    # E(5,16): sixteen steps round the orbit, five lit, the first one the satellite itself
    n, k = 16, 5
    for i in range(n):
        th = 2 * np.pi * i / n + 0.5
        px = cx + a_ * np.cos(th) * np.cos(ang) + b_ * np.sin(th) * np.sin(ang)
        py = cy - a_ * np.cos(th) * np.sin(ang) + b_ * np.sin(th) * np.cos(ang)
        d = np.sqrt((xx - px) ** 2 + (yy - py) ** 2)
        lit = (i * k) % n < k
        if lit:
            col = np.array([255, 160, 80], np.float32)
            img = screen(img, col[None, None, :] * (np.exp(-(d / (S * 0.022)) ** 2) * 0.55 + np.clip((S * 0.011 - d) / 3, 0, 1))[..., None])
        else:
            img = screen(img, np.array([170, 190, 255], np.float32)[None, None, :] * (np.clip((S * 0.005 - d) / 3, 0, 1) * 0.6)[..., None])
    return img

def tile(bg, symbol, number, mass, name, glow_rgb, out):
    img = Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    # Element-tile hairline frame
    frame = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    m = int(S * 0.085)
    fd.rounded_rectangle([m, m, S - m, S - m], radius=int(S * 0.11), outline=(255, 255, 255, 70), width=int(S * 0.0045))
    img = Image.alpha_composite(img, frame)

    # Symbol with a tinted glow
    sym_font = ImageFont.truetype(FONT % "Light", int(S * 0.43))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    cx, cy = S * 0.5, S * 0.40
    ld.text((cx, cy), symbol, font=sym_font, anchor="mm", fill=(250, 251, 255, 255))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.text((cx, cy), symbol, font=sym_font, anchor="mm", fill=glow_rgb + (230,))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.03))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, layer)

    # Periodic-table furniture: atomic number (top-left), atomic mass (top-right),
    # name under the symbol.
    small = ImageFont.truetype(FONT % "Regular", int(S * 0.078))
    tiny = ImageFont.truetype(FONT % "Medium", int(S * 0.050))
    td = ImageDraw.Draw(img)
    inset_x, inset_y = m + S * 0.055, m + S * 0.04
    td.text((inset_x, inset_y), number, font=small, fill=(255, 255, 255, 215))
    td.text((S - inset_x, inset_y), mass, font=small, anchor="ra", fill=(255, 255, 255, 150))
    # Name, letter-spaced, centred under the symbol
    label, track = name.upper(), S * 0.012
    widths = [td.textlength(ch, font=tiny) for ch in label]
    x = S * 0.5 - (sum(widths) + track * (len(label) - 1)) / 2
    for ch, w in zip(label, widths):
        td.text((x, S * 0.632), ch, font=tiny, anchor="lm", fill=(255, 255, 255, 175))
        x += w + track

    img.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(out)

# Element 121, the next one after Aether (119) and Bellweathered (120). The mass is the
# app's medium: 35,786 km, the geostationary altitude.
tile(orbit_bg(), "Ot", "121", "[35786]", "Orbitakt", (130, 170, 255), sys.argv[1])
print("ok")
