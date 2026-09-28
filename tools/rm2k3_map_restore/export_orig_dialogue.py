#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导出原作 L3D 的全部「显示文章」文本（地图事件 + 公共事件），供台词系统取材。

═══ 为什么需要自适应解码 ═══
这个版本是**简体中文汉化版**，但编码并不统一：
- 地图事件正文＝中文（GBK/GB18030）；
- 公共事件正文＝日文原文（Shift-JIS/cp932）。
`dump_orig_events.dec()` 一律 cp932 优先，于是中文正文被解成半角片假名乱码
（`保存当前进度` → `ｱ｣ｴ豬ｱﾇｰｽ`）。本脚本按「解码结果里半角片假名占比」自动选编码。

用法：
    python export_orig_dialogue.py                 # 全部地图 + 公共事件
    python export_orig_dialogue.py --maps 139 137  # 只导出指定地图
    python export_orig_dialogue.py --out FILE      # 指定输出文件
"""
import argparse
import glob
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import (  # noqa: E402
    GAME_DIR, command_list, event_header, ldb_common_events, lmu_events,
)

TEXT_CODES = {
    10110: "Msg",
    10120: "MsgOpt",
    10140: "MsgFace",
}
COMMENT_CODES = {12410, 22410}


def dec_auto(bs):
    """正文解码：在地图事件（中文 gb18030）与公共事件（日文 cp932）之间自适应。"""
    if not bs:
        return ""
    cp = gb = None
    try:
        cp = bs.decode("cp932")
    except Exception:
        pass
    try:
        gb = bs.decode("gb18030")
    except Exception:
        pass
    if cp is None:
        return gb if gb is not None else repr(bs)
    if gb is None:
        return cp
    half = sum(1 for ch in cp if 0xFF61 <= ord(ch) <= 0xFF9F)
    return gb if half * 4 > len(cp) else cp


def dec_name(bs):
    if not bs:
        return ""
    try:
        return bs.decode("cp932")
    except Exception:
        pass
    try:
        return bs.decode("gb18030")
    except Exception:
        return repr(bs)


def load_map_names():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "map_tree.json")
    names = {}
    try:
        data = json.load(io.open(path, encoding="utf-8"))
        for item in data.get("map_tree", []):
            try:
                nm = bytes.fromhex(item["name_raw_hex"]).decode("cp932")
            except Exception:
                nm = item.get("name", "")
            names[item["id"]] = nm
    except Exception as exc:
        print("! map_tree.json 读取失败: %s" % exc)
    return names


def dump_map(map_id, map_names, out):
    path = os.path.join(GAME_DIR, "Map%04d.lmu" % map_id)
    if not os.path.exists(path):
        return 0
    count = 0
    try:
        events = list(lmu_events(path))
    except Exception as exc:
        out.write("\n#### Map%04d 解析失败：%s\n" % (map_id, exc))
        return 0
    title = "Map%04d %s" % (map_id, map_names.get(map_id, ""))
    block = []
    for idx, chunks in events:
        name, x, y, pages = event_header(chunks)
        nm = dec_name(name)
        for pi, pg in enumerate(pages):
            cid, cmds = command_list(pg[1])
            rows = [(c["code"], c.get("str"), c.get("params")) for c in (cmds or [])]
            hits = [r for r in rows if r[0] in TEXT_CODES]
            if not hits:
                continue
            block.append("**事件 #%d「%s」页 %d**（命令块 0x%02X）" % (idx, nm, pi, cid or 0))
            for code, raw, params in rows:
                if code in TEXT_CODES:
                    txt = dec_auto(raw)
                    if code == 10120:
                        block.append("- `MsgOpt` params=%s" % params)
                    elif code == 10140:
                        block.append("- `MsgFace` face=%s" % params)
                    else:
                        block.append("- %s" % txt.replace("\n", " ⏎ "))
            block.append("")
            count += len(hits)
    if block:
        out.write("\n### %s\n\n" % title)
        out.write("\n".join(block) + "\n")
    return count


def dump_common(out):
    count = 0
    path = os.path.join(GAME_DIR, "RPG_RT.ldb")
    if not os.path.exists(path):
        return 0
    for ev in ldb_common_events(path):
        hits = [c for c in ev["cmds"] if c["code"] in TEXT_CODES]
        if not hits:
            continue
        out.write("\n#### 公共事件 #%d「%s」(trigger=%s)\n\n" % (
            ev["id"], dec_name(ev["name"]), ev["trigger"]))
        for c in ev["cmds"]:
            if c["code"] in TEXT_CODES:
                if c["code"] == 10120:
                    out.write("- `MsgOpt` params=%s\n" % c["params"])
                elif c["code"] == 10140:
                    out.write("- `MsgFace` face=%s\n" % c["params"])
                else:
                    out.write("- %s\n" % dec_auto(c.get("str")).replace("\n", " ⏎ "))
        count += len(hits)
    return count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--maps", type=int, nargs="*", default=None)
    ap.add_argument("--out", default="")
    ap.add_argument("--no-common", action="store_true")
    args = ap.parse_args()

    map_names = load_map_names()
    if args.maps:
        ids = args.maps
    else:
        ids = sorted(
            int(os.path.basename(p)[3:7])
            for p in glob.glob(os.path.join(GAME_DIR, "Map*.lmu"))
        )

    buf = io.StringIO()
    buf.write("# 原作 L3D 文本导出（显示文章指令）\n\n")
    buf.write("- 来源目录：`%s`\n" % GAME_DIR)
    buf.write("- 指令：`10110 ShowMessage` / `10140 ShowMessageFace` / `10120 MessageOptions`\n")
    buf.write("- 编码：地图事件正文 gb18030（中文汉化），公共事件正文 cp932（日文原文）—— 自动判别\n\n")

    total = 0
    for map_id in ids:
        total += dump_map(map_id, map_names, buf)

    if not args.no_common:
        buf.write("\n## 公共事件（CommonEvent）\n")
        total += dump_common(buf)

    text = buf.getvalue()
    if args.out:
        io.open(args.out, "w", encoding="utf-8", newline="\n").write(text)
        print("已写出 %s（%d 字符，文本命令 %d 条）" % (args.out, len(text), total))
    else:
        sys.stdout.write(text)
        print("\n=== 文本命令合计 %d 条 ===" % total)


if __name__ == "__main__":
    main()
