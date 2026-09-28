#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按**角色**提取安全屋台词（原作的说话人写在文本里：`\\>\\C[4]名字\\C[0]\\<`）。

═══ 原理 ═══
「显示文章」命令的字节布局（LCF，BER 为**大端** 7-bit 变长）：

    10110  ShowMessage   : [CE 7E] [indent] [strlen] [str......] [paramcnt] [params...]
    20110  ShowMessage_2 : [81 9D 0E] [indent] [strlen] [str......] [paramcnt] [params...]
    10130  ChangeFaceGraphic : [CF 12] ...

说话人行 = 整串就是一个颜色标记包裹的名字（`\\>\\C[4]大雄\\C[0]\\<` 或 `\\C[4]大雄\\C[0]`）；
其后连续的 20110 就是该角色的台词行；遇到下一条 10110（尤其实名存档界面那种纯文本）即换人/收尾。

用法：python export_safehouse_lines.py [map_id ...]   默认 139 137 143 145
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_orig_events import GAME_DIR  # noqa: E402

## 整串就是「颜色标记包裹的名字」→ 说话人。
## 两种写法都有：`\>\C[4]名字\C[0]\<`（存档界面用）与 `\C[4]名字\C[0]`（安全屋用）。
## ★ 别写成 `\\>?` —— 那样 `?` 只作用于 `>`，反斜杠变成必需，不带 `\>` 的行全部匹配不上。
SPEAKER_RE = re.compile(r"^\s*(?:\\>)?\\C\[\d+\]([^\\]{1,12})\\C\[0\](?:\\<)?\s*$")


def ber(d, p):
    """LCF 变长整数：**大端** 7-bit，首字节最高位=1 表示继续。
    例：CE 7E → 10110（ShowMessage）；81 9D 0E → 20110（ShowMessage 续行）。"""
    v = d[p] & 0x7F
    while d[p] & 0x80:
        p += 1
        v = (v << 7) | (d[p] & 0x7F)
    return v, p + 1


def scan_messages(d):
    """扫描全文件，产出 [(code, indent, text)] 顺序表（只认 10110 / 20110）。

    ★ 必须把 paramcnt + params 一起吃掉再前进 —— 只跳字符串会错位，
      之后的锚点全部对不上（这就是上一版只扫到存档界面的原因）。
    """
    out = []
    i = 0
    n = len(d)
    while i < n - 6:
        if d[i] == 0xCE and d[i + 1] == 0x7E:
            pass
        elif d[i] == 0x81 and d[i + 1] == 0x9D and d[i + 2] == 0x0E:
            pass
        else:
            i += 1
            continue
        try:
            code, p = ber(d, i)
            indent, p = ber(d, p)
            slen, p = ber(d, p)
            if indent > 12 or slen == 0 or slen > 2000 or p + slen > n:
                i += 1
                continue
            text = d[p:p + slen].decode("gb18030")
            p += slen
            pcount, p = ber(d, p)
            if pcount > 64:
                i += 1
                continue
            for _ in range(pcount):
                _v, p = ber(d, p)
            if p > n:
                i += 1
                continue
        except (IndexError, UnicodeDecodeError, ValueError):
            i += 1
            continue
        if "\ufffd" in text or "\x00" in text:
            i += 1
            continue
        out.append({"off": i, "code": code, "indent": indent, "text": text})
        i = p
    return out


def group_by_speaker(msgs, min_indent=3):
    """把消息序列整理成 [{speaker, lines, off, indent}, ...]；非说话人的 10110 会切断归属。

    min_indent：安全屋台词在「全マップ共通処理」的**条件分支内**（indent=4），
    而存档界面的难度说明 NPC（德田志穗）在分支外（indent=2）→ 用缩进层级天然区分。
    """
    blocks = []
    cur = None
    for m in msgs:
        if m["code"] == 10110:
            mt = SPEAKER_RE.match(m["text"])
            if mt and m["indent"] >= min_indent:
                cur = {"speaker": mt.group(1).strip(), "lines": [],
                       "off": m["off"], "indent": m["indent"]}
                blocks.append(cur)
            else:
                cur = None   # 存档界面那类无标记正文 / 分支外说明 → 不归属
            continue
        if cur is not None and m["text"].strip():
            cur["lines"].append(m["text"].strip())
    return blocks


def main():
    ids = [int(a) for a in sys.argv[1:]] or [139, 137, 143, 145]
    for mid in ids:
        path = os.path.join(GAME_DIR, "Map%04d.lmu" % mid)
        if not os.path.exists(path):
            print("Map%04d 不存在" % mid)
            continue
        d = open(path, "rb").read()
        msgs = scan_messages(d)
        blocks = [b for b in group_by_speaker(msgs) if b["lines"]]
        print("=" * 78)
        print("Map%04d   说话人块 %d 个，共 %d 行台词" % (
            mid, len(blocks), sum(len(b["lines"]) for b in blocks)))
        for b in blocks:
            print("  ● %s" % b["speaker"])
            for ln in b["lines"]:
                print("      - %s" % ln)


if __name__ == "__main__":
    main()
