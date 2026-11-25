#!/usr/bin/env python3
"""Draws SuperSurfer's app icon: one link that fans out to the browsers.

    python3 packaging/macos/icon/make-icon.py packaging/macos/AppIcon.iconset

It writes the ten pictures macOS wants an app icon in, from 16 to 1024
points, into that folder. build-app.sh packs the folder into the app with
`iconutil`. The pictures are kept in the repository, so this only has to
run when the icon is to change. It needs Pillow and numpy.

The glyph is drawn here, from dots and curves. It is not the branching
arrow of the menu bar. That one is an SF Symbol of Apple's, and those may
be used in an app's interface and not in its icon.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# Everything below is measured on a picture 1024 points wide.
SIZE = 1024
# The rounded square that app icons fill since macOS 11. It leaves a tenth
# of the picture free on every side, which is where the shadow goes.
BODY = 824
RADIUS = 185.4
TOP = (58, 176, 255)
BOTTOM = (20, 96, 235)

START = (300, 512)
FORK = (410, 512)
TARGETS = [(716, 316), (716, 512), (716, 708)]


def curve(p0, p1, p2, p3, steps):
    """Points along a cubic Bézier curve, the first one left out."""
    for i in range(1, steps + 1):
        t = i / steps
        a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
        yield (a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1])


def body_mask(side):
    """The rounded square. Its corners run into the sides without a kink,
    which three curves per corner come close to."""
    k = side / SIZE
    w, r = BODY * k, RADIUS * k
    offset = (side - w) / 2

    corner = [(w - 1.528665 * r, 0.0)]
    corner += curve(corner[-1], (w - 1.08849296 * r, 0), (w - 0.86840694 * r, 0), (w - 0.63149379 * r, 0.07491139 * r), 40)
    corner += curve(corner[-1], (w - 0.37282383 * r, 0.16905956 * r), (w - 0.16905956 * r, 0.37282383 * r), (w - 0.07491139 * r, 0.63149379 * r), 40)
    corner += curve(corner[-1], (w, 0.86840694 * r), (w, 1.08849296 * r), (w, 1.528665 * r), 40)

    # That was the top right corner. The other three are its mirror images,
    # taken in the order that goes once around.
    outline = list(corner)
    outline += [(x, w - y) for x, y in reversed(corner)]
    outline += [(w - x, w - y) for x, y in corner]
    outline += [(w - x, y) for x, y in reversed(corner)]
    mask = Image.new("L", (side, side), 0)
    ImageDraw.Draw(mask).polygon([(x + offset, y + offset) for x, y in outline], fill=255)
    return mask


def gradient(side):
    """Lighter at the top, as if lit from above."""
    top = (SIZE - BODY) / 2 * side / SIZE
    t = np.clip((np.arange(side) + 0.5 - top) / (BODY * side / SIZE), 0, 1)[:, np.newaxis, np.newaxis]
    colors = np.array(TOP)[np.newaxis, np.newaxis, :] * (1 - t) + np.array(BOTTOM)[np.newaxis, np.newaxis, :] * t
    return Image.fromarray(np.broadcast_to(colors, (side, side, 3)).astype(np.uint8), "RGB")


def glyph_mask(side, weight):
    """A dot, a line that fans out in waves, and a larger dot at each end.
    `weight` thickens all of it for the pictures that are shown small."""
    k = side / SIZE
    mask = Image.new("L", (side, side), 0)
    draw = ImageDraw.Draw(mask)
    stroke = 56 * weight

    def dot(center, radius):
        draw.ellipse(((center[0] - radius) * k, (center[1] - radius) * k, (center[0] + radius) * k, (center[1] + radius) * k), fill=255)

    # A stroke is a row of dots set close together.
    def line(points):
        for point in points:
            dot(point, stroke / 2)

    line(curve(START, START, FORK, FORK, 200))
    for target in TARGETS:
        # Leaves the fork level and arrives level.
        lean = (target[0] - FORK[0]) * 0.55
        line(curve(FORK, (FORK[0] + lean, FORK[1]), (target[0] - lean, target[1]), target, 900))
        dot(target, 62 * (1 + (weight - 1) * 0.6))
    dot(START, 52 * (1 + (weight - 1) * 0.6))
    return mask


def icon(pixels):
    """The icon `pixels` wide. It is drawn several times as large and scaled
    down, which smooths every edge."""
    side = max(2048, pixels * 4)
    scale = side / SIZE
    weight = 1.0 if pixels >= 128 else (1.18 if pixels >= 64 else 1.4)
    nothing = Image.new("L", (side, side), 0)
    body = body_mask(side)
    picture = Image.new("RGBA", (side, side), (0, 0, 0, 0))

    # A soft shadow below the body, as the system's own icons have one.
    shadow = Image.new("L", (side, side), 0)
    shadow.paste(body, (0, round(12 * scale)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * scale)).point(lambda value: int(value * 0.30))
    picture.paste((0, 0, 0, 255), (0, 0), shadow)

    picture.paste(gradient(side), (0, 0), body)

    # The glyph, with a hint of depth under it.
    glyph = glyph_mask(side, weight)
    depth = Image.new("L", (side, side), 0)
    depth.paste(glyph, (0, round(8 * scale)))
    depth = depth.filter(ImageFilter.GaussianBlur(10 * scale)).point(lambda value: int(value * 0.22))
    picture.paste((6, 40, 120, 255), (0, 0), Image.composite(depth, nothing, body))
    picture.paste((255, 255, 255, 255), (0, 0), glyph)

    return picture.resize((pixels, pixels), Image.LANCZOS)


def main():
    if len(sys.argv) != 2 or not sys.argv[1].endswith(".iconset"):
        sys.exit("usage: make-icon.py <folder>.iconset")
    folder = Path(sys.argv[1])
    folder.mkdir(parents=True, exist_ok=True)
    drawn = {}
    # What iconutil expects: each size once, and once for a display that
    # shows two pixels to the point.
    for points in (16, 32, 128, 256, 512):
        for factor, ending in ((1, ""), (2, "@2x")):
            pixels = points * factor
            if pixels not in drawn:
                drawn[pixels] = icon(pixels)
            drawn[pixels].save(folder / f"icon_{points}x{points}{ending}.png", optimize=True)


if __name__ == "__main__":
    main()
