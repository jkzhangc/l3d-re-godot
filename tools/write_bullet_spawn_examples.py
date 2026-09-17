# -*- coding: utf-8 -*-
"""给每把远程武器写入 bullet_spawn_offsets 的「默认范例」。

零行为变化原则：范例值 = 该武器子弹当前的 offset_down/up/left/right
（缺失则用 BulletData 默认 down=(0,0) up=(0,0) left=(0,-4) right=(0,-4)），
四个角色各写一份（同值），用户之后在 Inspector 里按各角色枪口像素微调即可。

子弹资源有两种写法，都要支持：
  · 内联 sub_resource（多数武器）
  · 外部 .tres 文件引用（weapon_pistol → object/bullet_pistol.tres 等）

多颗子弹偏移不一致时跳过（bullet_spawn_offsets 是"每武器"粒度，会盖掉逐子弹差异）。

用法：python tools/write_bullet_spawn_examples.py [--check]
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEAPON_GLOB = os.path.join(ROOT, "object", "weapon_*.tres")
CHARS = ["nobita", "shizuka", "suneo", "bigg"]
WSO_SCRIPT_UID = "uid://clc2uli4hs8k0"
WSO_SCRIPT_PATH = "res://script/weapon_effect_offsets.gd"
EXT_ID = "9wspawn"
PROP_ORDER = ["down", "left", "right", "up"]
DEFAULTS = {"down": "(0, 0)", "up": "(0, 0)", "left": "(0, -4)", "right": "(0, -4)"}

OFFSET_RE = re.compile(r'^(offset_down|offset_left|offset_right|offset_up) = Vector2(\(.+\))$')
EXT_RE = re.compile(r'^\[ext_resource type="[^"]*" uid="[^"]*" path="([^"]+)" id="([^"]+)"\]$')
EXT_RE_NOUID = re.compile(r'^\[ext_resource type="[^"]*" path="([^"]+)" id="([^"]+)"\]$')
ITEM_ID_RE = re.compile(r'^item_id = "([^"]+)"', re.M)

check_only = "--check" in sys.argv
report = []


def read_text(path):
    return open(path, "rb").read().decode("utf-8")


def ext_map(lines):
    """ext_resource id -> res:// 路径"""
    out = {}
    for ln in lines:
        m = EXT_RE.match(ln) or EXT_RE_NOUID.match(ln)
        if m:
            out[m.group(2)] = m.group(1)
    return out


def parse_offsets_from_lines(lines, want_script_id=None):
    """按出现顺序收集若干「子弹」块的逐方向偏移；want_script_id=None 表示文件本身就是子弹。"""
    bullets, cur, in_bullet = [], None, want_script_id is None
    for ln in lines:
        if ln.startswith("[sub_resource"):
            cur, in_bullet = None, False
            continue
        if ln.startswith("[resource]"):
            in_bullet = want_script_id is None
            cur = {} if in_bullet else None
            if in_bullet:
                bullets.append(cur)
            continue
        if want_script_id is not None and ln.strip() == 'script = ExtResource("%s")' % want_script_id:
            in_bullet = True
            cur = {}
            bullets.append(cur)
            continue
        if in_bullet and cur is not None:
            m = OFFSET_RE.match(ln)
            if m:
                cur[m.group(1).replace("offset_", "")] = m.group(2)
    return bullets


def bullets_of_weapon(path, text, lines):
    """返回该武器实际使用的子弹偏移列表（内联优先，其次外部 .tres）。"""
    bmap = ext_map(lines)
    inline_ext = None
    for eid, p in bmap.items():
        if p.endswith("script/bullet_data.gd"):
            inline_ext = eid
            break
    bullets = parse_offsets_from_lines(lines, inline_ext) if inline_ext else []
    if not bullets:
        # 外部 BulletData：解析 bullet_list 引用到的 Resource .tres
        m = re.search(r'^bullet_list = Array\[ExtResource\("([^"]+)"\)\]\(\[(.*?)\]\)', text, re.M | re.S)
        if m:
            refs = re.findall(r'ExtResource\("([^"]+)"\)', m.group(2))
            for ref in refs:
                rel = bmap.get(ref)
                if not rel:
                    continue
                ext_path = os.path.join(ROOT, rel.replace("res://", ""))
                if os.path.exists(ext_path):
                    sub = read_text(ext_path).split("\n")
                    bullets.extend(parse_offsets_from_lines(sub, None))
    return bullets


for path in sorted(glob.glob(WEAPON_GLOB)):
    name = os.path.basename(path)
    raw = read_text(path)
    if "bullet_spawn_offsets" in raw:
        report.append((name, "SKIP 已有 bullet_spawn_offsets", 0))
        continue
    lines = raw.split("\n")
    bullets = bullets_of_weapon(path, raw, lines)
    if not bullets:
        report.append((name, "SKIP 近战/无子弹资源", 0))
        continue
    first = bullets[0]
    vals = {k: first.get(k, DEFAULTS[k]) for k in PROP_ORDER}
    if any({k: b.get(k, DEFAULTS[k]) for k in PROP_ORDER} != vals for b in bullets[1:]):
        report.append((name, "SKIP %d 颗子弹偏移不一致，需手动决定" % len(bullets), 0))
        continue
    m = ITEM_ID_RE.search(raw)
    item_id = m.group(1) if m else re.sub(r"[^a-z0-9_]", "_", name[:-5])

    ext_line = ('[ext_resource type="Script" uid="%s" path="%s" id="%s"]'
                % (WSO_SCRIPT_UID, WSO_SCRIPT_PATH, EXT_ID))
    sub_lines = []
    for ch in CHARS:
        sub_lines.append('[sub_resource type="Resource" id="WSO_%s_%s"]' % (item_id, ch))
        sub_lines.append('script = ExtResource("%s")' % EXT_ID)
        for k in PROP_ORDER:
            sub_lines.append("%s = Vector2%s" % (k, vals[k]))
    prop_lines = ["bullet_spawn_offsets = {"]
    for i, ch in enumerate(CHARS):
        comma = "," if i < len(CHARS) - 1 else ""
        prop_lines.append('"%s": SubResource("WSO_%s_%s")%s' % (ch, item_id, ch, comma))
    prop_lines.append("}")

    out = []
    last_ext = max(i for i, ln in enumerate(lines) if ln.startswith("[ext_resource"))
    res_idx = next(i for i, ln in enumerate(lines) if ln.startswith("[resource]"))
    for i, ln in enumerate(lines):
        out.append(ln)
        if i == last_ext:
            out.append(ext_line)
        if i == res_idx - 1:
            out.extend(sub_lines)
    while out and out[-1].strip() == "":
        out.pop()
    out.extend(prop_lines)
    out.append("")
    new_text = "\n".join(out)
    if "\r\n" in raw:
        new_text = new_text.replace("\n", "\r\n")
    if not check_only:
        open(path, "wb").write(new_text.encode("utf-8"))
    report.append((name, "写入 %s（%s）" % (item_id, " ".join("%s%s" % (k, vals[k]) for k in PROP_ORDER)), len(sub_lines)))

print("=== 武器子弹发射点范例 ===")
for name, msg, n in report:
    print("  %-32s %s" % (name, msg))
