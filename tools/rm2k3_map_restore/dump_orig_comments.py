#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dump_orig_comments.py — 导出原作 RM2K3 的公共事件 / 地图事件的**名称 + 注釈**（Shift-JIS → UTF-8）

原作 `RPG_RT.ldb` / `Map*.lmu` 里的文本是 **Shift-JIS**；用中文版工具或按 GBK 打开会变成
`5昩娫偩偗傑偭偰傗傞` 这种乱码（SJIS 字节被当成 GBK 解）。本脚本一律按 cp932 解，
并把「注釈」命令（RM2K3 code=10110，续行 20110）按原始缩进合并成一段。

用法：
    python tools/rm2k3_map_restore/dump_orig_comments.py common
    python tools/rm2k3_map_restore/dump_orig_comments.py maps
    python tools/rm2k3_map_restore/dump_orig_comments.py maps --map 21

产物：`outputs/orig_db/公共事件_名称与注釈.md` / `地图事件_名称与注釈.md`
"""
import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dump_orig_events as D  # noqa: E402

GAME_DIR = r"D:/15.L3D"
OUT_DIR = "outputs/orig_db"
## RM2K3 命令码：10110/20110 是「显示文章」及其续行（会误当成注释），
## **12410 / 22410 才是「注釈」及其续行**（实测本作 3671 / 7280 条）。
COMMENT = 12410
COMMENT_CONT = 22410


def comments_of(cmds):
    """把 10110 + 后续 20110 合并成文本行，保留缩进层级（用 '·' 表示层级）。"""
    out = []
    in_comment = False
    for c in cmds:
        if c["code"] == COMMENT:
            in_comment = True
            out.append((c["indent"], D.dec(c["str"])))
        elif c["code"] == COMMENT_CONT and in_comment:
            out.append((c["indent"], D.dec(c["str"])))
        else:
            in_comment = False
    return out


def fmt(lines):
    return "\n".join("%s%s" % ("  " * max(indent, 0), text) for indent, text in lines)


def dump_common():
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "公共事件_名称与注釈.md")
    evs = D.ldb_common_events(os.path.join(GAME_DIR, "RPG_RT.ldb"))
    n_with = 0
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# 原作 L3D · 公共事件名称与注釈\n\n")
        f.write("来源 `RPG_RT.ldb`（Shift-JIS → UTF-8）。`trigger`："
                "0=呼叫 1=自动 2=并行 … 具体值按 RM2K3 语义。\n\n")
        for ev in evs:
            name = D.dec(ev["name"]).strip()
            lines = comments_of(ev["cmds"])
            if lines:
                n_with += 1
            f.write("## #%d %s\n\n" % (ev["id"], name if name else "（无名）"))
            f.write("- trigger=%s，命令 %d 条\n" % (ev["trigger"], len(ev["cmds"])))
            if lines:
                f.write("\n```text\n%s\n```\n" % fmt(lines))
            f.write("\n")
    print("公共事件 %d 个（含注釈 %d 个）→ %s" % (len(evs), n_with, path))


def dump_maps(only_map):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "地图事件_名称与注釈.md")
    files = sorted(glob.glob(os.path.join(GAME_DIR, "Map*.lmu")))
    if only_map is not None:
        files = [f for f in files if os.path.basename(f) == "Map%04d.lmu" % only_map]
    total_ev = 0
    total_cmt = 0
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# 原作 L3D · 地图事件名称与注釈\n\n")
        f.write("来源 `Map*.lmu`（Shift-JIS → UTF-8）。只列出**有名字或有注釈**的事件。\n\n")
        for fp in files:
            try:
                evs = D.lmu_events(fp)
            except (IndexError, ValueError) as e:
                print("跳过 %s：%s" % (os.path.basename(fp), e))
                continue
            rows = []
            for idx, chunks in evs:
                name, x, y, pages = D.event_header(chunks)
                nm = D.dec(name).strip()
                cmts = []
                for _pi, pg in enumerate(pages):
                    _cid, cmds = D.command_list(pg[1])
                    cmts.extend(comments_of(cmds or []))
                if not nm and not cmts:
                    continue
                rows.append((idx, x, y, nm, cmts))
            if not rows:
                continue
            f.write("## %s（%d 个事件）\n\n" % (os.path.basename(fp), len(rows)))
            for idx, x, y, nm, cmts in rows:
                total_ev += 1
                total_cmt += 1 if cmts else 0
                ## 部分地图（无图块层的事件页）没有 0x02/0x03 chunk → 坐标显示 "?"
                xs = "?" if x is None else x
                ys = "?" if y is None else y
                f.write("### #%d (%s,%s) %s\n\n" % (idx, xs, ys, nm if nm else "（无名）"))
                if cmts:
                    f.write("\n```text\n%s\n```\n" % fmt(cmts))
                f.write("\n")
    print("地图事件 %d 个（含注釈 %d 个）→ %s" % (total_ev, total_cmt, path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["common", "maps"])
    ap.add_argument("--map", type=int, default=None)
    a = ap.parse_args()
    if a.mode == "common":
        dump_common()
    else:
        dump_maps(a.map)


if __name__ == "__main__":
    main()
