#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按**字节偏移**定位台词落在哪个 事件 / 页 / chunk（结构解析会漏，所以走偏移).

用法：python locate_dialogue.py <map_id> [关键词]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_lcf import ber, chunks_of  # noqa: E402
from dump_orig_events import GAME_DIR  # noqa: E402

KANA = re.compile(r"[\u3040-\u30ff]")


def parse_array_off(buf, pos, end):
    """和 parse_chunk_array 一样，但记录每个元素的字节范围。"""
    count, pos = ber(buf, pos)
    out = []
    for _ in range(count):
        idx, pos = ber(buf, pos)
        st = pos
        chunks = {}
        while pos < end:
            cid, pos = ber(buf, pos)
            if cid == 0:
                break
            ln, pos = ber(buf, pos)
            chunks[cid] = (pos, pos + ln)
            pos += ln
        out.append((idx, st, pos, chunks))
    return out


def dec2(bs):
    """混合编码自适应：cp932 出假名则用 cp932，否则 gb18030。"""
    if not bs:
        return ""
    try:
        cp = bs.decode("cp932")
    except Exception:
        cp = None
    try:
        gb = bs.decode("gb18030")
    except Exception:
        gb = None
    if cp is not None and KANA.search(cp):
        return cp
    if gb is not None:
        return gb
    return cp if cp is not None else repr(bs)


def main():
    mid = int(sys.argv[1]) if len(sys.argv) > 1 else 139
    key = sys.argv[2] if len(sys.argv) > 2 else "大街上全都是怪物"
    path = os.path.join(GAME_DIR, "Map%04d.lmu" % mid)
    d = open(path, "rb").read()
    p = d.index(b"LcfMapUnit") + 10

    ev_sec = None
    for cid, dp, ln in chunks_of(d, p, len(d)):
        if cid == 0x51:
            ev_sec = (dp, dp + ln)
    if not ev_sec:
        print("未找到事件区")
        return

    events = parse_array_off(d, ev_sec[0], ev_sec[1])
    print("Map%04d 共 %d 个事件" % (mid, len(events)))

    # 找目标串的偏移
    needle = key.encode("gb18030")
    offs = []
    i = d.find(needle)
    while i >= 0:
        offs.append(i)
        i = d.find(needle, i + 1)
    print("目标 %r 出现 %d 次" % (key, len(offs)))
    if not offs:
        return

    for off in offs[:4]:
        # 定位事件
        for eidx, est, een, echunks in events:
            if est <= off < een:
                nm = dec2(echunks.get(0x01, (0, 0))[0:0]) if False else ""
                nrange = echunks.get(0x01)
                if nrange:
                    nm = dec2(d[nrange[0]:nrange[1]])
                xr, yr = echunks.get(0x02), echunks.get(0x03)
                x = ber(d, xr[0])[0] if xr else "?"
                y = ber(d, yr[0])[0] if yr else "?"
                print("\n=== 偏移 %d → 事件 #%d (%s,%s) 名=%r 事件范围[%d,%d)" % (
                    off, eidx, x, y, nm, est, een))
                # 页
                prange = echunks.get(0x05)
                if not prange:
                    continue
                pages = parse_array_off(d, prange[0], prange[1])
                for pidx, pst, pen, pchunks in pages:
                    if pst <= off < pen:
                        print("    页 %d 范围[%d,%d) chunks=%s" % (
                            pidx, pst, pen,
                            {hex(k): (v[1] - v[0]) for k, v in sorted(pchunks.items())}))
                        for cid, (cs, ce) in sorted(pchunks.items()):
                            if cs <= off < ce:
                                print("    ★ 落在 chunk 0x%02X  长度=%d" % (cid, ce - cs))
                                seg = d[cs:ce]
                                _dump_seg(seg, off - cs)
                break
        else:
            print("\n=== 偏移 %d → 不属于任何事件（在地图自身数据里）" % off)


def _dump_seg(seg, rel):
    """把 chunk 内容按 gb18030 解码，保留 ASCII 控制码，展示名字标记。"""
    txt = seg.decode("gb18030", errors="replace")
    print("    ---- chunk 全文（gb18030, 控制码保留）----")
    # 只打印含中文/控制码的行片段
    print(txt.replace("\x00", "·")[:2600])
    print("    ---- 目标串相对偏移 %d，前后 260 字节 ----" % rel)
    lo = max(0, rel - 260)
    hi = min(len(seg), rel + 260)
    print(repr(seg[lo:hi].decode("gb18030", errors="replace")))


if __name__ == "__main__":
    main()
