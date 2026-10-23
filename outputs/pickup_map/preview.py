# -*- coding: utf-8 -*-
import sys, re, glob, os
sys.path.insert(0, "outputs/pickup_map")
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
        mm = re.search(r'^icon = ExtResource\("([^"]+)"\)', txt, re.M)
        if mm:
            key = mm.group(1)
            for l in txt.splitlines():
                if l.startswith("[ext_resource") and f'id="{key}"' in l:
                    p = re.search(r'path="([^"]+)"', l)
                    if p:
                        icon = p.group(1).replace("res://", "")
        info[iid] = (icon, os.path.basename(f))
    return info

def render(rows, out_prefix, per_img=12):
    SC = 3; IW = 80; IH = 46
    cellw = IW*2 + FW*SC + 26; cellh = FH*SC + 18
    made = []
    for k in range(0, len(rows), per_img):
        chunk = rows[k:k+per_img]
        rr = (len(chunk)+1)//2
        canvas = Image.new("RGBA", (cellw*2, cellh*rr+8), (26,26,30,255))
        d = ImageDraw.Draw(canvas)
        for i, (iid, tres, icon, sk, idx) in enumerate(chunk):
            cx, cy = i % 2, i // 2
            x = cx*cellw+6; y = cy*cellh+16
            if icon and os.path.exists(icon):
                ic = Image.open(icon).convert("RGBA").resize((IW*2, IH*2), Image.NEAREST)
                canvas.alpha_composite(ic, (x, y))
            sheet = Image.open(SHEETS[sk]).convert("RGBA")
            c, r = idx % 4, idx // 4
            ox, oy = c*FW*3, r*FH*4
            sub = sheet.crop((ox+FW, oy, ox+2*FW, oy+FH)).resize((FW*SC, FH*SC), Image.NEAREST)
            canvas.alpha_composite(sub, (x+IW*2+8, y-6))
            d.text((x, cy*cellh+2), f"{iid} [{sk},{idx}] {tres}", fill=(255,225,140,255))
        out = f"{out_prefix}_{k//per_img}.png"
        canvas.save(out)
        made.append(out)
    return made

if __name__ == "__main__":
    info = load_info()
    rows = []
    for iid, (sk, idx) in MAPPING.items():
        icon, tres = info.get(iid, ("", "?MISSING?"))
        rows.append((iid, tres, icon, sk, idx))
    rows.sort(key=lambda r: r[1])
    for o in render(rows, "outputs/sheetcheck/pv"):
        print(o)
