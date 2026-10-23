# -*- coding: utf-8 -*-
"""对指定物品，输出「图标 + 相似度前 N 候选格」对照条，供人工拍板。"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import match
from PIL import Image, ImageDraw
from catalog import short

FW, FH = 48, 64

GROUPS = {
    "A_long": ["rifle_01", "rifle_02", "rifle_03", "smg_01", "smg_02", "smg_03",
               "shotgun_01", "shotgun_02", "shotgun_03",
               "sniper_01", "sniper_02", "sniper_03", "mg_01", "at_rifle_01"],
    "B_special": ["launcher_01", "launcher_02", "launcher_acid_01", "rocket_01",
                  "rocket_02", "rocket_03", "grenade_01", "flash_01", "bolt_grenade_01",
                  "dynamite_01", "throwing_knife_01", "adrenaline_01",
                  "acid_bottle_01", "nitrogen_01", "first_aid_spray"],
}


def strips(ids, cells, icons, top_n=6, out_prefix="outputs/sheetcheck/pk"):
    made = []
    per_img = 3
    for start in range(0, len(ids), per_img):
        chunk = ids[start:start + per_img]
        rowh = FH * 4 + 34
        iconw = 180
        cellw = 150
        width = iconw + cellw * top_n + 20
        canvas = Image.new("RGBA", (width, rowh * len(chunk) + 8), (24, 24, 28, 255))
        d = ImageDraw.Draw(canvas)
        for i, iid in enumerate(chunk):
            y = i * rowh + 22
            icon = icons[iid]
            ic = Image.open(icon).convert("RGBA").resize((160, 92), Image.NEAREST)
            canvas.alpha_composite(ic, (8, y + 10))
            d.text((8, y - 16), iid, fill=(160, 220, 255, 255))
            ex = match.extract_icon(icon)
            m, col = match.normalize(ex)
            scored = []
            for c in cells:
                s = match.iou(m, c["mask"]) * 2.0 - match.color_dist(col, c["col"]) / 255.0
                scored.append((s, c))
            scored.sort(key=lambda t: -t[0])
            for k, (s, c) in enumerate(scored[:top_n]):
                x = iconw + k * cellw
                crop = c["crop"].resize((c["crop"].width * 3, c["crop"].height * 3), Image.NEAREST)
                if crop.width > cellw - 12:
                    f = (cellw - 12) / crop.width
                    crop = crop.resize((int(crop.width * f), int(crop.height * f)), Image.NEAREST)
                canvas.alpha_composite(crop, (x + 6, y + 30))
                d.text((x + 6, y - 4), "%s#%d %.2f" % (short(c["path"]), c["idx"], s),
                       fill=(255, 226, 150, 255))
        p = "%s_%s_%d.png" % (out_prefix, ids[0], start // per_img)
        canvas.save(p)
        made.append(p)
    return made


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "A_long"
    all_cells = match.cells()
    for c in all_cells:
        im = Image.open(c["path"]).convert("RGBA")
        ci = c["idx"]
        col, row = ci % 4, ci // 4
        cell = im.crop((col * FW * 3 + FW, row * FH * 4, col * FW * 3 + 2 * FW, row * FH * 4 + FH))
        c["crop"] = cell.crop(cell.getbbox())
    icons = dict(match.items())
    ids = GROUPS[which]
    for p in strips(ids, all_cells, icons):
        print(p)


if __name__ == "__main__":
    main()
