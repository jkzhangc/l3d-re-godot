#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RM2K3 事件侦察：从 LMU(地图事件) / LDB(公共事件) 里把事件名与命令列出来。

用途：定位原作 L3D 的刷怪逻辑（哪张图、哪个公共事件、什么参数）。
只读，不改原作。

用法：
    python dump_orig_events.py names            # 只列事件名（LMU + LDB 公共事件）
    python dump_orig_events.py cmds <map_id> <事件名关键字>
    python dump_orig_events.py common <公共事件名关键字>
    python dump_orig_events.py page <map_id> <事件名关键字> <页号>

═══ LCF 数组格式（2026-09-12 按 EasyRPG 文档修正）═══
结构数组 = [元素个数 BER] + N × { 元素索引 BER + chunk 流 }。
chunk 流：每个 chunk = [chunk_id BER][长度 BER][数据]；chunk_id == 0 表示对象结束（无长度无数据）。
LMU 事件：0x51 chunk 的 payload 是「事件数组」；事件 chunk：0x01=名字 0x02=x 0x03=y 0x05=页数组。
页数组同样是「结构数组」；页内的命令块按 try-parse 识别（无条数前缀，code=0 收尾）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_lcf import ber, ber_of, chunks_of, ldb_sections  # noqa: E402

GAME_DIR = "E:/15.L3D"


def dec(bs):
    """本项目事件名是 **Shift-JIS(cp932)**：parse_lcf.decode_name 先试 GBK 会成功但出乱码，
    所以这里改成 cp932 优先。"""
    for enc in ("cp932", "gb18030"):
        try:
            return bs.decode(enc)
        except Exception:
            continue
    return repr(bs)


# ------------------------------------------------------- LCF 结构数组 ----

def parse_chunk_array(buf, pos, end):
    """LCF 结构数组：[数量][元素: 索引BER + chunk流(0x00 收尾)] → [(索引, {chunk_id: bytes})]"""
    count, pos = ber(buf, pos)
    out = []
    for _ in range(count):
        idx, pos = ber(buf, pos)
        chunks = {}
        while pos < end:
            cid, pos = ber(buf, pos)
            if cid == 0:
                break
            ln, pos = ber(buf, pos)
            chunks[cid] = buf[pos:pos + ln]
            pos += ln
        out.append((idx, chunks))
    return out


# ---------------------------------------------------------------- LMU 事件 ----

def lmu_events(path):
    d = open(path, "rb").read()
    p = d.index(b"LcfMapUnit") + 10
    for cid, dp, ln in chunks_of(d, p, len(d)):
        if cid == 0x51:
            return parse_chunk_array(d, dp, dp + ln)
    return []


def event_header(chunks):
    """事件 chunk：0x01 名字 / 0x02 x / 0x03 y / 0x05 页数组"""
    name = chunks.get(0x01, b"")
    x = ber_of(chunks[0x02]) if 0x02 in chunks else None
    y = ber_of(chunks[0x03]) if 0x03 in chunks else None
    pages = []
    if 0x05 in chunks:
        pg = chunks[0x05]
        pages = parse_chunk_array(pg, 0, len(pg))
    return name, x, y, pages


def page_chunks(pg):
    return sorted(pg.items())


def command_list(pg):
    """在页里找命令表：试所有块，能按 [code,indent,string,params] 完整解析的即为命令表"""
    for cid, seg in page_chunks(pg):
        cmds = parse_commands(seg)
        if cmds is not None and cmds:
            return cid, cmds
    return None, None


def parse_commands(seg):
    """解析命令区：**无条数前缀**，解析到段尾为止（末条为 code=0 END）。"""
    try:
        pos = 0
        cmds = []
        while pos < len(seg):
            code, pos = ber(seg, pos)
            indent, pos = ber(seg, pos)
            slen, pos = ber(seg, pos)
            s = seg[pos:pos + slen]
            pos += slen
            pc, pos = ber(seg, pos)
            params = []
            for _i in range(pc):
                v, pos = ber(seg, pos)
                params.append(v)
            cmds.append({"code": code, "indent": indent, "str": s, "params": params})
        return cmds
    except (IndexError, ValueError):
        return None


# --------------------------------------------------------------- LDB 公共 ----

COMMON_CHUNKS = (0x01, 0x0B, 0x0C, 0x0D, 0x15, 0x16)


