#!/usr/bin/env python3
"""Render bgrt shine-sweep animation frames for the plymouth script theme.

IMPORTANT: the source logo is a FULL-SCREEN composition (its aspect ratio
matches the phone panel, 1080x2340). We must preserve the logo's position and
size within that frame so the ABL -> plymouth handover is seamless (no shift,
no resize). So we render full-frame images (no cropping / re-centering) and let
bgrt.script scale them to the actual screen at runtime.

Usage:
  ./render-anim.py [path/to/logo.png]
"""
import glob
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

# Full-frame render resolution (the phone panel). Keep the panel aspect ratio.
FRAME_W, FRAME_H = 1080, 2340

SWEEP = 34          # frames of the light sweeping across the text
PAUSE = 8           # frames of dim hold between sweeps
BASE = 0.30         # dim level of the text between sweeps (smaller = stronger)
SIGMA_FRAC = 0.20   # light band width as a fraction of the text span
HI = np.array([180, 222, 255], np.float32)   # cyan-white glint color

DEFAULT_SRC = ("/home/nuanyang/.cursor/projects/"
               "home-nuanyang-k20-source-xiaomi-raphael-uboot/assets/"
               "logo_0-b5e5c3a3-3c37-45a9-936a-69c58b9661d9.png")


def render(src, out_dir):
    # Full-frame composition: scale the whole source to the panel, preserving
    # the logo's designed position and size. (Aspect matches, so no distortion.)
    im = Image.open(src).convert("RGB").resize((FRAME_W, FRAME_H), Image.LANCZOS)
    arr = np.asarray(im).astype(np.float32)

    lum = arr.max(axis=2) / 255.0
    mask = np.clip((lum - 0.05) / 0.95, 0, 1)          # bright text -> 1

    xs = np.arange(FRAME_W)[None, :]
    ys = np.arange(FRAME_H)[:, None]
    d = xs + 0.45 * ys                                  # diagonal sweep axis
    ty, tx = np.where(mask > 0.2)
    dt = tx + 0.45 * ty
    dmin_t, dmax_t = float(dt.min()), float(dt.max())
    span = dmax_t - dmin_t
    sigma = max(120.0, span * SIGMA_FRAC)

    n = SWEEP + PAUSE
    for old in glob.glob(os.path.join(out_dir, "anim-*.png")):
        os.remove(old)

    frames = []
    for f in range(SWEEP):
        t = f / (SWEEP - 1)
        c = (dmin_t - 320) + t * (span + 640)
        band = np.exp(-((d - c) ** 2) / (2 * sigma ** 2))
        factor = BASE + (1.0 - BASE) * band * 1.45      # dim -> overbright
        out = arr * factor[..., None]
        glow_src = (mask * band * 255).astype(np.uint8)
        glow = np.asarray(
            Image.fromarray(glow_src).filter(ImageFilter.GaussianBlur(22))
        ).astype(np.float32) / 255.0
        out = out + glow[..., None] * HI * 1.1
        frames.append(np.clip(out, 0, 255).astype(np.uint8))

    dim = np.clip(arr * BASE, 0, 255).astype(np.uint8)
    for _ in range(PAUSE):
        frames.append(dim)

    for idx, fr in enumerate(frames, start=1):
        Image.fromarray(fr).save(
            os.path.join(out_dir, "anim-%d.png" % idx), optimize=True)

    # Static fallback (full-bright full-frame) for the two-step BGRT path.
    Image.fromarray(arr.astype(np.uint8)).save(
        os.path.join(out_dir, "..", "spinner", "bgrt-fallback.png"),
        optimize=True)

    total = sum(os.path.getsize(os.path.join(out_dir, "anim-%d.png" % i))
                for i in range(1, n + 1))
    print("frame size: %dx%d (full panel)" % (FRAME_W, FRAME_H))
    print("frames: %d, total: %.2f MB" % (n, total / 1024 / 1024))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    if not os.path.isfile(src):
        sys.exit("logo not found: " + src)
    render(src, here)


if __name__ == "__main__":
    main()
