#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探针 v2：用 **gb18030 优先** 解码，打印安全屋/起始点地图里的显示文章序列。

背景：`dump_orig_events.dec()` 为了事件名（Shift-JIS）而 cp932 优先，
但 **正文台词是简体中文（GBK/GB18030）** —— cp932 能"成功"解出半角片假名乱码，
于是正文全变 `ｱ｣ｴ豬ｱ`。本探针改为 gb18030 优先，专门看正文。

用法：python probe_safehouse_text2.py [map_id ...]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import GAME_DIR, command_list, event_header, lmu_events  # noqa: E402

TEXT_CODES = {
    10110: "ShowMessage",
    10120: "MessageOptions",
    10140: "ShowMessageFace",
    10150: "MessageFaceSettings",
}


def dec_text(bs):
    """正文字节 → 文本：**gb18030 优先**（简体中文版），失败再退 cp932。"""
    if not bs:
        return ""
    for enc in ("gb18030", "cp932"):
        try:
            return bs.decode(enc)
        except Exception:
            continue
    return repr(bs)


def main():
    maps = [int(a) for a in sys.argv[1:]] or [139, 137, 143, 145]
    for map_id in maps:
        path = os.path.join(GAME_DIR, "Map%04d.lmu" % map_id)
        print("=" * 78)
        print("Map%04d" % map_id)
        if not os.path.exists(path):
            print("  ! 不存在")
            continue
        for idx, chunks in lmu_events(path):
            name, x, y, pages = event_header(chunks)
            nm = name.decode("cp932", "replace") if isinstance(name, bytes) else str(name)
            for pi, pg in enumerate(pages):
                cid, cmds = command_list(pg[1])
                hits = [c for c in (cmds or []) if c["code"] in TEXT_CODES]
                if not hits:
                    continue
                print("  -- #%d 「%s」页%d 块=0x%02X  文本命令 %d 条" % (
                    idx, nm, pi, cid or 0, len(hits)))
                for c in cmds or []:
                    code = c["code"]
                    if code in TEXT_CODES:
                        t = dec_text(c.get("str"))
                        tag = TEXT_CODES[code]
                        if code == 10120:
                            print("       [%s] params=%s" % (tag, c["params"]))
                        else:
                            print("       [%s] %r" % (tag, t))
                    elif code in (12410, 22410):
                        t = dec_text(c.get("str"))
                        if t and "―――" not in t:
                            print("       (注释) %s" % t[:70])


if __name__ == "__main__":
    main()