def ldb_common_events(path):
    """遍历 LDB 0x19（公共事件）。

    条目结构（2026-09-10 逐字节验证；2026-09-12 按 LCF 数组格式修正：
    条目 = [索引 BER] + chunk 流（0x00 收尾），**没有条目级长度前缀**）：
        0x01 名字 / 0x0B 触发方式 / 0x0C 开关标志 / 0x0D 开关号 / 0x15 命令区长度 / 0x16 命令区
    """
    data, secs = ldb_sections(path)
    if 0x19 not in secs:
        return []
    cp, ln = secs[0x19]
    out = []
    for eid, chunks in parse_chunk_array(data, cp, cp + ln):
        name = chunks.get(0x01, b"")
        trigger = ber_of(chunks[0x0B]) if 0x0B in chunks else None
        cmds = parse_commands(chunks[0x16]) or [] if 0x16 in chunks else []
        out.append({"id": eid, "name": name, "trigger": trigger, "cmds": cmds})
    return out


# ------------------------------------------------------------------ 输出 ----

def brief(cmds, limit=40):
    lines = []
    for i, c in enumerate(cmds[:limit]):
        s = dec(c["str"]) if c["str"] else ""
        if len(s) > 60:
            s = s[:60] + "…"
        lines.append("    %3d indent=%-2d code=%-6d %s  params=%s" % (
            i, c["indent"], c["code"], s, c["params"]))
    if len(cmds) > limit:
        lines.append("    ...（共 %d 条）" % len(cmds))
    return lines


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "names"
    gd = GAME_DIR

    if mode == "names":
        print("=== LDB 公共事件 ===")
        for ev in ldb_common_events(os.path.join(gd, "RPG_RT.ldb")):
            print("  #%-3d trigger=%s cmds=%-4d %s" % (
                ev["id"], ev["trigger"], len(ev["cmds"]), dec(ev["name"])))
        print()
        print("=== 地图事件名（只列有事件的图） ===")
        import glob
        for f in sorted(glob.glob(os.path.join(gd, "Map*.lmu"))):
            try:
                evs = lmu_events(f)
            except (IndexError, ValueError) as e:
                print("---- %s: 解析失败，已跳过 (%s)" % (os.path.basename(f), e))
                continue
            if not evs:
                continue
            print("---- %s: %d 个事件" % (os.path.basename(f), len(evs)))
            for idx, chunks in evs:
                name, x, y, pages = event_header(chunks)
                nm = dec(name)
                pcs = []
                for _pi, pg in enumerate(pages):
                    cid, cmds = command_list(pg[1])
                    pcs.append("%s:%d" % ("cmd" + str(cid) if cid else "-", len(cmds or [])))
                print("    #%-3d (%3s,%3s) 页=%d [%s] %s" % (idx, x, y, len(pages), ",".join(pcs), nm))
        return

    if mode == "common":
        key = sys.argv[2]
        for ev in ldb_common_events(os.path.join(gd, "RPG_RT.ldb")):
            nm = dec(ev["name"])
            if key and key not in nm:
                continue
            print("=== 公共事件 #%d %s (trigger=%s, %d 条) ===" % (
                ev["id"], nm, ev["trigger"], len(ev["cmds"])))
            print("\n".join(brief(ev["cmds"], 400)))
            print()
        return

    if mode in ("cmds", "page"):
        map_id = int(sys.argv[2])
        key = sys.argv[3]
        only = int(sys.argv[4]) if mode == "page" and len(sys.argv) > 4 else None
        f = os.path.join(gd, "Map%04d.lmu" % map_id)
        for idx, chunks in lmu_events(f):
            name, x, y, pages = event_header(chunks)
            nm = dec(name)
            if key and key not in nm:
                continue
            print("=== 地图 %d 事件 #%d (%s,%s) %s 共 %d 页 ===" % (map_id, idx, x, y, nm, len(pages)))
            for pi, pg in enumerate(pages):
                if only is not None and pi != only:
                    continue
                cid, cmds = command_list(pg[1])
                print("  -- 第 %d 页 命令块=0x%02X 共 %d 条" % (pi, cid or 0, len(cmds or [])))
                print("\n".join(brief(cmds or [], 400)))
        return

    print(__doc__)


if __name__ == "__main__":
    main()
