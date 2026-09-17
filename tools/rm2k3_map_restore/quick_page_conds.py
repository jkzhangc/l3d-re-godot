#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""147 图敌人事件页条件速查：每页的开关/变量出现条件 + 首条命令。

LCF EventPage condition chunk (0x02) 布局（liblcf rpg/eventpage.h Condition）:
    [flags][switch_a][switch_b][variable_id][variable_value][item_id]...
    flags bit0=开关A bit1=开关B bit2=变量 bit3=道具 bit4=角色(2k3) bit5=计时器1 bit6=计时器2
页触发方式 chunk (0x01): 0=按钮/0x0B... (RM2K3: 0=決定键,1=接触,2=事件接触,3=自动开始,4=并行处理)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_lcf import ber
from dump_orig_events import lmu_events, event_header, dec


def page_condition(pg):
    cond = pg.get(0x02)
    if not cond:
        return "(无条件)"
    flags = cond[0]
    vals = []
    p = 1
    while p < len(cond):
        v, p = ber(cond, p)
        vals.append(v)
    names = []
    if flags & 0x01 and len(vals) > 0:
        names.append("开关A=%d" % vals[0])
    if flags & 0x02 and len(vals) > 1:
        names.append("开关B=%d" % vals[1])
    if flags & 0x04 and len(vals) > 3:
        names.append("变量%d==%d" % (vals[2], vals[3]))
    return "flags=0x%02X %s" % (flags, " ".join(names) if names else "(空条件位)")


def page_trigger(pg):
    t = pg.get(0x01)
    if not t:
        return "?"
    names = {0: "決定键", 1: "玩家接触", 2: "事件接触", 3: "自动开始", 4: "并行处理"}
    return names.get(t[0], str(t[0]))


def main():
    events = {idx: ch for idx, ch in lmu_events(os.path.join("E:/15.L3D", "Map%04d.lmu" % 147))}
    targets = [int(x) for x in sys.argv[1:]] or [249, 111, 159, 54, 295, 332, 123, 70, 97, 99, 250, 322]
    for tid in targets:
        chunks = events.get(tid)
        if not chunks:
            print("事件 #%d 不存在" % tid)
            continue
        name, x, y, pages = event_header(chunks)
        print("=== #%d (%s,%s) %s：%d 页 ===" % (tid, x, y, dec(name), len(pages)))
        for pi, (pgidx, pg) in enumerate(pages):
            c = pg.get(0x02, b"")
            t = pg.get(0x01, b"")
            print("  页%-2d cond=%s trigger=%s" % (pi, c.hex() if c else "(none)", t.hex() if t else "?"))
        print()


if __name__ == "__main__":
    main()
