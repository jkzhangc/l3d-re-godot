# -*- coding: utf-8 -*-
"""把 art/Weapon 里所有「长条 / 竖条」候选格分页放大，方便人工认图。"""
import glob, os, sys
from PIL import Image, ImageDraw

FW, FH = 48, 64
NAME2K = {"武器オブジェクト": "OBJ", "アタッシュケース": "CASE"}
FULL = {"１": "1", "２": "2", "３": "3", "４": "4", "５": "5", "６": "6",
        "７": "7", "８": "8", "９": "9", "１０": "10", "１１": "11",
        "１２": "12", "１３": "13", "１４": "14"}


def short(p):
    """图集短名：A武器セット４ → A4；[2K-VX]-A武器セット４ → S4（两套不混淆）。"""
    b = os.path.basename(p)
    if b.endswith(".png"):
        b = b[:-4]
    if b.startswith("[2K-VX]-A"):
        rest = b[len("[2K-VX]-A"):]
        if rest in NAME2K:
            return NAME2K[rest]
        if rest.startswith("武器セット") and rest[5:] in FULL:
            return "S" + FULL[rest[5:]]
        return rest
    if b.startswith("A武器セット"):
        rest = b[len("A武器セット"):]
        if rest == "":
            return "A0"
        if rest in FULL:
            return "A" + FULL[rest]
        return "A" + rest
    return b


def collect(min_w=34, min_ratio=1.55, mode="long"):
    out = []
    for p in sorted(glob.glob("art/Weapon/*.png")):
        im = Image.open(p)
        if im.size != (576, 512):
            continue
        im = im.convert("RGBA")
        for ci in range(8):
            c, r = ci % 4, ci // 4
            cell = im.crop((c * FW * 3 + FW, r * FH * 4, c * FW * 3 + 2 * FW, r * FH * 4 + FH))
            bb = cell.getbbox()
            if not bb:
                continue
            w, h = bb[2] - bb[0], bb[3] - bb[1]
            if mode == "long" and w >= min_w and w / h >= min_ratio:
                out.append((p, ci, cell.crop(bb), w, h))
            if mode == "tall" and h >= 22 and h / w >= 1.1:
                out.append((p, ci, cell.crop(bb), w, h))
    return out


def render(cands, out_prefix, per_page=24, cell_px=34):
    cols = 6
    cw = cell_px * 9 + 14
    ch = 22 * 9 + 22
    pages = []
    for start in range(0, len(cands), per_page):
        chunk = cands[start:start + per_page]
        rows = (len(chunk) + cols - 1) // cols
        canvas = Image.new("RGBA", (cw * cols, ch * rows), (24, 24, 28, 255))
        d = ImageDraw.Draw(canvas)
        for i, (p, ci, crop, w, h) in enumerate(chunk):
            sc = min(9, (cell_px * 9) // crop.width, (22 * 9) // crop.height)
            sc = max(2, sc)
            big = crop.resize((crop.width * sc, crop.height * sc), Image.NEAREST)
            cx, cy = i % cols, i // cols
            canvas.alpha_composite(big, (cx * cw + 6, cy * ch + 18))
            d.text((cx * cw + 6, cy * ch + 3), "%s#%d %dx%d" % (short(p), ci, w, h),
                   fill=(255, 220, 120, 255))
        path = "%s_%d.png" % (out_prefix, start // per_page)
        canvas.save(path)
        pages.append(path)
    return pages


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "long"
    cands = collect(mode=mode)
    print(len(cands))
    for p in render(cands, "outputs/sheetcheck/cat_%s" % mode):
        print(p)
