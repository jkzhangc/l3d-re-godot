#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""打印某条中文台词周围的原始 hex（确认命令头字节）。"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import GAME_DIR  # noqa: E402

mid = int(sys.argv[1]) if len(sys.argv) > 1 else 139
key = sys.argv[2] if len(sys.argv) > 2 else "大街上全都是怪物"
back = int(sys.argv[3]) if len(sys.argv) > 3 else 70
fwd = int(sys.argv[4]) if len(sys.argv) > 4 else 130

d = open(os.path.join(GAME_DIR, "Map%04d.lmu" % mid), "rb").read()
pat = key.encode("gb18030")
i = d.find(pat)
print("Map%04d %r 首次出现偏移=%d" % (mid, key, i))
lo = max(0, i - back)
hi = min(len(d), i + fwd)
print("hex:", d[lo:hi].hex(" "))
print("rep:", repr(d[lo:hi]))
