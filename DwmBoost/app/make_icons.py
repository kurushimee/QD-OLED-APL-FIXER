#!/usr/bin/env python3
# Renders icon.svg into icon.ico (effect on) and icon_off.ico (effect off, a faded grey copy) for
# DwmBoost.rc. Every size is rendered from the vector, so the small tray sizes stay sharp instead
# of being scaled down from the large one. Needs resvg-py and Pillow. Run: python make_icons.py

import io
from pathlib import Path

import resvg_py
from PIL import Image, ImageOps

HERE = Path(__file__).parent
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]
OFF_OPACITY = 0.55


def render(size):
    png = resvg_py.svg_to_bytes(svg_path=str(HERE / "icon.svg"), width=size, height=size)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def faded(frame):
    grey = ImageOps.grayscale(frame).convert("RGBA")
    grey.putalpha(frame.getchannel("A").point(lambda a: round(a * OFF_OPACITY)))
    return grey


def save_ico(frames, name):
    largest = frames[-1]
    largest.save(HERE / name, format="ICO", sizes=[f.size for f in frames], append_images=frames[:-1])


on = [render(size) for size in SIZES]
save_ico(on, "icon.ico")
save_ico([faded(frame) for frame in on], "icon_off.ico")
