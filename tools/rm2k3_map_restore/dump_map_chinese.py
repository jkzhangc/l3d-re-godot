#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""提取地图里的**汉化正文**（中文台词），避开同文件里的日文原文。

═══ 判据 ═══
同一段字节同时用两种编码解：
- cp932 解出的结果**含平假名/片假名** → 是日文原文（`こうげき`）→ 丢弃；
- 否则 gb18030 解出的是纯汉字串 → 是汉化正文（`这么糟糕的情况`）→ 保留。
这样能把 `偙偆偘偒`（cp932 日文被 gb18030 解出的伪汉字）正确剔除。

用法：python dump_map_chinese.py [map_id ...]   默认 40 139 137 143 145
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import GAME_DIR  # noqa: E402

KANA = re.compile(r"[\u3040-\u30ff]")
HAN = re.compile(r"[\u4e00-\u9fff]")
## 高频字：真·中文句子几乎必然含其中若干；cp932 日文被 gb18030 解出的伪汉字串
## （`乗乗乗`、`晲婍愝抲`、`嚼菽薹`）则一个都不含 → 用它剔除。
COMMON = set(
    "的一是不了在人有我他这那么什么吗啊吧呢但很就也都和与及等对会被把让给"
    "上下前后里外中大小多少好坏新旧来去说想做要看听觉得知道能够可以需"
    "你她它们个位只条张次种样时候地方向点分秒年月日"
    "怪物僵尸安全逃走赶快我们大家先找发现"
)


def _is_real_chinese(text):
    return sum(1 for ch in text if ch in COMMON) >= 2


def _flush(chunks, out, minlen):
    if not chunks:
        return
    raw = b"".join(chunks)
    try:
        cp = raw.decode("cp932")
    except Exception:
        cp = None
    if cp is not None and KANA.search(cp):
        return  # 日文原文
    try:
        gb = raw.decode("gb18030")
    except Exception:
        return
    text = gb.strip()
    if len(text) < minlen or not HAN.search(text):
        return
    if not _is_real_chinese(text):
        return
    if text not in out:
        out.append(text)


def chinese_strings(path, minlen=3):
    bs = open(path, "rb").read()
    out = []
    cur = []
    i = 0
    while i < len(bs):
        if i + 1 < len(bs):
            b1, b2 = bs[i], bs[i + 1]
            if 0x81 <= b1 <= 0xFE and 0x40 <= b2 <= 0xFE and b2 != 0x7F:
                cur.append(bs[i:i + 2])
                i += 2
                continue
        if bs[i] in (0x20, 0x0A, 0x0D):
            cur.append(bytes([bs[i]]))
            i += 1
            continue
        _flush(cur, out, minlen)
        cur = []
        i += 1
    _flush(cur, out, minlen)
    return out


def main():
    ids = [int(a) for a in sys.argv[1:]] or [40, 139, 137, 143, 145]
    for mid in ids:
        path = os.path.join(GAME_DIR, "Map%04d.lmu" % mid)
        print("=" * 78)
        if not os.path.exists(path):
            print("Map%04d 不存在" % mid)
            continue
        strs = chinese_strings(path)
        print("Map%04d  汉化正文 %d 条" % (mid, len(strs)))
        for s in strs:
            print("  | " + s)


if __name__ == "__main__":
    main()
