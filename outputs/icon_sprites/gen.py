# -*- coding: utf-8 -*-
"""从 Ui 图标剥离出地面精灵（48x64 格，底部对齐，与既有地面精灵同尺度）。

- 底板为纯 #414141 圆形，内圆 r<=38 之外一律丢弃；
- 命中底板色(±6)的像素视为底板，其余为武器/道具像素；
- 宽度 >46 或高度 >62 时按整数 1/2 降采样（保持像素栅格），否则 1:1；
- 结果贴到 48x64 画布，水平居中、底边对齐 y=62（与 [2K-VX]-A武器セット 一致）。
"""
import math
import os
import sys
import glob
import re
from PIL import Image

FW, FH = 48, 64
BOTTOM = 62
MAX_W, MAX_H = 46, 62


def extract(path, tol=6, rim=38.0):
    im = Image.open(path).convert("RGBA")
    px = im.load()
    W, H = im.size
    cx, cy = (W - 1) / 2, (H - 1) / 2
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    po = out.load()
    for y in range(H):
        for x in range(W):
            r, g, b, a = px[x, y]
            if a < 200:
                continue
            if math.hypot(x - cx, y - cy) > rim:
                continue
            if abs(r - 65) <= tol and abs(g - 65) <= tol and abs(b - 65) <= tol:
                continue
            po[x, y] = (r, g, b, 255)
    return out


def to_cell(icon_path):
    ex = extract(icon_path)
    bb = ex.getbbox()
    if not bb:
        return None, "提取为空"
    crop = ex.crop(bb)
    # 图标里武器画得比地面图大 1.6~1.9 倍 → 统一 1/2 降到地面尺度
    factor = 2
    while crop.width / factor > MAX_W or crop.height / factor > MAX_H:
        factor *= 2
    if factor > 1:
        nw = max(1, int(round(crop.width / factor)))
        nh = max(1, int(round(crop.height / factor)))
        crop = crop.resize((nw, nh), Image.NEAREST)
    cell = Image.new("RGBA", (FW, FH), (0, 0, 0, 0))
    x = (FW - crop.width) // 2
    y = BOTTOM - crop.height
    cell.alpha_composite(crop, (x, max(0, y)))
    return cell, "%dx%d@1/%d" % (crop.width, crop.height, factor)


def item_icons():
    out = []
    for f in sorted(glob.glob("object/*.tres")):
        txt = open(f, encoding="utf-8", errors="replace").read()
        m = re.search(r'^item_id = "([^"]*)"', txt, re.M)
        if not m:
            continue
        mm = re.search(r'(?<!u)\bicon = ExtResource\("([^"]+)"\)', txt, re.M)
        if not mm:
            continue
        key = mm.group(1)
        icon = ""
        for l in txt.splitlines():
            if l.startswith("[ext_resource") and f'id="{key}"' in l:
                p = re.search(r'path="([^"]+)"', l)
                if p:
                    icon = p.group(1).replace("res://", "")
        if icon:
            out.append((m.group(1), icon))
    return out


def main():
    os.makedirs("outputs/icon_sprites/cells", exist_ok=True)
    rows = []
    for iid, icon in item_icons():
        cell, note = to_cell(icon)
        if cell is None:
            print("!!", iid, icon, note)
            continue
        cell.save("outputs/icon_sprites/cells/%s.png" % iid)
        rows.append((iid, icon, cell, note))
    print("生成", len(rows), "张")
    # 对照图
    from PIL import ImageDraw
    per_col = 12
    SC = 2
    cellw = 170 + FW * SC + 18
    cellh = FH * SC + 20
    for page in range(0, len(rows), per_col):
        chunk = rows[page:page + per_col]
        canvas = Image.new("RGBA", (cellw * 2, cellh * ((len(chunk) + 1) // 2) + 8), (26, 26, 30, 255))
        d = ImageDraw.Draw(canvas)
        for i, (iid, icon, cell, note) in enumerate(chunk):
            cx0, cy0 = i % 2, i // 2
            x = cx0 * cellw + 6
            y = cy0 * cellh + 16
            ic = Image.open(icon).convert("RGBA")
            canvas.alpha_composite(ic, (x, y))
            plate = Image.new("RGBA", (FW * SC + 8, FH * SC + 8), (92, 96, 92, 255))
            plate.alpha_composite(cell.resize((FW * SC, FH * SC), Image.NEAREST), (4, 4))
            canvas.alpha_composite(plate, (x + 168, y - 4))
            d.text((x, cy0 * cellh + 3), "%s  %s" % (iid, note), fill=(255, 226, 150, 255))
        canvas.save("outputs/icon_sprites/demo_%d.png" % (page // per_col))
        print("outputs/icon_sprites/demo_%d.png" % (page // per_col))


if __name__ == "__main__":
    main()
