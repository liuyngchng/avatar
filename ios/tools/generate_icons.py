#!/usr/bin/env python3
"""Generate iOS app icons from the Android launcher + splash icon designs.

- AppIcon  → ic_launcher_foreground.xml  (one-arm wave, dot eyes, cheeky grin)
- LaunchIcon → ic_splash_foreground.xml  (both arms up "Ta-da!", squint eyes, big grin)

Both use the same radial-gradient background (ic_launcher_background.xml / ic_splash_background.xml).
"""

import math
import os
from PIL import Image, ImageDraw

# ── Paths ────────────────────────────────────────────────────────────────
ASSETS = os.path.join(os.path.dirname(__file__), "..", "Avatar", "Avatar", "Assets.xcassets")
APPICON = os.path.join(ASSETS, "AppIcon.appiconset")
LAUNCH_ICON = os.path.join(ASSETS, "LaunchIcon.imageset")

# ── Android viewport ─────────────────────────────────────────────────────
VP = 108          # original adaptive-icon viewport (dp)
MASTER = 1024     # render at this resolution
S = MASTER / VP   # scale factor

# ── iOS sizes ────────────────────────────────────────────────────────────
IOS_SIZES = [1024, 180, 120, 152, 167, 80, 87, 60, 58, 40]

# ── Colors (from Android vectors) ────────────────────────────────────────
GRAD_CENTER = (0x2D, 0x2D, 0x44)
GRAD_MID    = (0x1E, 0x1E, 0x35)
GRAD_EDGE   = (0x15, 0x15, 0x28)

BODY        = (0xF0, 0xEC, 0xE6)
HEAD_FILL   = (0xFA, 0xF8, 0xF5)
HEAD_LINE   = (0xD0, 0xCC, 0xC6)
EYE_COLOR   = (0x1A, 0x1A, 0x2E)
MOUTH_COLOR = (0xE9, 0x45, 0x60)


def _s(val):
    return val * S


def _sw(val):
    return max(1.0, val * S)


def _lerp(a, b, t):
    return tuple(int(ai + (bi - ai) * t) for ai, bi in zip(a, b))


def draw_background(img: Image.Image):
    """Radial gradient matching ic_launcher_background.xml."""
    cx = cy = MASTER / 2
    r = _s(76)
    for y in range(MASTER):
        for x in range(MASTER):
            d = math.hypot(x - cx, y - cy)
            t = min(d / r, 1.0)
            if t < 0.7:
                c = _lerp(GRAD_CENTER, GRAD_MID, t / 0.7)
            else:
                c = _lerp(GRAD_MID, GRAD_EDGE, (t - 0.7) / 0.3)
            img.putpixel((x, y), (*c, 255))


def draw_common_body(draw: ImageDraw.ImageDraw):
    """Body + legs + head outline (shared between both poses)."""
    # Body
    draw.line(
        [(_s(54), _s(49)), (_s(54), _s(68))],
        fill=BODY, width=int(_sw(4)), joint="curve",
    )
    # Left leg (hip at body left edge: body center x=54, sw=4 → edge at 52)
    draw.line(
        [(_s(52), _s(68)), (_s(42), _s(80)), (_s(40), _s(88))],
        fill=BODY, width=int(_sw(3)), joint="curve",
    )
    # Right leg (hip at body right edge: body center x=54, sw=4 → edge at 56)
    draw.line(
        [(_s(56), _s(68)), (_s(66), _s(80)), (_s(68), _s(88))],
        fill=BODY, width=int(_sw(3)), joint="curve",
    )


def draw_head(draw: ImageDraw.ImageDraw):
    hr = _s(13)
    hx, hy = _s(54), _s(36)
    draw.ellipse(
        [(hx - hr, hy - hr), (hx + hr, hy + hr)],
        fill=HEAD_FILL, outline=HEAD_LINE, width=max(1, int(_sw(1.5))),
    )


def draw_feet_common(draw: ImageDraw.ImageDraw, left_hand, right_hand):
    """Feet (same for both) + provided hand positions."""
    dot_r = _s(2.5)
    for dx, dy in [
        left_hand,
        right_hand,
        (_s(40), _s(88)),   # left foot
        (_s(68), _s(88)),   # right foot
    ]:
        draw.ellipse(
            [(dx - dot_r, dy - dot_r), (dx + dot_r, dy + dot_r)],
            fill=BODY,
        )


# ── Launcher icon: one-arm wave ─────────────────────────────────────────

def draw_launcher_arms(draw: ImageDraw.ImageDraw):
    # Left arm (hanging, shoulder at body left edge x=52)
    draw.line(
        [(_s(52), _s(49)), (_s(34), _s(57)), (_s(28), _s(67))],
        fill=BODY, width=int(_sw(3)), joint="curve",
    )
    # Right arm (waving up, shoulder at body right edge x=56)
    draw.line(
        [(_s(56), _s(49)), (_s(74), _s(41)), (_s(80), _s(31))],
        fill=BODY, width=int(_sw(3)), joint="curve",
    )


