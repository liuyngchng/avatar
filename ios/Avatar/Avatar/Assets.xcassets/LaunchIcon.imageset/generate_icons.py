#!/usr/bin/env python3
"""
Generate iOS LaunchIcon PNGs matching Android's ic_splash_foreground.xml
stick figure in ta-da! pose with happy squint eyes + big grin.

Viewport: 108x108 (Android adaptive icon)
Targets: 200x200 (@1x), 400x400 (@2x), 600x600 (@3x)
"""
from PIL import Image, ImageDraw
import math, os

# ─── Color palette (from Android XML) ───
HEAD_FILL   = (0xFA, 0xF8, 0xF5, 255)   # #FAF8F5 warm white fill
HEAD_STROKE = (0xD0, 0xCC, 0xC6, 255)   # #D0CCC6 subtle outline
BODY_COLOR  = (0xF0, 0xEC, 0xE6, 255)   # #F0ECE6 warm white lines
EYE_COLOR   = (0x1A, 0x1A, 0x2E, 255)   # #1A1A2E dark navy
MOUTH_COLOR = (0xE9, 0x45, 0x60, 255)   # #E94560 warm red

# ─── Geometry ──────────────────────────────────────────────────────────
# All coordinates in the Android 108x108 viewport space.
# These are scaled to the target canvas size at render time.

# Head: center + radius
HEAD_CX, HEAD_CY, HEAD_R = 54, 36, 13

# Body: vertical line neck → hip
BODY_X, BODY_Y1, BODY_Y2 = 54, 49, 68
BODY_SW = 4   # stroke width

# Left arm (two segments)
LA_X0, LA_Y0 = 46, 49    # shoulder
LA_X1, LA_Y1 = 36, 37    # elbow
LA_X2, LA_Y2 = 28, 28    # hand

# Right arm (two segments)
RA_X0, RA_Y0 = 62, 49
RA_X1, RA_Y1 = 72, 37
RA_X2, RA_Y2 = 80, 28

# Left leg (two segments)
LL_X0, LL_Y0 = 48, 68    # hip
LL_X1, LL_Y1 = 42, 80    # knee
LL_X2, LL_Y2 = 40, 88    # foot

# Right leg (two segments)
RL_X0, RL_Y0 = 60, 68
RL_X1, RL_Y1 = 66, 80
RL_X2, RL_Y2 = 68, 88

LIMB_SW = 3      # limb stroke width

# Eye: happy squint arcs — (left/right) (cx, y_top) → control_point → (cx, y_bot)
LEYE_X0, LEYE_X1 = 45, 51   ; LEYE_Y0, LEYE_Y1 = 34, 34  ; LEYE_CX, LEYE_CY = 48, 31
REYE_X0, REYE_X1 = 57, 63   ; REYE_Y0, REYE_Y1 = 34, 34  ; REYE_CX, REYE_CY = 60, 31
EYE_SW = 2

# Mouth: big happy grin arc
MOUTH_X0, MOUTH_X1 = 47, 61 ; MOUTH_Y0, MOUTH_Y1 = 40, 40
MOUTH_CX, MOUTH_CY = 54, 46
MOUTH_SW = 2

# Joint dots (hands & feet)
JOINT_R = 2.5

# Head outline
HEAD_OUTLINE_SW = 1.5


def scale(v, factor):
    """Scale a number or list of numbers by factor."""
    if isinstance(v, (list, tuple)):
        return [x * factor for x in v]
    return v * factor


