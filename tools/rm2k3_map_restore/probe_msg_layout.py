#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""确认「显示文章」命令的字节布局：围绕 \\C[4] 名字标记打印 hex。"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import GAME_DIR  # noqa: E402

mid = int(sys.argv[1]) if len(sys.argv) > 1 else 139
d = open(os.path.join(GAME_DIR, "Map%04d.lmu" % mid), "rb").read()

pat = b"\\C[4]"
i = d.find(pat)
n = 0
while i >= 0 and n < 3:
    lo = max(0, i - 24)
    hi = min(len(d), i + 90)
    print("=== 偏移 %d ===" % i)
    print("  hex :", d[lo:hi].hex(" "))
    print("  rep :", repr(d[lo:hi]))
    print()
    i = d.find(pat, i + 1)
    n += 1
print("总出现次数:", d.count(pat))
