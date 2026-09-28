#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「人类打字机」App 图标:圆角渐变底 + 白色「打」字 + 光标条。"""
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
OUT = "icon_1024.png"
OUT_SMALL = "icon_256.png"
FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def load_font(size):
    for idx in range(8):
        try:
            f = ImageFont.truetype(FONT_PATH, size, index=idx)
            if f.getmask("打").getbbox():
                return f
        except Exception:
            continue
    raise RuntimeError("找不到能显示「打」的字体")


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size, size],
                                        radius=radius, fill=255)
    return m


def main():
    # 背景:纵向渐变靛蓝 -> 宝蓝
    top = (99, 102, 241)
    bottom = (37, 99, 235)
    bg = Image.new("RGB", (SIZE, SIZE), top)
    px = bg.load()
    for y in range(SIZE):
        t = y / (SIZE - 1)
        px_line = tuple(int(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(SIZE):
            px[x, y] = px_line
    bg.putalpha(rounded_mask(SIZE, 232))

    # 顶部高光
    gloss = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    gd = ImageDraw.Draw(gloss)
    gd.rounded_rectangle([0, 0, SIZE, SIZE], radius=232,
                         fill=(255, 255, 255, 34))
    gd.rectangle([0, SIZE // 2, SIZE, SIZE], fill=(255, 255, 255, 0))
    bg = Image.alpha_composite(bg, gloss)

    d = ImageDraw.Draw(bg)
    # 主字「打」
    font = load_font(540)
    d.text((512, 452), "打", font=font, fill=(255, 255, 255, 255),
           anchor="mm")
    # 底部:模拟已打出的文本行 + 闪烁光标
    bar_y, bar_h = 800, 46
    d.rounded_rectangle([252, bar_y, 660, bar_y + bar_h], radius=23,
                        fill=(255, 255, 255, 225))
    d.rounded_rectangle([692, bar_y, 748, bar_y + bar_h], radius=12,
                        fill=(255, 255, 255, 255))

    bg.save(OUT)
    bg.resize((256, 256), Image.LANCZOS).save(OUT_SMALL)
    print(f"OK: {OUT}, {OUT_SMALL}")


if __name__ == "__main__":
    main()
