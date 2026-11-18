#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 RPG Maker VX Ace 的 `Data/Animations.rvdata2` 导出 anim/*.tscn（含真实帧序列）。

依赖：pip install rubymarshal
（自带的 Ruby Marshal 解析器在 RGSS3 的字符串/符号编码上有偏差，改用成熟库。）

用法：
    python tools/anim_import_rvdata2.py --data "E:/某工程/Data/Animations.rvdata2" \
        --out "anim/_imported" --no-copy

规则：
  · 纹理 = animation1_name（pattern < 100）；若全部 pattern >= 100 则用 animation2_name（减 100）。
  · frame_sequence = 每帧第一个 cell 的 pattern —— 与 VX Ace 的「第 i 帧显示第几个图案」一致。
  · 混合双表的动画（既有 <100 又有 >=100）目前只用第一张表，>=100 的帧退回上一帧图案并警告。
  · 素材不复制（--no-copy），生成场景引用 res://art/Animations/<表名>.png。
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

try:
    from rubymarshal.reader import Reader
except ImportError:
    print("[ERROR] 需要 rubymarshal：pip install rubymarshal")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE_HEADER = 20  # Table: dim,x,y,z,count 各 4 字节


def load_animations(path: str) -> list[dict]:
    with open(path, "rb") as f:
        head = f.read(2)
        if head != b"\x04\x08":
            raise ValueError("不是 Ruby Marshal 4.8 文件")
        obj = Reader(f).read()
    out = []
    for item in obj:
        if getattr(item, "ruby_class_name", "") != "RPG::Animation":
            continue
        at = item.attributes
        name = str(at.get("@name") or "").strip()
        frames = at.get("@frames") or []
        cells_per_frame: list[list[dict]] = []
        for fr in frames:
            cd = fr.attributes.get("@cell_data")
            raw = getattr(cd, "_private_data", b"") if cd is not None else b""
            cells_per_frame.append(_decode_cells(raw))
        out.append({
            "id": int(at.get("@id") or 0),
            "name": name,
            "sheet1": str(at.get("@animation1_name") or ""),
            "sheet2": str(at.get("@animation2_name") or ""),
            "frame_max": int(at.get("@frame_max") or 0),
            "frames": cells_per_frame[: int(at.get("@frame_max") or 0)],
        })
    return out


def _decode_cells(raw: bytes) -> list[dict]:
    """RPG::Table：x=同一帧里的第几个 cell，y=字段（8 个）。

    字段顺序（VX Ace，逐字节验证）：pattern, x, y, zoom(100=原始), angle, flip, opacity(255), blend
    """
    if len(raw) < TABLE_HEADER:
        return []
    dim, xs, ys, zs, cnt = struct.unpack_from("<5I", raw, 0)
    if dim != 2 or xs <= 0 or ys < 8:
        return []
    vals = struct.unpack_from("<%dh" % cnt, raw, TABLE_HEADER)
    out = []
    for x in range(xs):
        f = [vals[y * xs + x] for y in range(8)]
        out.append({
            "pattern": f[0], "x": f[1], "y": f[2], "zoom": f[3],
            "angle": f[4], "flip": f[5], "opacity": f[6], "blend": f[7],
        })
    return out


def safe(name: str) -> str:
    for k, v in {"/": "_", "\\": "_", ":": "_", "*": "_", "?": "_",
                 '"': "_", "<": "_", ">": "_", "|": "_"}.items():
        name = name.replace(k, v)
    return name.strip() or "anim"


