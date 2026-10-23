# -*- coding: utf-8 -*-
"""生成验收对照图：图标 / 地面精灵 1x / 地面精灵 3x。"""
import sys, os, re, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mapping import SHEETS, MAPPING
from PIL import Image, ImageDraw

FW, FH = 48, 64


def load_info():
    info = {}
    for f in sorted(glob.glob("object/*.tres")):
        txt = open(f, encoding="utf-8", errors="replace").read()
        m = re.search(r'^item_id = "([^"]*)"', txt, re.M)
        if not m:
            continue
        iid = m.group(1)
        icon = ""
        mm = re.search(r'(?<!u)\bicon = ExtResource\("([^"]+)"\)', txt, re.M)
        if mm:
            key = mm.group(1)
            for l in txt.splitlines():
                if l.startswith("[ext_resource") and f'id="{key}"' in l:
                    p = re.search(r'path="([^"]+)"', l)
                    if p:
                        icon = p.group(1).replace("res://", "")
        name = ""
        mn = re.search(r'^item_name = "([^"]*)"', txt, re.M)
        if mn:
            name = mn.group(1)
        info[iid] = (icon, name)
    return info


def main():
    info = load_info()
    rows = []
    for iid, (sk, idx) in MAPPING.items():
        icon, name = info.get(iid, ("", ""))
        rows.append((iid, name, icon, sk, idx))
    rows.sort(key=lambda r: (0 if "weapon" not in r[0] else 0, r[0]))

    SC = 3
    row_h = FH * SC + 26
    col_w = 170 + 60 + FW * SC + 24
    cols = 2
    per = 14
    for page in range(0, len(rows), per):
        chunk = rows[page:page + per]
        nr = (len(chunk) + cols - 1) // cols
        canvas = Image.new("RGBA", (col_w * cols, row_h * nr + 10), (22, 22, 26, 255))
        d = ImageDraw.Draw(canvas)
        for i, (iid, name, icon, sk, idx) in enumerate(chunk):
            cx, cy = i // cols, i % cols
            x = cy * col_w + 8
            y = cx * row_h + 20
            # 图标 1x
            if icon and os.path.exists(icon):
                ic = Image.open(icon).convert("RGBA")
                canvas.alpha_composite(ic, (x, y + 6))
            # 地面精灵 1x（灰底，模拟地面）
            sheet = Image.open(SHEETS[sk]).convert("RGBA")
            c, r = idx % 4, idx // 4
            ox, oy = c * FW * 3, r * FH * 4
            cell = sheet.crop((ox + FW, oy, ox + 2 * FW, oy + FH))
            plate = Image.new("RGBA", (FW + 8, FH + 8), (92, 96, 92, 255))
            plate.alpha_composite(cell, (4, 4))
            canvas.alpha_composite(plate, (x + 170, y + 2))
            # 3x
            big = Image.new("RGBA", (FW * SC + 8, FH * SC + 8), (92, 96, 92, 255))
            big.alpha_composite(cell.resize((FW * SC, FH * SC), Image.NEAREST), (4, 4))
            canvas.alpha_composite(big, (x + 170 + 62, y))
            d.text((x, (cx * row_h) + 3), "%s  %s  [%s,%d]" % (iid, name, sk, idx),
                   fill=(255, 226, 150, 255))
        out = "outputs/sheetcheck/accept_%d.png" % (page // per)
        canvas.save(out)
        print(out, canvas.size)


if __name__ == "__main__":
    main()