def draw_launcher_eyes(draw: ImageDraw.ImageDraw):
    er = _s(2)
    for ex, ey in [(_s(48), _s(34)), (_s(60), _s(34))]:
        draw.ellipse(
            [(ex - er, ey - er), (ex + er, ey + er)],
            fill=EYE_COLOR,
        )


def draw_launcher_mouth(draw: ImageDraw.ImageDraw):
    # Crescent smile — thick arc, like a moon
    mw = _s(14)
    mh = _s(6)
    mx, my = _s(54), _s(39)
    sw = max(1, int(_sw(3)))
    draw.arc(
        [(mx - mw / 2, my - mh), (mx + mw / 2, my + mh)],
        start=30, end=150,
        fill=MOUTH_COLOR, width=sw,
    )


def render_launcher() -> Image.Image:
    img = Image.new("RGBA", (MASTER, MASTER))
    draw_background(img)
    d = ImageDraw.Draw(img)
    draw_common_body(d)
    draw_launcher_arms(d)
    draw_head(d)
    draw_launcher_eyes(d)
    draw_launcher_mouth(d)
    draw_feet_common(d, (_s(28), _s(67)), (_s(80), _s(31)))
    return img


# ── Splash icon: both arms up "Ta-da!" ──────────────────────────────────

def draw_splash_arms(draw: ImageDraw.ImageDraw):
    # Both arms raised up, shoulders at body edges (52, 56)
    # Left arm: 52,49 → 36,37 → 28,28
    draw.line(
        [(_s(52), _s(49)), (_s(36), _s(37)), (_s(28), _s(28))],
        fill=BODY, width=int(_sw(3)), joint="curve",
    )
    # Right arm: 56,49 → 72,37 → 80,28
    draw.line(
        [(_s(56), _s(49)), (_s(72), _s(37)), (_s(80), _s(28))],
        fill=BODY, width=int(_sw(3)), joint="curve",
    )


def draw_splash_eyes(draw: ImageDraw.ImageDraw):
    # Happy squints — upward arcs
    for sx, sy, ex, ey, cpx, cpy in [
        (_s(45), _s(34), _s(51), _s(34), _s(48), _s(31)),
        (_s(57), _s(34), _s(63), _s(34), _s(60), _s(31)),
    ]:
        # Quadratic bezier approximated with a short polyline
        pts = []
        for t in [i / 12.0 for i in range(13)]:
            x = (1-t)*(1-t)*sx + 2*(1-t)*t*cpx + t*t*ex
            y = (1-t)*(1-t)*sy + 2*(1-t)*t*cpy + t*t*ey
            pts.append((x, y))
        for i in range(len(pts) - 1):
            draw.line([pts[i], pts[i+1]], fill=EYE_COLOR, width=max(1, int(_sw(2))))


def draw_splash_mouth(draw: ImageDraw.ImageDraw):
    # Big happy grin: Q(54,46) from (47,40) to (61,40)
    sx, sy = _s(47), _s(40)
    ex, ey = _s(61), _s(40)
    cpx, cpy = _s(54), _s(46)
    pts = []
    for t in [i / 16.0 for i in range(17)]:
        x = (1-t)*(1-t)*sx + 2*(1-t)*t*cpx + t*t*ex
        y = (1-t)*(1-t)*sy + 2*(1-t)*t*cpy + t*t*ey
        pts.append((x, y))
    for i in range(len(pts) - 1):
        draw.line([pts[i], pts[i+1]], fill=MOUTH_COLOR, width=max(1, int(_sw(2))))


def render_splash() -> Image.Image:
    img = Image.new("RGBA", (MASTER, MASTER))
    draw_background(img)
    d = ImageDraw.Draw(img)
    draw_common_body(d)
    draw_splash_arms(d)
    draw_head(d)
    draw_splash_eyes(d)
    draw_splash_mouth(d)
    draw_feet_common(d, (_s(28), _s(28)), (_s(80), _s(28)))  # both hands high
    return img


# ── Main ────────────────────────────────────────────────────────────────

def main():
    launcher = render_launcher()
    splash = render_splash()

    # ── AppIcon (launcher pose) ──
    os.makedirs(APPICON, exist_ok=True)
    for size in IOS_SIZES:
        out = launcher.resize((size, size), Image.LANCZOS)
        path = os.path.join(APPICON, f"{size}.png")
        out.save(path, "PNG")
        print(f"  AppIcon  {size:>4}x{size:<4} → {path}")

    # ── LaunchIcon (splash/ta-da pose — full size only) ──
    os.makedirs(LAUNCH_ICON, exist_ok=True)
    path = os.path.join(LAUNCH_ICON, "LaunchIcon.png")
    splash.save(path, "PNG")
    print(f"  LaunchIcon 1024x1024 → {path}")

    print(f"\nDone. {len(IOS_SIZES)} AppIcon sizes + LaunchIcon generated.")


if __name__ == "__main__":
    main()