def write_scene(path: str, texture_res: str, texture2_res: str, frames: list[list[dict]],
                fps: float, h_frames: int = 5) -> None:
    """写多格场景：每帧的每个 cell 变成一条 VXAnimCellData 子资源。"""
    flat: list[tuple[int, dict]] = []
    for fi, cs in enumerate(frames):
        for c in cs:
            flat.append((fi, c))
    lines: list[str] = ["[gd_scene format=3]", ""]
    lines.append('[ext_resource type="Script" path="res://script/vx_anim_sprite.gd" id="1_sprite"]')
    lines.append('[ext_resource type="Script" path="res://script/vx_anim_cell_data.gd" id="2_cell"]')
    lines.append('[ext_resource type="Texture2D" path="%s" id="3_sheet"]' % texture_res)
    if texture2_res:
        lines.append('[ext_resource type="Texture2D" path="%s" id="4_sheet2"]' % texture2_res)
    lines.append("")
    ids: list[str] = []
    for i, (fi, c) in enumerate(flat):
        rid = "cell_%d" % i
        ids.append(rid)
        zoom = (c.get("zoom", 100) or 100) / 100.0
        lines.append('[sub_resource type="Resource" id="%s"]' % rid)
        lines.append('script = ExtResource("2_cell")')
        lines.append("frame_idx = %d" % fi)
        lines.append("pattern = %d" % max(0, int(c.get("pattern", 0))))
        lines.append("offset = Vector2(%d, %d)" % (int(c.get("x", 0)), int(c.get("y", 0))))
        lines.append("scale = Vector2(%s, %s)" % (_num(zoom), _num(zoom)))
        lines.append("rotation_deg = %s" % _num(float(c.get("angle", 0))))
        lines.append("opacity = %s" % _num(float(c.get("opacity", 255)) / 255.0))
        lines.append("blend_mode = %d" % int(c.get("blend", 0)))
        if int(c.get("flip", 0)) != 0:
            lines.append("flip_h = true")
        lines.append("")
    seq = ", ".join(str(i) for i in range(len(frames)))
    lines.append('[node name="AnimEdit" type="Node2D"]')
    lines.append('script = ExtResource("1_sprite")')
    lines.append('texture = ExtResource("3_sheet")')
    if texture2_res:
        lines.append('texture2 = ExtResource("4_sheet2")')
    lines.append("h_frames = %d" % h_frames)
    lines.append("fps = %s" % _num(fps))
    lines.append("frame_sequence = Array[int]([%s])" % seq)
    if ids:
        lines.append('cell_data = Array[ExtResource("2_cell")]([%s])'
                     % ", ".join('SubResource("%s")' % r for r in ids))
    lines.append("")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


def _num(v: float) -> str:
    if abs(v - round(v)) < 1e-6:
        return str(int(round(v)))
    return ("%.4f" % v).rstrip("0").rstrip(".")


def convert(data: str, out_dir: str, art_dir: str, fps: float, prefix: str,
            dry_run: bool, force: bool) -> int:
    anims = load_animations(data)
    print("读到 %d 条动画" % len(anims))
    made = skipped = missing = 0
    used_names: set[str] = set()
    for a in anims:
        frames = a["frames"]
        if not a["name"] or a["frame_max"] <= 0 or not frames:
            skipped += 1
            continue
        n1 = sum(1 for fr in frames for c in fr if 0 <= c["pattern"] < 100)
        n2 = sum(1 for fr in frames for c in fr if c["pattern"] >= 100)
        if n1 == 0 and n2 == 0:
            skipped += 1
            continue
        ## 双表：pattern 原样保留，运行时按 >=100 分发到 texture2（见 VXAnimSprite）。
        ## 只有「第一张表为空」时才把第二张表降级成主表（pattern -100）。
        if not a["sheet1"] and a["sheet2"]:
            sheet = a["sheet2"]
            sheet2 = ""
            mapped = [[dict(c, pattern=c["pattern"] - 100) for c in fr if c["pattern"] >= 100]
                      for fr in frames]
        else:
            sheet = a["sheet1"]
            sheet2 = a["sheet2"] if n2 > 0 else ""
            mapped = frames
        if not sheet:
            skipped += 1
            continue
        for sh in (sheet, sheet2):
            if sh and not os.path.exists(os.path.join(art_dir, sh + ".png")):
                missing += 1
        base = safe(a["name"])
        if base in used_names:
            base = "%s_%d" % (base, a["id"])
        used_names.add(base)
        dst = os.path.join(out_dir, "%s%s.tscn" % (prefix, base))
        if os.path.exists(dst) and not force:
            skipped += 1
            continue
        total_cells = sum(len(fr) for fr in mapped)
        print("  [导出] %-20s 帧=%-3d cell=%-3d 表=%s%s" % (
            a["name"], len(mapped), total_cells, sheet, ("+" + sheet2) if sheet2 else ""))
        if not dry_run:
            write_scene(dst, "res://art/Animations/%s.png" % sheet,
                        ("res://art/Animations/%s.png" % sheet2) if sheet2 else "", mapped, fps)
        made += 1
    print("\n完成：导出 %d，跳过 %d，其中素材缺失 %d%s"
          % (made, skipped, missing, "（dry-run）" if dry_run else ""))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="VX Ace Animations.rvdata2 → anim/*.tscn")
    ap.add_argument("--data", required=True, help="Data/Animations.rvdata2")
    ap.add_argument("--out", default=os.path.join(ROOT, "anim"))
    ap.add_argument("--art", default=os.path.join(ROOT, "art", "Animations"))
    ap.add_argument("--fps", type=float, default=20.0)
    ap.add_argument("--prefix", default="anim_")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    return convert(args.data, args.out, args.art, args.fps, args.prefix, args.dry_run, args.force)


if __name__ == "__main__":
    sys.exit(main())
