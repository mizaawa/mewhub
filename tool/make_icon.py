"""Builds MewHub's icon set from the generated artwork in tool/icon_art.png.

The artwork (gpt-image-2.6) is a clay cat-bubble on a milk-cream gradient.
This script cuts the cat out and writes (1024px):
  assets/images/icon.png       full icon (iOS / in-app), no alpha
  assets/images/icon_fg.png    adaptive foreground: cat + soft shadow, in the safe zone
  assets/images/icon_bg.png    adaptive background: the artwork's cream gradient
  assets/images/icon_mono.png  monochrome silhouette (Android 13 themed icon)
Then run `dart run flutter_launcher_icons`.

usage: python tool/make_icon.py
"""
from collections import deque

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ART = 'tool/icon_art.png'
OUT = 'assets/images/'
N = 1024
# Adaptive icons: 108dp canvas, 66dp guaranteed visible. Keep the cat's
# widest extent inside ~60dp so circle masks don't clip the ears.
FG_SPAN = 0.52


def cat_mask(rgb, thr=160):
    """Flood-fills bright background + shadow from the borders; the cat's
    darker caramel rim stops the fill. Keeps the largest remaining region."""
    im = np.asarray(rgb).astype(np.int32)
    h, w, _ = im.shape
    passable = im.min(axis=2) > thr
    seen = np.zeros((h, w), bool)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if passable[y, x] and not seen[y, x]:
                seen[y, x] = True
                q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if passable[y, x] and not seen[y, x]:
                seen[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and not seen[ny, nx] and passable[ny, nx]:
                seen[ny, nx] = True
                q.append((ny, nx))
    cat = ~seen
    # Largest 4-connected component only (drops shadow fragments).
    label = np.zeros((h, w), np.int32)
    best, best_n, cur = 0, 0, 0
    for y0 in range(h):
        for x0 in np.flatnonzero(cat[y0] & (label[y0] == 0)):
            if label[y0, x0]:
                continue
            cur += 1
            label[y0, x0] = cur
            q = deque([(y0, x0)])
            n = 0
            while q:
                y, x = q.popleft()
                n += 1
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w and cat[ny, nx] and not label[ny, nx]:
                        label[ny, nx] = cur
                        q.append((ny, nx))
            if n > best_n:
                best, best_n = cur, n
    m = Image.fromarray(((label == best) * 255).astype(np.uint8), 'L')
    return m.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(1.0))


def background(rgb):
    """Vertical cream gradient sampled from the artwork's left/right borders."""
    a = np.asarray(rgb).astype(np.float32)
    col = (a[:, :24].mean(axis=1) + a[:, -24:].mean(axis=1)) / 2
    grad = np.repeat(col[:, None, :], a.shape[1], axis=1)
    return Image.fromarray(grad.clip(0, 255).astype(np.uint8), 'RGB')


def soft_shadow(alpha, size):
    """A flat, warm contact shadow under the cat, like the artwork's."""
    box = alpha.point(lambda v: 255 if v > 128 else 0).getbbox()
    sh = Image.new('L', (size, size), 0)
    x0, _, x1, y1 = box
    cx, w = (x0 + x1) / 2, (x1 - x0)
    ImageDraw.Draw(sh).ellipse([cx - w * 0.42, y1 - w * 0.035, cx + w * 0.42, y1 + w * 0.05], fill=120)
    sh = sh.filter(ImageFilter.GaussianBlur(size * 0.018))
    layer = Image.new('RGBA', (size, size), (150, 98, 58, 0))
    layer.putalpha(ImageChops.subtract(sh, alpha))
    return layer


def place(img, alpha, span):
    """Scales the cat so its bbox width is span*N and centres it."""
    box = alpha.point(lambda v: 255 if v > 128 else 0).getbbox()
    cw, ch = box[2] - box[0], box[3] - box[1]
    s = span * N / cw
    crop = img.crop(box).resize((round(cw * s), round(ch * s)), Image.LANCZOS)
    out = Image.new(img.mode, (N, N), (0,) * len(img.getbands()))
    out.paste(crop, ((N - crop.width) // 2, (N - crop.height) // 2 + round(N * 0.01)))
    return out


def main():
    art = Image.open(ART).convert('RGB').resize((N, N), Image.LANCZOS)
    art.save(OUT + 'icon.png', optimize=True)
    background(art).save(OUT + 'icon_bg.png', optimize=True)

    alpha = cat_mask(art)
    cat = art.copy()
    cat.putalpha(alpha)
    fg_cat = place(cat, alpha, FG_SPAN)
    fg = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    fg.alpha_composite(soft_shadow(fg_cat.split()[3], N))
    fg.alpha_composite(fg_cat)
    fg.save(OUT + 'icon_fg.png', optimize=True)

    # Silhouette with the dark face strokes (eyes, mouth, whiskers) punched out.
    lum = fg_cat.convert('RGB').convert('L')
    strokes = lum.point(lambda v: 255 if v < 115 else 0)
    strokes = ImageChops.multiply(strokes, fg_cat.split()[3].filter(ImageFilter.MinFilter(25)))
    strokes = strokes.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
    mono = Image.new('RGBA', (N, N), (255, 255, 255, 0))
    mono.putalpha(ImageChops.subtract(fg_cat.split()[3], strokes))
    mono.save(OUT + 'icon_mono.png', optimize=True)
    print('icons written')


if __name__ == '__main__':
    main()
