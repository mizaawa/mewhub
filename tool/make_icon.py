"""Generates MewHub icons: a caramel cat face on a milk-white gradient.

Outputs (1024px):
  assets/images/icon.png       full icon (iOS / in-app), no alpha
  assets/images/icon_fg.png    adaptive foreground (transparent, safe zone)
  assets/images/icon_mono.png  monochrome (Android 13 themed icon)
"""
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersample, downscaled to 1024
CREAM_TOP = (253, 249, 243)
CREAM_BOT = (236, 220, 202)
CARAMEL = (196, 140, 92)
CARAMEL_DARK = (160, 108, 66)
INNER_EAR = (244, 186, 178)
COCOA = (74, 56, 44)
BLUSH = (242, 160, 150)


def gradient(size, top, bot):
    img = Image.new('RGB', (size, size), top)
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (size, y)], fill=c)
    return img


def cat(size, scale=1.0, mono=False):
    """Draws the cat on a transparent layer; scale shrinks it toward center."""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = size / 2, size / 2 + size * 0.04 * scale
    u = size * scale / 1024  # unit relative to a 1024 design

    def P(x, y):
        return (cx + x * u, cy + y * u)

    head = CARAMEL if not mono else (255, 255, 255)
    dark = CARAMEL_DARK if not mono else (255, 255, 255)
    # ears (outer)
    d.polygon([P(-300, -120), P(-250, -400), P(-90, -250)], fill=dark)
    d.polygon([P(300, -120), P(250, -400), P(90, -250)], fill=dark)
    # head
    d.ellipse([P(-330, -300), P(330, 290)], fill=head)
    if not mono:
        # inner ears
        d.polygon([P(-255, -170), P(-238, -330), P(-140, -240)], fill=INNER_EAR)
        d.polygon([P(255, -170), P(238, -330), P(140, -240)], fill=INNER_EAR)
        # muzzle highlight
        d.ellipse([P(-150, 20), P(150, 230)], fill=(250, 236, 220))
        # blush
        d.ellipse([P(-250, 40), P(-160, 100)], fill=BLUSH)
        d.ellipse([P(160, 40), P(250, 100)], fill=BLUSH)
    eye = COCOA if not mono else (0, 0, 0, 0)
    w = int(26 * u)
    # happy closed eyes (arcs)
    d.arc([P(-215, -90), P(-85, 20)], start=200, end=340, fill=eye, width=w)
    d.arc([P(85, -90), P(215, 20)], start=200, end=340, fill=eye, width=w)
    # nose
    nose = (232, 128, 120) if not mono else (0, 0, 0, 0)
    d.polygon([P(-34, 40), P(34, 40), P(0, 82)], fill=nose)
    # mouth "w"
    mw = int(18 * u)
    d.arc([P(-70, 60), P(2, 130)], start=20, end=160, fill=eye, width=mw)
    d.arc([P(-2, 60), P(70, 130)], start=20, end=160, fill=eye, width=mw)
    if not mono:
        # whiskers
        ww = int(10 * u)
        for dy in (60, 105):
            d.line([P(-170, dy), P(-330, dy - 25)], fill=(140, 100, 70), width=ww)
            d.line([P(170, dy), P(330, dy - 25)], fill=(140, 100, 70), width=ww)
    return layer


def shadow(layer, size):
    a = layer.split()[3].filter(ImageFilter.GaussianBlur(size * 0.025))
    sh = Image.new('RGBA', layer.size, (120, 80, 50, 0))
    sh.putalpha(a.point(lambda v: int(v * 0.35)))
    out = Image.new('RGBA', layer.size, (0, 0, 0, 0))
    out.alpha_composite(sh, (0, int(size * 0.02)))
    return out


def main():
    bg = gradient(S, CREAM_TOP, CREAM_BOT).convert('RGBA')
    c = cat(S, 0.92)
    bg.alpha_composite(shadow(c, S))
    bg.alpha_composite(c)
    bg.convert('RGB').resize((1024, 1024), Image.LANCZOS).save('assets/images/icon.png', optimize=True)

    fg = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    c2 = cat(S, 0.58)
    fg.alpha_composite(shadow(c2, S))
    fg.alpha_composite(c2)
    fg.resize((1024, 1024), Image.LANCZOS).save('assets/images/icon_fg.png', optimize=True)

    mono = cat(S, 0.58, mono=True)
    mono.resize((1024, 1024), Image.LANCZOS).save('assets/images/icon_mono.png', optimize=True)
    print('icons written')


if __name__ == '__main__':
    main()
