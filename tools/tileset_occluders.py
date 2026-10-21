#!/usr/bin/env python3
"""把 TileSet 的墙碰撞多边形复制成遮挡多边形，供内置 2D 灯光（LightOccluder2D）使用。

背景
----
Godot 的 TileSet 有两套互相独立的"形状"数据：
  · physics_layer_N/polygon_M/points    —— 碰撞
  · occlusion_layer_N/polygon_M/polygon —— 遮挡（决定 2D 灯光在哪里投出阴影）
本项目全部 TileSet 只有前者：2108 个墙多边形，0 个遮挡多边形，
所以内置 PointLight2D 打不出任何墙影（现有射线遮挡打的就是这些墙）。

只取"墙层"
----------
一个 TileSet 可能有多个物理层。只有 `physics_layer_N/collision_layer` 含 bit0（=1）的
才是墙体/障碍（现有射线遮挡也是打 collision_layer 1）。例如 Map0145 的
physics_layer_1 是 collision_layer = 32（不是墙），必须跳过。

1:1 复制，不新增不删除不改顶点；同一 tile 上重复的多边形会去重。

序列化格式（Godot 4.6.3 实测，勿凭记忆改）：
    [sub_resource type="OccluderPolygon2D" id="OccluderPolygon2D_xxx"]
    polygon = PackedVector2Array(...)

    <x>:<y>/<alt>/occlusion_layer_0/polygon_0/polygon = SubResource("OccluderPolygon2D_xxx")

    [resource]
    occlusion_layer_0/light_mask = 1

不写 occlusion_layer_0/polygons_count —— Godot 保存时也不写它（派生值）。

用法
----
    python tools/tileset_occluders.py                  # 预览
    python tools/tileset_occluders.py --apply          # 写入 + 自动备份
    python tools/tileset_occluders.py --verify         # 校验落盘结果
    python tools/tileset_occluders.py --force          # 连非墙层也复制（一般不用）
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GLOB = "tres/*.tres"
BACKUP_DIR = ROOT / ".workbuddy" / "tmp" / "occl_backup"

WALL_BIT = 1
PHYS_RE = re.compile(
    r"^(?P<tile>\d+:\d+/\d+)/physics_layer_(?P<layer>\d+)/polygon_(?P<idx>\d+)/points\s*=\s*(?P<value>PackedVector2Array\(.*\))\s*$"
)
OCCL_RE = re.compile(r"^(?P<tile>\d+:\d+/\d+)/occlusion_layer_\d+/polygon_\d+/polygon\s*=\s*(?P<sub>SubResource\(\"([^\"]+)\"\))\s*$")
SUB_ID_RE = re.compile(r'^\[sub_resource type="OccluderPolygon2D" id="(?P<id>[^"]+)"\]$')
TILE_KEY_RE = re.compile(r"^(?P<tile>\d+:\d+/\d+)/")
LAYER_MASK_RE = re.compile(r"^physics_layer_(?P<layer>\d+)/collision_layer\s*=\s*(?P<mask>\d+)\s*$")
ATLAS_HEADER = '[sub_resource type="TileSetAtlasSource"'
MASK_KEY = "occlusion_layer_0/light_mask"


def split_blocks(lines: list[str]) -> list[tuple[str, int, int]]:
    starts = [i for i, ln in enumerate(lines) if ln.startswith("[")]
    out = []
    for n, s in enumerate(starts):
        e = starts[n + 1] if n + 1 < len(starts) else len(lines)
        out.append((lines[s], s, e))
    return out


def wall_layers(block_body: list[str], force: bool) -> set[int] | None:
    """返回墙层索引集合；None 表示"没声明掩码，按全收处理"。"""
    layers: dict[int, int] = {}
    for ln in block_body:
        m = LAYER_MASK_RE.match(ln)
        if m:
            layers[int(m.group("layer"))] = int(m.group("mask"))
    if force or not layers:
        return None
    keep = {i for i, mask in layers.items() if mask & WALL_BIT}
    return keep


def convert_text(text: str, tag: str, force: bool) -> tuple[str, int, int, bool]:
    lines = text.split("\n")
    blocks = split_blocks(lines)

    res_body: list[str] = []
    for header, start, end in blocks:
        if header.startswith("[resource]"):
            res_body = lines[start:end]
    keep = wall_layers(res_body, force)

    new_subs: list[str] = []
    edits: list[tuple[int, list[str]]] = []
    counter = tiles_done = polys_done = 0

    for header, start, end in blocks:
        if not header.startswith(ATLAS_HEADER):
            continue
        body = lines[start:end]

        tile_last: dict[str, int] = {}
        for i, ln in enumerate(body):
            m = TILE_KEY_RE.match(ln)
            if m:
                tile_last[m.group("tile")] = i

        existing: dict[str, set[str]] = defaultdict(set)
        for ln in body:
            m = OCCL_RE.match(ln)
            if m:
                existing[m.group("tile")].add(m.group("sub"))

        per_tile: dict[str, list[str]] = defaultdict(list)
        seen: dict[str, set[str]] = defaultdict(set)
        for ln in body:
            m = PHYS_RE.match(ln)
            if not m:
                continue
            if keep is not None and int(m.group("layer")) not in keep:
                continue
            tile, value = m.group("tile"), m.group("value")
            if value in seen[tile]:
                continue
            seen[tile].add(value)
            if existing.get(tile):
                continue
            counter += 1
            rid = f"OccluderPolygon2D_{tag}{counter}"
            new_subs += [f'[sub_resource type="OccluderPolygon2D" id="{rid}"]', f"polygon = {value}", ""]
            per_tile[tile].append(
                f'{tile}/occlusion_layer_0/polygon_{len(per_tile[tile])}/polygon = SubResource("{rid}")'
            )
            polys_done += 1

        for tile, occ_lines in per_tile.items():
            edits.append((start + tile_last[tile] + 1, occ_lines))
            tiles_done += 1

    for pos, new_lines in sorted(edits, key=lambda x: -x[0]):
        lines[pos:pos] = new_lines

    if new_subs:
        anchor = next((i for i, ln in enumerate(lines) if ln.startswith(ATLAS_HEADER)), None)
        if anchor is None:
            raise RuntimeError("找不到 TileSetAtlasSource 块，文件格式不符")
        lines[anchor:anchor] = new_subs

    mask_changed = False
    for n, ln in enumerate(lines):
        if ln.startswith(MASK_KEY):
            if ln.strip() != f"{MASK_KEY} = 1":
                lines[n] = f"{MASK_KEY} = 1"
                mask_changed = True
            break
    else:
        if polys_done:
            for n, ln in enumerate(lines):
                if ln.startswith("[resource]"):
                    pos = n + 1
                    if pos < len(lines) and lines[pos].startswith("tile_size"):
                        pos += 1
                    lines.insert(pos, f"{MASK_KEY} = 1")
                    mask_changed = True
                    break

    return "\n".join(lines), tiles_done, polys_done, mask_changed


def verify(text: str, force: bool = False) -> tuple[int, int, list[str]]:
    """按"墙层多边形多重集 == 遮挡多边形多重集"逐 **source** 逐 tile 校验。

    注意：同一 .tres 里可以有多个 TileSetAtlasSource，不同 source 会有相同的 tile 坐标
    （例如街道B 有 7 个 source 都含 1:0/0），所以 key 必须带 source 序号。
    """
    lines = text.split("\n")
    sub_poly: dict[str, str] = {}
    for i, ln in enumerate(lines):
        m = SUB_ID_RE.match(ln)
        if m and i + 1 < len(lines) and lines[i + 1].startswith("polygon = "):
            sub_poly[m.group("id")] = lines[i + 1][len("polygon = "):].strip()

    blocks = split_blocks(lines)
    keep = None
    for header, start, end in blocks:
        if header.startswith("[resource]"):
            keep = wall_layers(lines[start:end], force)

    phys: dict[tuple[int, str], list[str]] = defaultdict(list)
    occ: dict[tuple[int, str], list[str]] = defaultdict(list)
    src_idx = -1
    for header, start, end in blocks:
        if header.startswith(ATLAS_HEADER):
            src_idx += 1
        for ln in lines[start:end]:
            m = PHYS_RE.match(ln)
            if m and (keep is None or int(m.group("layer")) in keep):
                key = (src_idx, m.group("tile"))
                if m.group("value") not in phys[key]:
                    phys[key].append(m.group("value"))
                continue
            m2 = OCCL_RE.match(ln)
            if m2:
                rid = re.search(r'SubResource\("([^"]+)"\)', m2.group("sub")).group(1)
                occ[(src_idx, m2.group("tile"))].append(sub_poly.get(rid, "<<子资源缺失>>"))

    problems = []
    for (idx, tile), vals in phys.items():
        have = sorted(occ.get((idx, tile), []))
        if sorted(vals) != have:
            problems.append(f"source#{idx} tile {tile}: 墙碰撞={len(vals)} 遮挡={len(have)}")
    for (idx, tile), vals in occ.items():
        if (idx, tile) not in phys:
            problems.append(f"source#{idx} tile {tile}: 有多余遮挡 {len(vals)} 个")
    return sum(len(v) for v in phys.values()), sum(len(v) for v in occ.values()), problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", help="tres 路径，缺省为 tres/*.tres")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--force", action="store_true", help="不区分墙层，全部物理层都复制")
    args = ap.parse_args()

    files = [Path(p) for p in args.files] if args.files else sorted(ROOT.glob(DEFAULT_GLOB))
    files = [f for f in files if f.is_file()]
    if not files:
        print("没有匹配到文件")
        return 1

    if args.verify:
        bad = 0
        tp = to = 0
        for f in files:
            p, o, probs = verify(f.read_text(encoding="utf-8"), args.force)
            tp += p
            to += o
            if probs:
                bad += 1
                print(f"[FAIL] {f.name}: 墙碰撞={p} 遮挡={o}")
                for msg in probs[:5]:
                    print(f"        {msg}")
            elif p:
                print(f"[ OK ] {f.name}: {p} 墙多边形 / {o} 遮挡多边形")
        print(f"\n校验：{len(files)} 文件，墙={tp} 遮挡={to}，异常={bad}")
        return 1 if bad else 0

    total_tiles = total_polys = touched = 0
    for f in files:
        text = f.read_text(encoding="utf-8")
        new_text, tiles, polys, mask = convert_text(text, f.stem[-4:] + "_", args.force)
        if polys == 0 and not mask:
            continue
        touched += 1
        total_tiles += tiles
        total_polys += polys
        print(f"{f.name}: +{tiles} tile / +{polys} 多边形" + (" (light_mask→1)" if mask else ""))
        if args.apply:
            BACKUP_DIR.mkdir(parents=True, exist_ok=True)
            bak = BACKUP_DIR / f"{f.name}.bak"
            if not bak.exists():
                shutil.copy2(f, bak)
            f.write_text(new_text, encoding="utf-8", newline="\n")

    print(f"\n合计：{touched} 文件，{total_tiles} tile，{total_polys} 遮挡多边形")
    print("已写入磁盘" if args.apply else "预览模式（未写盘），加 --apply 执行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
