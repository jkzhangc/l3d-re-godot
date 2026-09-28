#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探针：打印原作四张安全屋地图里所有带文本的事件命令，确认台词位置与编码。

只读原作，不修改。用法：
    python probe_safehouse_text.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import (  # noqa: E402
    GAME_DIR, command_list, dec, event_header, lmu_events,
)

MAPS = [
    (139, "第一章 · 初始安全屋"),
    (137, "第一章 · 结束安全屋"),
    (143, "第二章 · 结束安全屋"),
    (145, "第三章 · 结束安全屋"),
]

for map_id, label in MAPS:
    path = os.path.join(GAME_DIR, "Map%04d.lmu" % map_id)
    print("=" * 72)
    print("Map%04d  %s" % (map_id, label))
    if not os.path.exists(path):
        print("  ! 文件不存在：%s" % path)
        continue
    total = 0
    for idx, chunks in lmu_events(path):
        name, x, y, pages = event_header(chunks)
        nm = dec(name)
        for pi, pg in enumerate(pages):
            cid, cmds = command_list(pg[1])
            texts = [
                (i, c["code"], dec(c["str"]))
                for i, c in enumerate(cmds or [])
                if c.get("str")
            ]
            if not texts:
                continue
            total += len(texts)
            print("  -- 事件#%-3d (%3s,%3s) 「%s」页%d 命令块=0x%02X" % (
                idx, x, y, nm, pi, cid or 0))
            for i, code, s in texts:
                print("       [%3d] code=%-6d %s" % (i, code, s.replace("\n", " ⏎ ")))
    print("  >>> 文本条数 = %d" % total)
