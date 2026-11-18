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
        pats: list[int] = []
        for fr in frames:
            cd = fr.attributes.get("@cell_data")
            raw = getattr(cd, "_private_data", b"") if cd is not None else b""
            pats.append(struct.unpack_from("<h", raw, TABLE_HEADER)[0] if len(raw) > TABLE_HEADER else -1)
        out.append({
            "id": int(at.get("@id") or 0),
            "name": name,
            "sheet1": str(at.get("@animation1_name") or ""),
            "sheet2": str(at.get("@animation2_name") or ""),
            "frame_max": int(at.get("@frame_max") or 0),
            "patterns": pats[: int(at.get("@frame_max") or 0)],
        })
    return out


def safe(name: str) -> str:
    for k, v in {"/": "_", "\\": "_", ":": "_", "*": "_", "?": "_",
                 '"': "_", "<": "_", ">": "_", "|": "_"}.items():
        name = name.replace(k, v)
    return name.strip() or "anim"


def write_tscn(path: str, texture_res: str, seq: list[int], fps: float, h_frames: int = 5) -> None:
    text = (
        '[gd_scene load_steps=3 format=3]\n\n'
        '[ext_resource type="Script" path="res://script/vx_anim_sprite.gd" id="1_sprite"]\n'
        '[ext_resource type="Texture2D" path="%s" id="2_sheet"]\n\n'
        '[node name="AnimEdit" type="Node2D"]\n'
        'script = ExtResource("1_sprite")\n'
        'texture = ExtResource("2_sheet")\n'
        'h_frames = %d\n'
        'fps = %g\n'
        'frame_sequence = Array[int]([%s])\n'
    ) % (texture_res, h_frames, fps, ", ".join(str(x) for x in seq))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def convert(data: str, out_dir: str, art_dir: str, fps: float, prefix: str,
            dry_run: bool, force: bool) -> int:
    anims = load_animations(data)
    print("读到 %d 条动画" % len(anims))
    made = 0
    skipped = 0
    missing = 0
    used_names: set[str] = set()
    used_names: set[str] = set()
    for a in anims:
        if not a["name"] or a["frame_max"] <= 0 or not a["patterns"]:
            skipped += 1
            continue
        pats = a["patterns"]
        has1 = any(0 <= p < 100 for p in pats)
        has2 = any(p >= 100 for p in pats)
        if has1 and a["sheet1"]:
            sheet = a["sheet1"]
            seq = [p if p < 100 else -1 for p in pats]
        elif has2 and a["sheet2"]:
            sheet = a["sheet2"]
            seq = [p - 100 if p >= 100 else -1 for p in pats]
        else:
            skipped += 1
            continue
        ## 混合双表：>=100 的帧退回上一个有效图案（运行时单纹理做不到两表叠加）
        fixed: list[int] = []
        last = -1
        mixed = False
        for p in seq:
            if p < 0:
                mixed = True
                p = last if last >= 0 else 0
            fixed.append(p)
            last = p
        if mixed:
            print("  [警告] %s：双表混合，>=100 的帧退回上一图案" % a["name"])
        if not os.path.exists(os.path.join(art_dir, sheet + ".png")):
            missing += 1
        ## 重名动画（VX 里允许同名）用 id 区分，避免互相覆盖。
        base = safe(a["name"])
        if base in used_names:
            base = "%s_%d" % (base, a["id"])
        used_names.add(base)
        dst = os.path.join(out_dir, "%s%s.tscn" % (prefix, base))
        if os.path.exists(dst) and not force:
            skipped += 1
            continue
        print("  [导出] %-20s 帧=%-3d 表=%s" % (a["name"], a["frame_max"], sheet))
        if not dry_run:
            write_tscn(dst, "res://art/Animations/%s.png" % sheet, fixed, fps)
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
