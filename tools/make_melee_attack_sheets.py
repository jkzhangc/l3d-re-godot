# -*- coding: utf-8 -*-
"""为 art/WeaponAttack/<族>/ 生成逐帧标注对照表（棋盘底，2x 原样）。

输出：outputs/melee/sheets/<族>.png
用途：人工核对「哪个编号对应哪个方向 / 哪一帧是前摇、挥砍、后摇」。
"""
import os
import re
import unicodedata

from PIL import Image, ImageDraw

ROOT = "art/WeaponAttack"
OUT = "outputs/melee/sheets"
FULL2ASCII = {chr(0xFF10 + i): str(i) for i in range(10)}

CELL_BG_A = (58, 60, 66)
CELL_BG_B = (78, 80, 88)
PAD = 8
LABEL_H = 16


def num_key(name: str) -> tuple:
    """族内排序：数字升序，同号 B 在数字之后。"""
    m = re.search(r"([０-９]+)([BＣB]?|[（(].*?[)）])?$", name)
    if not m:
        return (999, 0, name)
    digits = "".join(FULL2ASCII.get(c, c) for c in m.group(1))
    suffix = m.group(2) or ""
    return (int(digits), 0 if suffix == "" else 1, suffix)


def checker(w: int, h: int) -> Image.Image:
    img = Image.new("RGBA", (w, h), CELL_BG_A + (255,))
    px = img.load()
    for y in range(h):
        for x in range(w):
            if ((x // 8) + (y // 8)) % 2 == 0:
                px[x, y] = CELL_BG_B + (255,)
    return img


def render_family(fam: str) -> str | None:
    d = os.path.join(ROOT, fam)
    files = sorted([f for f in os.listdir(d) if f.endswith(".png")], key=num_key)
    if not files:
        return None
    ims = [Image.open(os.path.join(d, f)).convert("RGBA") for f in files]
    cw = max(i.width for i in ims) + PAD * 2
    ch = max(i.height for i in ims) + PAD * 2 + LABEL_H
    cols = 4 if len(files) > 8 else min(4, len(files))
    rows = (len(files) + cols - 1) // cols
    canvas = Image.new("RGB", (cw * cols, ch * rows + 22), (26, 26, 30))
    dr = ImageDraw.Draw(canvas)
    dr.text((6, 5), "%s  %d 帧（2x）" % (fam, len(files)), fill=(255, 226, 150))
    for i, (f, im) in enumerate(zip(files, ims)):
        cx, cy = i % cols, i // cols
        x = cx * cw + PAD
        y = cy * ch + 22 + LABEL_H
        plate = checker(im.width, im.height)
        plate.alpha_composite(im)
        canvas.paste(plate.convert("RGB"), (x, y))
        label = os.path.splitext(f)[0][len(fam):] or "(空)"
        label = unicodedata.normalize("NFKC", label)
        dr.text((cx * cw + PAD, cy * ch + 22 + 2), label, fill=(150, 220, 255))
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, fam + ".png")
    canvas.save(path)
    return path


def main() -> None:
    fams = sorted(f for f in os.listdir(ROOT) if os.path.isdir(os.path.join(ROOT, f)))
    made = 0
    for fam in fams:
        if render_family(fam):
            made += 1
    print("生成 %d 张对照表 → %s" % (made, OUT))


if __name__ == "__main__":
    main()
