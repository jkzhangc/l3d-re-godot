#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""add_melee_to_safehouse_pools.py — 把新增的近战武器补进各安全屋「近战类」随机拾取池

安全屋里 `近战类` / `近战类2` / `近战类3` 都是 `random_pickup.tscn` 实例，
共用同一个 `DropPoolData` 子资源（`pool = SubResource(...)`）。
本工具按**子资源去重**往池里追加：同一个池被 3 个节点共用时只加一次。

用法：
    python tools/add_melee_to_safehouse_pools.py --dry
    python tools/add_melee_to_safehouse_pools.py
"""
import os
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(r"D:\!bird's-eye-view-arpg-test-\l3d-re-godot")
MAPS = ROOT / "scene" / "maps"

## 追加的近战武器与权重（与敌人掉落池同档）
ADD = [
    ("weapon_combat_knife", 0.10),
    ("weapon_knuckles", 0.10),
    ("weapon_pipe", 0.08),
    ("weapon_shovel", 0.06),
    ("weapon_fire_axe", 0.05),
    ("weapon_uchigatana", 0.05),
    ("weapon_sledgehammer", 0.03),
]
NODE_PREFIX = "近战类"


def write_atomic(p: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), suffix=".tmp")
    os.close(fd)
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text if text.endswith("\n") else text + "\n")
    os.replace(tmp, p)


def process(p: Path, dry: bool) -> int:
    text = p.read_text(encoding="utf-8")
    # 1) 节点名 → pool 子资源 id
    pools = set()
    for m in re.finditer(r'\[node name="([^"]+)"[^\]]*\]\n((?:(?!\[node )[^\n]*\n)*)', text):
        name, body = m.group(1), m.group(2)
        if not name.startswith(NODE_PREFIX):
            continue
        pm = re.search(r"pool = SubResource\(\"([^\"]+)\"\)", body)
        if pm:
            pools.add(pm.group(1))
    if not pools:
        return 0
    # 2) 现有 ext_resource（按 path 找 id，避免重复声明）
    by_path = {}
    used_ids = set()
    for line in text.splitlines():
        if line.startswith("[ext_resource"):
            i = re.search(r'\bid="([^"]+)"', line)
            pp = re.search(r'path="res://([^"]+)"', line)
            if i:
                used_ids.add(i.group(1))
            if i and pp:
                by_path[pp.group(1)] = i.group(1)
    # 3) 为缺的武器补 ext_resource
    new_ext = []
    n = 60
    for name, _w in ADD:
        rel = "object/%s.tres" % name
        if rel in by_path:
            continue
        while str(n) in used_ids:
            n += 1
        eid = str(n)
        used_ids.add(eid)
        n += 1
        by_path[rel] = eid
        new_ext.append('[ext_resource type="Resource" path="res://%s" id="%s"]' % (rel, eid))
    if new_ext:
        lines = text.split("\n")
        last = max(i for i, l in enumerate(lines) if l.startswith("[ext_resource"))
        for k, line in enumerate(new_ext):
            lines.insert(last + 1 + k, line)
        text = "\n".join(lines)
    # 4) 每个池追加 items/weights
    added_pools = 0
    for pid in sorted(pools):
        m = re.search(r'\[sub_resource type="Resource" id="%s"\]\n(.*?)(?=\n\[|\Z)'
                      % re.escape(pid), text, re.S)
        if not m:
            continue
        block = m.group(0)
        im = re.search(r"^items = Array\[Resource\]\(\[(.*?)\]\)$", block, re.M | re.S)
        wm = re.search(r"^weights = Array\[float\]\(\[(.*?)\]\)$", block, re.M | re.S)
        if not im:
            continue
        it = [x.strip() for x in im.group(1).split(",") if x.strip()]
        wt = [x.strip() for x in wm.group(1).split(",") if x.strip()] if wm else []
        if wt and len(it) != len(wt):
            print("  !! %s 池 %s items=%d weights=%d 不一致，跳过" % (p.name, pid, len(it), len(wt)))
            continue
        for name, w in ADD:
            tok = 'ExtResource("%s")' % by_path["object/%s.tres" % name]
            if tok in it:
                continue
            it.append(tok)
            if wt:
                wt.append("%.2f" % w)
        new_block = block
        new_block = re.sub(r"^items = Array\[Resource\]\(\[.*?\]\)$",
                           "items = Array[Resource]([%s])" % ", ".join(it),
                           new_block, count=1, flags=re.M | re.S)
        if wt:
            new_block = re.sub(r"^weights = Array\[float\]\(\[.*?\]\)$",
                               "weights = Array[float]([%s])" % ", ".join(wt),
                               new_block, count=1, flags=re.M | re.S)
        text = text.replace(block, new_block, 1)
        added_pools += 1
    print("%-46s 池 %d 个（%s）" % (p.name, added_pools, ", ".join(sorted(pools))))
    if not dry:
        write_atomic(p, text)
    return added_pools


def main() -> None:
    dry = "--dry" in sys.argv
    total = 0
    for p in sorted(MAPS.glob("*安全屋*.tscn")):
        total += process(p, dry)
    print("\n共处理 %d 个池%s" % (total, "（dry run）" if dry else ""))


if __name__ == "__main__":
    main()
