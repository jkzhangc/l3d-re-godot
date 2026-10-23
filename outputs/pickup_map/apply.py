# -*- coding: utf-8 -*-
"""把所有地面拾取物的 pickup_texture / pickup_char_idx / pickup_direction
统一改成与 icon 对应的行走图格。

用法：项目根目录执行
  <python> outputs/pickup_map/apply.py            # 写入
  <python> outputs/pickup_map/apply.py --dry-run  # 只打印
"""
import sys
import os
import re
import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mapping import SHEETS, UIDS, MAPPING

ID_RE = re.compile(r'(?<!u)\bid="([^"]+)"')   # 只取 id="，不取 uid="


def read(p):
    return open(p, encoding="utf-8", newline="").read()


def write(p, s):
    s = s.replace("\r\n", "\n")
    open(p, "w", encoding="utf-8", newline="\n").write(s)


def ext_id_for(lines, res_path):
    """已有指向 res_path 的 ext_resource 就返回其 id，否则 None。"""
    for l in lines:
        if l.startswith("[ext_resource") and f'path="{res_path}"' in l:
            m = ID_RE.search(l)
            if m:
                return m.group(1)
    return None


def used_ids(text):
    return set(re.findall(r'ExtResource\("([^"]+)"\)', text))


def apply_one(tres_path, sheet_path, uid, idx, dry_run=False):
    res_path = "res://" + sheet_path
    s = read(tres_path)
    lines = s.split("\n")

    rid = ext_id_for(lines, res_path)
    new_ext = None
    if rid is None:
        rid = "pickup_tex"
        n = 1
        ids = {ID_RE.search(l).group(1) for l in lines if l.startswith("[ext_resource")}
        while rid in ids:
            n += 1
            rid = "pickup_tex%d" % n
        new_ext = ('[ext_resource type="Texture2D" uid="%s" path="%s" id="%s"]'
                   % (uid, res_path, rid))

    def find_prop(key):
        for i, l in enumerate(lines):
            if l.startswith(key + " = "):
                return i
        return None

    def set_prop(key, value, after_key):
        """替换已有行；没有就插到 after_key 之后（都没有则插到 [resource] 之后）。"""
        cur = find_prop(key)
        if cur is not None:
            lines[cur] = "%s = %s" % (key, value)
            return
        anchor = find_prop(after_key) if after_key else None
        if anchor is None:
            anchor = find_prop("pickup_texture")
        if anchor is None:
            for i, l in enumerate(lines):
                if l.startswith("script = "):
                    anchor = i
        if anchor is None:
            for i, l in enumerate(lines):
                if l.startswith("[resource]"):
                    anchor = i
        lines.insert(anchor + 1, "%s = %s" % (key, value))

    set_prop("pickup_texture", 'ExtResource("%s")' % rid, None)
    set_prop("pickup_char_idx", str(idx), "pickup_texture")
    set_prop("pickup_direction", "0", "pickup_char_idx")

    if new_ext:
        last_ext = max(i for i, l in enumerate(lines) if l.startswith("[ext_resource"))
        insert_block = [new_ext]
        if lines[last_ext + 1].strip() != "":
            insert_block.append("")
        for offset, item in enumerate(insert_block):
            lines.insert(last_ext + 1 + offset, item)

    text = "\n".join(lines)
    # 不动既有的 ext_resource 集合：Godot 自带的 uid 行与"当前未引用"的条目一律保留，
    # 避免无关 diff（删掉 anim/audio 的 ext_resource 属于多余改动）。
    text = re.sub(r"\n{3,}", "\n\n", text)
    if not text.endswith("\n"):
        text += "\n"
    if not dry_run:
        write(tres_path, text)
    return rid


def main():
    dry = "--dry-run" in sys.argv
    rows = []
    for f in sorted(glob.glob("object/*.tres")):
        s = read(f)
        m = re.search(r'^item_id = "([^"]*)"', s, re.M)
        if not m or m.group(1) not in MAPPING:
            continue
        sk, idx = MAPPING[m.group(1)]
        rid = apply_one(f, SHEETS[sk], UIDS[sk], idx, dry)
        rows.append((os.path.basename(f), m.group(1), sk, idx, rid))
    for r in rows:
        print("%-30s %-22s %-4s %d  ext=%s" % r)
    print("total", len(rows), "dry_run" if dry else "written")


if __name__ == "__main__":
    main()
