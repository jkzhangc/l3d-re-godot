#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_item_catalog.py — 全武器/物品/投掷物汇总说明书 + 收藏馆数据

扫描 `object/{weapon,item,throwable}_*.tres`，解析出 id / 名称 / 类型 / 数值 / 图标 / 地面图 /
说明，并合并两条来源信息：
  · `outputs/orig_db/weapon.tsv` / `item_b.tsv` —— 原作 RM2K3 数据库的日文名（用于溯源）；
  · `object/drop_pool_enemy_default.tres` —— 是否在敌人掉落池里（= 能否在关卡里拿到）。

输出
  outputs/catalog/catalog.json   —— 收藏馆 UI 直接吃的数据（`unlock_key` = item_id）
  outputs/catalog/道具武器总表.md —— 人看的说明书

用法：python tools/gen_item_catalog.py
"""
import csv
import json
import os
import re
from pathlib import Path

ROOT = Path(r"D:\!bird's-eye-view-arpg-test-\l3d-re-godot")
OBJ = ROOT / "object"
OUT = ROOT / "outputs" / "catalog"

ITEM_TYPES = ["消耗品", "材料", "关键道具", "武器", "防具", "弹药", "治疗品", "辅助品", "投掷物"]

GROUP_ORDER = ["主武器（远程）", "副武器 / 近战", "治疗品", "辅助品", "投掷物", "消耗品", "弹药", "其它"]


def parse_tres(path: Path):
    txt = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"path=\"res://([^\"]+)\" id=\"([^\"]+)\"", txt)
    exts = {}
    for line in txt.splitlines():
        if line.startswith("[ext_resource"):
            p = re.search(r'path="res://([^"]+)"', line)
            i = re.search(r'\bid="([^"]+)"', line)
            t = re.search(r'type="([^"]+)"', line)
            if p and i:
                exts[i.group(1)] = (p.group(1), t.group(1) if t else "")
    rec = {"file": path.name}
    for key in ("item_id", "item_name", "description"):
        m = re.search(r'^%s = "((?:[^"\\]|\\.)*)"' % key, txt, re.M)
        if m:
            rec[key] = m.group(1).replace('\\"', '"')
    for key in ("item_type", "attack_power", "attack_speed", "critical_rate", "sell_price",
                "magazine_capacity", "max_stack", "max_durability", "melee_range_forward_offset",
                "damage", "throw_range_min", "throw_range_max", "explosion_radius"):
        m = re.search(r"^%s = ([-\d.]+)" % key, txt, re.M)
        if m:
            v = float(m.group(1))
            rec[key] = int(v) if v.is_integer() else v
    for key in ("is_ranged", "ammo_is_infinite"):
        m = re.search(r"^%s = (true|false)" % key, txt, re.M)
        if m:
            rec[key] = m.group(1) == "true"
    # 武器精灵（地面显示 / 攻击动作图）
    for key, out in (("icon", "icon"), ("pickup_texture", "pickup_texture"),
                     ("melee_weapon_sprite", "attack_sheet")):
        m = re.search(r"^%s = ExtResource\(\"([^\"]+)\"\)" % key, txt, re.M)
        if m and m.group(1) in exts:
            rec[out] = exts[m.group(1)][0]
    m = re.search(r"^pickup_char_idx = (\d+)", txt, re.M)
    if m:
        rec["pickup_char_idx"] = int(m.group(1))
    m = re.search(r"^melee_attack_char_sequence = Array\[int\]\(\[([^\]]*)\]\)", txt, re.M)
    if m:
        rec["melee_sequence"] = [int(x) for x in m.group(1).split(",") if x.strip()]
    m = re.search(r"^melee_weapon_sprite_seq_cols = \{(.*?)\}", txt, re.S)
    if m:
        rec["sprite_seq_cols"] = {
            int(k): int(v) for k, v in re.findall(r"(\d+)\s*:\s*(\d+)", m.group(1))}
    rec["script_class"] = ""
    m = re.search(r'^\[gd_resource type="Resource" script_class="([^"]*)"', txt, re.M)
    if m:
        rec["script_class"] = m.group(1)
    return rec


def load_pool():
    p = OBJ / "drop_pool_enemy_default.tres"
    txt = p.read_text(encoding="utf-8", errors="replace")
    paths = {}
    for line in txt.splitlines():
        if line.startswith("[ext_resource"):
            pp = re.search(r'path="res://([^"]+)"', line)
            ii = re.search(r'\bid="([^"]+)"', line)
            if pp and ii:
                paths[ii.group(1)] = pp.group(1)
    m = re.search(r"^items = Array\[Resource\]\(\[(.*?)\]\)$", txt, re.M | re.S)
    w = re.search(r"^weights = Array\[float\]\(\[(.*?)\]\)$", txt, re.M | re.S)
    ids, ws = [], []
    if m:
        for tok in m.group(1).split(","):
            k = re.search(r'ExtResource\("([^"]+)"\)', tok)
            if k:
                ids.append(paths.get(k.group(1), ""))
    if w:
        ws = [float(x) for x in w.group(1).split(",") if x.strip()]
    return dict(zip(ids, ws))


def load_orig_names():
    """原作武器/道具区 → {日文名: id}，用于给新武器标溯源。"""
    out = {}
    for fn, key in (("weapon.tsv", "武器"), ("item_b.tsv", "道具")):
        p = ROOT / "outputs" / "orig_db" / fn
        if not p.exists():
            continue
        for row in csv.DictReader(open(p, encoding="utf-8"), delimiter="\t"):
            nm = (row.get("name_ja") or "").strip()
            if nm:
                out.setdefault(nm, (key, row.get("id", "")))
    return out


def group_of(rec):
    cls = rec.get("script_class", "")
    t = rec.get("item_type", 0)
    if cls == "ThrowableData" or t == 8:
        return "投掷物"
    if cls == "WeaponData" or t == 3:
        return "主武器（远程）" if rec.get("is_ranged") else "副武器 / 近战"
    if t == 6:
        return "治疗品"
    if t == 7:
        return "辅助品"
    if t == 5:
        return "弹药"
    if t == 0:
        return "消耗品"
    return "其它"


def main() -> None:
    pool = load_pool()
    orig = load_orig_names()
    recs = []
    for p in sorted(OBJ.glob("*.tres")):
        if not re.match(r"^(weapon|item|throwable)_", p.name):
            continue
        r = parse_tres(p)
        if not r.get("item_id"):
            continue
        # WeaponData.is_ranged 默认 true —— tres 里只有「近战」才会写出 false，
        # 缺字段时必须当远程，否则所有枪都会被归到近战。
        if r.get("script_class") == "WeaponData" and "is_ranged" not in r:
            r["is_ranged"] = True
        r["group"] = group_of(r)
        r["in_enemy_pool"] = ("object/" + p.name) in pool
        r["pool_weight"] = pool.get("object/" + p.name, 0.0)
        # 原作溯源：项目中文名对不上日文名，用「同名/包含」粗匹配
        r["orig"] = None
        for jp, (kind, oid) in orig.items():
            if jp and (jp == r.get("item_name") or jp in (r.get("description") or "")):
                r["orig"] = {"kind": kind, "id": oid, "name_ja": jp}
                break
        recs.append(r)

    recs.sort(key=lambda x: (GROUP_ORDER.index(x["group"]), x.get("item_id", "")))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "catalog.json").write_text(
        json.dumps({"version": 1, "unlock_key": "item_id", "groups": GROUP_ORDER,
                    "entries": recs}, ensure_ascii=False, indent=2), encoding="utf-8")

    lines = ["# 道具 · 武器总表", "",
             "> 由 `tools/gen_item_catalog.py` 从 `object/*.tres` 自动生成，**改资源后重跑即可**。",
             "> 收藏馆 UI 直接读 `outputs/catalog/catalog.json`，`unlock_key = item_id`"
             "（拿到过的 id 记进存档集合，界面按集合过滤）。", ""]
    for g in GROUP_ORDER:
        rows = [r for r in recs if r["group"] == g]
        if not rows:
            continue
        lines.append("## %s（%d）" % (g, len(rows)))
        lines.append("")
        if g == "副武器 / 近战":
            lines.append("| 名称 | id | 攻击 | 速度 | 暴击 | 攻击帧 | 动作图 | 敌人掉落 | 说明 |")
            lines.append("|---|---|---|---|---|---|---|---|---|")
            for r in rows:
                seq = r.get("melee_sequence") or []
                lines.append("| %s | `%s` | %s | %s | %s | %s | %s | %s | %s |" % (
                    r.get("item_name", ""), r.get("item_id", ""),
                    r.get("attack_power", ""), r.get("attack_speed", ""),
                    ("%g%%" % r["critical_rate"]) if "critical_rate" in r else "",
                    ("%d 帧" % len(seq)) if seq else "—",
                    "有" if r.get("attack_sheet") else "—",
                    ("%.2f" % r["pool_weight"]) if r["in_enemy_pool"] else "—",
                    (r.get("description") or "").replace("|", "/")))
        elif g == "主武器（远程）":
            lines.append("| 名称 | id | 攻击 | 速度 | 暴击 | 弹匣 | 敌人掉落 | 说明 |")
            lines.append("|---|---|---|---|---|---|---|---|")
            for r in rows:
                lines.append("| %s | `%s` | %s | %s | %s | %s | %s | %s |" % (
                    r.get("item_name", ""), r.get("item_id", ""),
                    r.get("attack_power", ""), r.get("attack_speed", ""),
                    ("%g%%" % r["critical_rate"]) if "critical_rate" in r else "",
                    r.get("magazine_capacity", ""),
                    ("%.2f" % r["pool_weight"]) if r["in_enemy_pool"] else "—",
                    (r.get("description") or "").replace("|", "/")))
        elif g == "投掷物":
            lines.append("| 名称 | id | 伤害 | 爆炸半径 | 投掷距离 | 敌人掉落 | 说明 |")
            lines.append("|---|---|---|---|---|---|---|")
            for r in rows:
                lines.append("| %s | `%s` | %s | %s | %s-%s | %s | %s |" % (
                    r.get("item_name", ""), r.get("item_id", ""), r.get("damage", ""),
                    r.get("explosion_radius", ""), r.get("throw_range_min", ""),
                    r.get("throw_range_max", ""),
                    ("%.2f" % r["pool_weight"]) if r["in_enemy_pool"] else "—",
                    (r.get("description") or "").replace("|", "/")))
        else:
            lines.append("| 名称 | id | 售价 | 叠加 | 敌人掉落 | 说明 |")
            lines.append("|---|---|---|---|---|---|")
            for r in rows:
                lines.append("| %s | `%s` | %s | %s | %s | %s |" % (
                    r.get("item_name", ""), r.get("item_id", ""), r.get("sell_price", ""),
                    r.get("max_stack", ""),
                    ("%.2f" % r["pool_weight"]) if r["in_enemy_pool"] else "—",
                    (r.get("description") or "").replace("|", "/")))
        lines.append("")
    totals = {}
    for r in recs:
        totals[r["group"]] = totals.get(r["group"], 0) + 1
    lines.insert(4, "总计 **%d** 项：%s" % (
        len(recs), " · ".join("%s %d" % (k, v) for k, v in totals.items())))
    (OUT / "道具武器总表.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print("条目 %d → %s" % (len(recs), OUT))
    emit_gd(recs)
    for g in GROUP_ORDER:
        n = totals.get(g, 0)
        if n:
            print("  %-14s %3d" % (g, n))
    miss_icon = [r["item_id"] for r in recs if not r.get("icon")]
    if miss_icon:
        print("  缺图标 %d 项：%s" % (len(miss_icon), "、".join(miss_icon[:12])))


GD_HEADER = '''class_name ItemCatalogData extends RefCounted

## ── 架构定位 ──
## 系统：物品总表 ｜ 层：数据（常量表）
## 联机：不涉及
## 职责：全游戏「武器 / 医疗品 / 辅助品 / 投掷物 / 弹药」的静态清单。
## 依赖：被收藏馆界面与调试召唤菜单（Alt+W）读取
##
## ⚠ 本文件由 `tools/gen_item_catalog.py` 生成，**别手改** —— 改完 object/*.tres 重跑生成器。

const ENTRIES: Array[Dictionary] = [
%s
]


## 收藏馆要展示的条目：**弹药不算收藏品**（2026-10-23 用户定），其余全给。
static func collection_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in ENTRIES:
		if str(e.get("group", "")) != "弹药":
			out.append(e)
	return out


## 按分组取条目（分组名见 catalog.json 的 groups）。
static func by_group(group: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in ENTRIES:
		if str(e.get("group", "")) == group:
			out.append(e)
	return out
'''


def emit_gd(recs) -> None:
	rows = []
	for r in recs:
		rows.append('{"id": "%s", "name": "%s", "group": "%s", "path": "res://object/%s"}' % (
			r.get("item_id", ""), (r.get("item_name") or "").replace('"', '\\"'),
			r["group"], r["file"]))
	path = ROOT / "script" / "item_catalog_data.gd"
	path.write_text(GD_HEADER % ",\n".join("\t" + x for x in rows), encoding="utf-8", newline="\n")
	print("  同时生成 %s（%d 条）" % (path, len(rows)))


if __name__ == "__main__":
    main()
