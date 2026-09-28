#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探针：把安全屋地图里含「显示文章」的事件**完整指令流**导出（含 indent 层级），
用来判断原作是怎么把台词和角色绑定起来的。

用法：python probe_dialogue_speaker.py [map_id ...]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import lmu_events, event_header, command_list, dec, GAME_DIR  # noqa: E402

KANA = re.compile(r"[\u3040-\u30ff]")
HAN = re.compile(r"[\u4e00-\u9fff]")


def dec_auto(bs):
    """同一个 LMU 里混合编码：先判 cp932 是否含假名 → 是则取 cp932，否则取 gb18030。"""
    if not bs:
        return ""
    try:
        cp = bs.decode("cp932")
    except Exception:
        cp = None
    if cp is not None and not KANA.search(cp):
        # cp932 解出纯汉字/符号，可能是汉化正文被误判 → 再比一次
        pass
    try:
        gb = bs.decode("gb18030")
    except Exception:
        gb = None
    # 汉化正文：gb18030 能解出、且 cp932 解出含假名（说明原字节是 GBK 双字节）
    if gb is not None and cp is not None and KANA.search(cp):
        return gb
    if gb is not None and HAN.search(gb) and (cp is None or not KANA.search(cp)):
        return gb
    return cp if cp is not None else (gb if gb is not None else repr(bs))


CODE_NAMES = {
    10110: "ShowMessage",
    10120: "MessageOptions",
    10130: "ChangeFaceGraphic",
    10140: "ShowMessageFace",
    10150: "MessageCtrl?",
    10610: "CondBranch",
    10620: "CondElse",
    10630: "CondEnd",
    10640: "Loop",
    10650: "BreakLoop",
    10660: "EndLoop",
    12010: "VarOp",
    12020: "SwitchOp",
    12110: "ChangeItem?",
    12410: "Comment",
    12420: "Comment?",
    12510: "GameOver?",
    12310: "Wait",
    10810: "CallCommonEvent?",
    10710: "JumpLabel?",
    10670: "End?",
    0: "END",
}


def show(c):
    code = c["code"]
    s = dec_auto(c["str"])
    tag = CODE_NAMES.get(code, "")
    return "  ind=%-2d c=%-6d %-16s %s %s" % (
        c["indent"], code, tag, s.replace("\n", " ⏎ ")[:88], c["params"])


def main():
    ids = [int(a) for a in sys.argv[1:]] or [139, 137, 143, 145]
    for mid in ids:
        f = os.path.join(GAME_DIR, "Map%04d.lmu" % mid)
        if not os.path.exists(f):
            print("Map%04d 不存在" % mid)
            continue
        print("=" * 90)
        print("Map%04d" % mid)
        for idx, chunks in lmu_events(f):
            nm, x, y, pages = event_header(chunks)
            for pi, pg in enumerate(pages):
                cid, cmds = command_list(pg[1])
                if not cmds:
                    continue
                if not any(c["code"] == 10110 for c in cmds):
                    continue
                print("--- 事件 #%d (%s,%s) 页%d  名=%s  共%d条" % (
                    idx, x, y, pi, dec(nm), len(cmds)))
                for i, c in enumerate(cmds):
                    if c["code"] in (12410, 12420):
                        continue
                    print("   [%3d]%s" % (i, show(c)))


if __name__ == "__main__":
    main()
