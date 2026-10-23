# -*- coding: utf-8 -*-
"""用图标轮廓在世界图集里找最像的格子。

思路：图标（162x92 圆形徽章）里武器像素可被剥离（底板纯 #414141）；
把图标轮廓与 art/Weapon 每张图集每格（48x64）都归一化成 32x32 的
「填充率图 + 颜色图」，用 IoU + 颜色距离打分排序。
这样映射不依赖人工认图。
"""
import math
import os
import re
import glob
from PIL import Image

FW, FH = 48, 64
N = 32


def extract_icon(path, tol=6, rim=38.0):
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
    bb = out.getbbox()
    return out.crop(bb) if bb else None


def normalize(img):
    """等比缩放到最长边 N，居中放进 NxN，返回 (mask 列表, 颜色列表)。"""
    w, h = img.size
    s = N / max(w, h)
    nw, nh = max(1, int(round(w * s))), max(1, int(round(h * s)))
    small = img.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    canvas.alpha_composite(small, ((N - nw) // 2, (N - nh) // 2))
    px = canvas.load()
    mask = []
    cols = []
    for y in range(N):
        for x in range(N):
            r, g, b, a = px[x, y]
            mask.append(1 if a > 90 else 0)
            cols.append((r, g, b) if a > 90 else None)
    return mask, cols


def iou(m1, m2):
    inter = sum(1 for a, b in zip(m1, m2) if a and b)
    uni = sum(1 for a, b in zip(m1, m2) if a or b)
    return inter / uni if uni else 0.0


def color_dist(c1, c2):
    tot = 0.0
    n = 0
    for a, b in zip(c1, c2):
        if a is None or b is None:
            continue
        tot += math.dist(a, b)
        n += 1
    return tot / n if n else 999.0


def cells():
    """遍历 art/Weapon 下所有 576x512 图集的 8 个格子。"""
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
            crop = cell.crop(bb)
            if crop.width < 6 or crop.height < 6:
                continue
            m, col = normalize(crop)
            if sum(m) < 60:
                continue
            out.append({"path": p, "idx": ci, "mask": m, "col": col,
                        "w": crop.width, "h": crop.height})
    return out


def items():
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
    all_cells = cells()
    print("候选格:", len(all_cells))
    rows = []
    for iid, icon in items():
        ex = extract_icon(icon)
        if ex is None:
            continue
        m, col = normalize(ex)
        scored = []
        for c in all_cells:
            s = iou(m, c["mask"]) * 2.0 - color_dist(col, c["col"]) / 255.0
            scored.append((s, c))
        scored.sort(key=lambda t: -t[0])
        rows.append((iid, icon, scored[:4]))
    for iid, icon, top in rows:
        parts = []
        for s, c in top:
            parts.append("%s#%d(%.2f)" % (os.path.basename(c["path"]).replace("[2K-VX]-A", "").replace(".png", ""), c["idx"], s))
        print("%-22s %s" % (iid, "  ".join(parts)))


if __name__ == "__main__":
    main()