def draw_figure(draw, canvas_w, canvas_h):
    """Draw the stick figure onto a PIL ImageDraw, scaling from 108→canvas."""
    W, H = canvas_w, canvas_h
    f_w = W / 108.0
    f_h = H / 108.0  # should be same (square canvas)

    f = lambda v: scale(v, f_w)  # uniform scale helper

    # ── Head fill ──
    cx, cy = f(HEAD_CX), f(HEAD_CY)
    r = f(HEAD_R)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=HEAD_FILL)

    # ── Head outline ──
    sw = max(1, round(f(HEAD_OUTLINE_SW)))
    draw.ellipse([cx - r, cy - r, cx + r, cy + r],
                 outline=HEAD_STROKE, width=sw)

    # ── Body ──
    body_sw = max(1, round(f(BODY_SW)))
    draw.line([f(BODY_X), f(BODY_Y1), f(BODY_X), f(BODY_Y2)],
              fill=BODY_COLOR, width=body_sw)

    # ── Left arm ──
    limb_sw = max(1, round(f(LIMB_SW)))
    draw.line([f(LA_X0), f(LA_Y0), f(LA_X1), f(LA_Y1)],
              fill=BODY_COLOR, width=limb_sw)
    draw.line([f(LA_X1), f(LA_Y1), f(LA_X2), f(LA_Y2)],
              fill=BODY_COLOR, width=limb_sw)

    # ── Right arm ──
    draw.line([f(RA_X0), f(RA_Y0), f(RA_X1), f(RA_Y1)],
              fill=BODY_COLOR, width=limb_sw)
    draw.line([f(RA_X1), f(RA_Y1), f(RA_X2), f(RA_Y2)],
              fill=BODY_COLOR, width=limb_sw)

    # ── Left leg ──
    draw.line([f(LL_X0), f(LL_Y0), f(LL_X1), f(LL_Y1)],
              fill=BODY_COLOR, width=limb_sw)
    draw.line([f(LL_X1), f(LL_Y1), f(LL_X2), f(LL_Y2)],
              fill=BODY_COLOR, width=limb_sw)

    # ── Right leg ──
    draw.line([f(RL_X0), f(RL_Y0), f(RL_X1), f(RL_Y1)],
              fill=BODY_COLOR, width=limb_sw)
    draw.line([f(RL_X1), f(RL_Y1), f(RL_X2), f(RL_Y2)],
              fill=BODY_COLOR, width=limb_sw)

    # ── Hands & feet dots ──
    jr = f(JOINT_R)
    for (jx, jy) in [(LA_X2, LA_Y2), (RA_X2, RA_Y2),
                     (LL_X2, LL_Y2), (RL_X2, RL_Y2)]:
        jx, jy = f(jx), f(jy)
        draw.ellipse([jx - jr, jy - jr, jx + jr, jy + jr], fill=BODY_COLOR)

    # ── Elbow & knee dots ──
    for (jx, jy) in [(LA_X1, LA_Y1), (RA_X1, RA_Y1),
                     (LL_X1, LL_Y1), (RL_X1, RL_Y1)]:
        jx, jy = f(jx), f(jy)
        draw.ellipse([jx - jr * 0.85, jy - jr * 0.85,
                      jx + jr * 0.85, jy + jr * 0.85], fill=BODY_COLOR)

    # ── Left eye (happy squint: upward arc) ──
    eye_sw = max(1, round(f(EYE_SW)))
    # Build arc as quadratic bezier approximated by line segments
    _draw_quadratic_bezier(draw,
        (f(LEYE_X0), f(LEYE_Y0)),
        (f(LEYE_CX), f(LEYE_CY)),
        (f(LEYE_X1), f(LEYE_Y1)),
        EYE_COLOR, eye_sw)

    # ── Right eye ──
    _draw_quadratic_bezier(draw,
        (f(REYE_X0), f(REYE_Y0)),
        (f(REYE_CX), f(REYE_CY)),
        (f(REYE_X1), f(REYE_Y1)),
        EYE_COLOR, eye_sw)

    # ── Mouth (big grin: downward arc) ──
    mouth_sw = max(1, round(f(MOUTH_SW)))
    _draw_quadratic_bezier(draw,
        (f(MOUTH_X0), f(MOUTH_Y0)),
        (f(MOUTH_CX), f(MOUTH_CY)),
        (f(MOUTH_X1), f(MOUTH_Y1)),
        MOUTH_COLOR, mouth_sw)


def _draw_quadratic_bezier(draw, p0, p1, p2, color, width):
    """Approximate a quadratic bezier with line segments."""
    n = 30  # enough segments for smooth curve
    points = []
    for i in range(n):
        t = i / (n - 1)
        # Quadratic bezier: B(t) = (1-t)²P0 + 2(1-t)tP1 + t²P2
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        points.append((x, y))
    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=color, width=width)


# ─── Generate ──────────────────────────────────────────────────────────

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
TARGETS = [
    ("LaunchIcon.png",     200,  200),
    ("LaunchIcon@2x.png",  400,  400),
    ("LaunchIcon@3x.png",  600,  600),
]

for filename, w, h in TARGETS:
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))  # transparent background
    draw = ImageDraw.Draw(img)
    draw_figure(draw, w, h)
    path = os.path.join(OUT_DIR, filename)
    img.save(path, "PNG")
    print(f"  ✓ {filename}  ({w}×{h})  — {os.path.getsize(path)} bytes")

print("Done.")
