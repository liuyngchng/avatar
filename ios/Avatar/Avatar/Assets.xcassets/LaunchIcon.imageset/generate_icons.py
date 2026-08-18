#!/usr/bin/env python3
"""
Generate iOS LaunchIcon PNGs — stick figure in ta-da! pose.
Emoji-style mouth design: red filled D-shaped cavity replaces the thin
stroke arc. White teeth are impossible on a white head, so the red
open-mouth shape (same pattern as the interactive speaking mouth)
communicates "big grin" purely through color contrast.

Viewport: 108x108 (Android adaptive icon)
Targets: 200x200 (@1x), 400x400 (@2x), 600x600 (@3x)
"""
from PIL import Image, ImageDraw
import math, os

# ─── Color palette (emoji yellow stick figure) ──────────────────
HEAD_FILL   = (0xFF, 0xE0, 0x66, 255)   # #FFE066 light yellow
HEAD_STROKE = (0xDD, 0xB8, 0x00, 255)   # #DDB800 golden outline
BODY_COLOR  = (0xF2, 0xCC, 0x3D, 255)   # #F2CC3D emoji yellow
EYE_COLOR   = (0x33, 0x33, 0x33, 255)   # #333333 soft charcoal
MOUTH_COLOR = (0x44, 0x44, 0x44, 255)   # #444444 emoji dark

# ─── Geometry (108×108 viewport) ────────────────────────────────────

HEAD_CX, HEAD_CY, HEAD_R = 54, 36, 13
HEAD_OUTLINE_SW = 1.5

BODY_X, BODY_Y1, BODY_Y2 = 54, 49, 68
BODY_SW = 4

# Arms: shoulders connect to body edges (body x=54, sw=4 → edges at 52, 56)
LA = [(52, 49), (36, 37), (28, 28)]   # left arm: shoulder→elbow→hand
RA = [(56, 49), (72, 37), (80, 28)]   # right arm
# Legs: hips connect to body edges at bottom
LL = [(52, 68), (42, 80), (40, 88)]   # left leg: hip→knee→foot
RL = [(56, 68), (66, 80), (68, 88)]   # right leg
LIMB_SW = 3
JOINT_R = 2.5

# Eyes: happy squints (upward arcs)
LEYE = ((45, 34), (48, 31), (51, 34))   # P0, CP, P1
REYE = ((57, 34), (60, 31), (63, 34))
EYE_SW = 2

# Mouth: emoji-style filled D-shaped cavity.
# White head → no white teeth. Red semi-ellipse = open-mouth grin.
MOUTH_CX, MOUTH_CY = 54, 43
MOUTH_RX, MOUTH_RY = 6.5, 5.0   # ellipse semi-axes
MOUTH_FLAT_TOP = True            # D-shape: flat top, curved bottom


def scale(v, factor):
    if isinstance(v, (list, tuple)):
        return [x * factor for x in v]
    return v * factor


def draw_filled_semi_ellipse(draw, cx, cy, rx, ry, color, flat_top=True):
    """Draw a filled semi-ellipse with optional white teeth at the top edge."""
    n = 60
    points = []
    start_angle = 0 if flat_top else math.pi
    end_angle = math.pi if flat_top else 2 * math.pi

    for i in range(n + 1):
        t = i / n
        angle = start_angle + t * (end_angle - start_angle)
        x = cx + rx * math.cos(angle)
        y = cy + ry * math.sin(angle)
        points.append((x, y))

    draw.polygon(points, fill=color)

    # White upper-tooth band — clipped within the dark cavity.
    # Bar is slightly narrower than the cavity to ensure it never
    # overflows the curved edges of the semi-ellipse.
    bar_w = rx * 0.82
    bar_h = ry * 0.28
    bar_x = cx - bar_w / 2
    bar_y = cy - bar_h * 0.5
    tooth_color = (255, 255, 255, 255)
    draw.rounded_rectangle([bar_x, bar_y, bar_x + bar_w, bar_y + bar_h],
                           radius=bar_h * 0.35, fill=tooth_color)


def draw_quadratic_bezier(draw, p0, p1, p2, color, width):
    """Approximate a quadratic bezier with line segments."""
    n = 30
    points = []
    for i in range(n):
        t = i / (n - 1)
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        points.append((x, y))
    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=color, width=width)


def draw_figure(draw, canvas_w, canvas_h):
    """Draw stick figure onto PIL ImageDraw, scaling from 108×108 viewport."""
    f_w = canvas_w / 108.0
    f = lambda v: scale(v, f_w)

    # ── Head ──
    cx, cy = f(HEAD_CX), f(HEAD_CY)
    r = f(HEAD_R)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=HEAD_FILL)
    sw = max(1, round(f(HEAD_OUTLINE_SW)))
    draw.ellipse([cx - r, cy - r, cx + r, cy + r],
                 outline=HEAD_STROKE, width=sw)

    # ── Body ──
    body_sw = max(1, round(f(BODY_SW)))
    draw.line([f(BODY_X), f(BODY_Y1), f(BODY_X), f(BODY_Y2)],
              fill=BODY_COLOR, width=body_sw)

    # ── Limbs ──
    limb_sw = max(1, round(f(LIMB_SW)))
    for chain in [LA, RA, LL, RL]:
        p0, p1, p2 = [f(v) for v in chain[0]], [f(v) for v in chain[1]], [f(v) for v in chain[2]]
        draw.line([p0[0], p0[1], p1[0], p1[1]], fill=BODY_COLOR, width=limb_sw)
        draw.line([p1[0], p1[1], p2[0], p2[1]], fill=BODY_COLOR, width=limb_sw)

    # ── Joint dots ──
    jr = f(JOINT_R)
    for chain in [LA, RA, LL, RL]:
        # End dot (hand/foot)
        ex, ey = f(chain[2][0]), f(chain[2][1])
        draw.ellipse([ex - jr, ey - jr, ex + jr, ey + jr], fill=BODY_COLOR)
        # Elbow/knee dot
        ex, ey = f(chain[1][0]), f(chain[1][1])
        draw.ellipse([ex - jr * 0.85, ey - jr * 0.85,
                      ex + jr * 0.85, ey + jr * 0.85], fill=BODY_COLOR)

    # ── Eyes (happy squints) ──
    eye_sw = max(1, round(f(EYE_SW)))
    for eye in [LEYE, REYE]:
        draw_quadratic_bezier(draw,
            (f(eye[0][0]), f(eye[0][1])),
            (f(eye[1][0]), f(eye[1][1])),
            (f(eye[2][0]), f(eye[2][1])),
            EYE_COLOR, eye_sw)

    # ── Mouth (emoji-style filled D-shaped cavity) ──
    mcx, mcy = f(MOUTH_CX), f(MOUTH_CY)
    mrx, mry = f(MOUTH_RX), f(MOUTH_RY)
    draw_filled_semi_ellipse(draw, mcx, mcy, mrx, mry, MOUTH_COLOR, flat_top=MOUTH_FLAT_TOP)


# ─── Generate ───────────────────────────────────────────────────────

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
TARGETS = [
    ("LaunchIcon.png",     200,  200),
    ("LaunchIcon@2x.png",  400,  400),
    ("LaunchIcon@3x.png",  600,  600),
]

for filename, w, h in TARGETS:
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw_figure(draw, w, h)
    path = os.path.join(OUT_DIR, filename)
    img.save(path, "PNG")
    print(f"  ✓ {filename}  ({w}×{h})  — {os.path.getsize(path)} bytes")

print("Done.")
