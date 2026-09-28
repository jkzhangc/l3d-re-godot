#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全库扫描：在所有 Map*.lmu 与 LDB 里找"像台词"的中文/日文串，定位安全屋角色台词。

两种编码都试（同文件内混合）：gb18030（汉化正文）与 cp932（日文原文）。
判定"像文本"：解出后不含控制字符、长度 >= 4、且以汉字/假名/标点为主。
用法：python scan_l3d_text.py [关键词 ...]
"""
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import GAME_DIR  # noqa: E402

CJK = re.compile(r"[\u4e00-\u9fff]")
KANA = re.compile(r"[\u3040-\u30ff]")
BAD = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def extract(bs, enc):
    """按指定编码抓连续"文本字符"串。"""
    out = []
    cur = []
    i = 0
    while i < len(bs):
        ch = None
        if enc == "gb18030" and i + 1 < len(bs):
            b1, b2 = bs[i], bs[i + 1]
            if 0x81 <= b1 <= 0xFE and 0x40 <= b2 <= 0xFE and b2 != 0x7F:
                try:
                    ch = bytes([b1, b2]).decode("gb18030")
                    i += 2
                except Exception:
                    ch = None
        elif enc == "cp932" and i + 1 < len(bs):
            b1, b2 = bs[i], bs[i + 1]
            if (0x81 <= b1 <= 0x9F or 0xE0 <= b1 <= 0xFC) and 0x40 <= b2 <= 0xFC and b2 != 0x7F:
                try:
                    ch = bytes([b1, b2]).decode("cp932")
                    i += 2
                except Exception:
                    ch = None
        if ch is None:
            i += 1
            if cur:
                s = "".join(cur)
                if len(s) >= 4:
                    out.append(s)
                cur = []
            continue
        if CJK.match(ch) or KANA.match(ch) or ch in "，。！？…、～「」（）·":
            cur.append(ch)
        else:
            if cur:
                s = "".join(cur)
                if len(s) >= 4:
                    out.append(s)
                cur = []
    return out


def looks_like_text(s, want_zh):
    if BAD.search(s):
        return False
    if CJK.search(s) is None:
        return False
    if want_zh:
        # 汉化正文：不应出现假名
        return KANA.search(s) is None
    return True


def main():
    keywords = sys.argv[1:] or ["胖虎", "静香", "小夫", "大雄", "糟糕", "对策"]
    files = sorted(glob.glob(os.path.join(GAME_DIR, "Map*.lmu")))
    files.append(os.path.join(GAME_DIR, "RPG_RT.ldb"))
    print("扫描 %d 个文件，关键词=%s\n" % (len(files), keywords))
    total = 0
    for path in files:
        try:
            bs = open(path, "rb").read()
        except Exception:
            continue
        name = os.path.basename(path)
        for enc, want_zh in (("gb18030", True), ("cp932", False)):
            strs = extract(bs, enc)
            hits = [s for s in strs if looks_like_text(s, want_zh)
                    and any(k in s for k in keywords)]
            if not hits:
                continue
            uniq = []
            for s in hits:
                if s not in uniq:
                    uniq.append(s)
            total += len(uniq)
            print("### %s [%s]  命中 %d" % (name, enc, len(uniq)))
            for s in uniq[:14]:
                print("    " + s[:100])
    print("\n=== 命中总计 %d ===" % total)


if __name__ == "__main__":
    main()
