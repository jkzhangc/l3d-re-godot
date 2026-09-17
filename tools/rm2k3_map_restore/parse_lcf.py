#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RM2K3 LCF 解析器（Left 3 Dead 工程, E:/15.L3D）

解析 RPG_RT.lmt(地图树) / RPG_RT.ldb(芯片组表) / MapXXXX.lmu(地图摘要),
输出 JSON 供 Godot 侧地图还原管线使用, 避免每次会话重新逆向格式。

用法:
    python parse_lcf.py [game_dir] [out_json] [art_tilesets_dir]
默认:
    game_dir          = E:/15.L3D
    out_json          = <本脚本目录>/map_tree.json
    art_tilesets_dir  = <godot工程>/art/Tilesets (用于素材名启发式匹配)

═══ 已验证的格式要点(2026-08 逐字节侦察结论) ═══

通用: LCF 整数 = BER(7位变长, 高位续传); 字符串 = BER长度 + 原始字节。
      本工程字符串 GBK(中文) 与 SJIS(日文残留) 混用, 两种都试解码。

LMU 地图: [0x0A]"LcfMapUnit" 之后直接跟顶层块(无包裹):
    0x01=芯片组ID(1字节)   0x02=高 0x03=宽 (BER值; 部分老图/废图缺失!)
    0x3C/0x3D/0x3E = 36字节全零块 x3 (用途未知, 忽略)
    0x47=下层矩阵 0x48=上层矩阵: 定长 2字节/格, 小端 uint16
    0x51=事件数据   0x5B=2字节(未知)
图块值编码: 上层 = 10000+n (n=0..191, 已证实) ;
            下层 = 0 / 4000+n / 5000+n 混合 (各区语义标定 = 待办)

LMT 地图树: [0x0B]"LcfMapTree" + 前导[0x37 0x00] + 根节点(无节点号):
    根/节点 = [0x01 名字串][属性块...][0x33 生成器数据(16B)收尾]
    后续节点前有 0x00 分隔字节 + [节点号BER]; 节点号 = 地图ID
    属性块: 0x02=父节点ID 0x03=缩进 0x04=类型(0根/1地图/2目录)
    树区之后还有第二区(每图音乐等, chunk 0x0F 起), 本脚本忽略。

LDB 数据库: 顶层块 = 各表; 表内条目 = [条目号BER][0x01 名字][字段块...]。
    芯片组表自动识别: 条目名字以 .xyz/.png/.bmp 结尾或与 ChipSet 目录匹配。
    芯片组字段: 0x02=地形表(BER整数序列) 0x03=通行表 0x04=动画类型 0x05=速度
"""

import json
import os
import sys
from datetime import datetime

GAME_DIR_DEFAULT = "E:/15.L3D"
HERE = os.path.dirname(os.path.abspath(__file__))


def ber(buf, pos):
    """读一个 BER 变长整数, 返回 (值, 新位置)"""
    val = 0
    while True:
        b = buf[pos]
        pos += 1
        val = (val << 7) | (b & 0x7F)
        if not (b & 0x80):
            break
    return val, pos


def ber_of(data):
    """把一小段字节按 BER 解码成整数"""
    v = 0
    for i, b in enumerate(data):
        v = (v << 7) | (b & 0x7F)
        if not (b & 0x80):
            break
    return v


def chunks_of(buf, pos, end):
    """把 [pos,end) 当作连续 chunk 列表, 返回 [(id, 数据起始, 长度)]"""
    out = []
    while pos + 1 < end:
        cid, p2 = ber(buf, pos)
        ln, p3 = ber(buf, p2)
        if p3 + ln > end:
            break
        out.append((cid, p3, ln))
        pos = p3 + ln
    return out


def decode_name(bs):
    """GBK 优先, SJIS 兜底; 返回 (文本, 编码) 或 (None, None)"""
    for enc in ("gb18030", "cp932"):
        try:
            return bs.decode(enc), enc
        except Exception:
            continue
    return None, None


# ---------------------------------------------------------------- LMT ----

def parse_lmt(path):
    data = open(path, "rb").read()
    pos = data.index(b"LcfMapTree") + 10 + 2  # 跳过前导 37 00
    end = len(data)
    nodes = {}

    def read_chunks_until_33(pos, n):
        while data[pos] != 0x33:
            cid, p2 = ber(data, pos)
            ln, p3 = ber(data, p2)
            if cid:
                n[cid] = data[p3:p3 + ln]
            pos = p3 + ln
        cid, p2 = ber(data, pos)
        ln, p3 = ber(data, p2)
        return p3 + ln  # 0x33 数据之后

    # 根节点: 无节点号
    cid, p2 = ber(data, pos)
    assert cid == 0x01, "LMT 根节点应以名字块开头"
    ln, p3 = ber(data, p2)
    root = {"name": data[p3:p3 + ln]}
    pos = read_chunks_until_33(p3 + ln, root) + 1  # +1 = 0x00 分隔
    nodes[0] = root

    while pos < end - 1:
        try:
            idx, p2 = ber(data, pos)
            cid, p3 = ber(data, p2)
            if cid != 0x01:
                break
            ln, p4 = ber(data, p3)
            n = {"name": data[p4:p4 + ln]}
            pos = read_chunks_until_33(p4 + ln, n) + 1
        except (IndexError, AssertionError):
            break
        nodes[idx] = n
    return nodes


# ---------------------------------------------------------------- LDB ----

def ldb_sections(path):
    data = open(path, "rb").read()
    pos = data.index(b"LcfDataBase") + 11
    secs = {}
    while pos + 1 < len(data):
        cid, p2 = ber(data, pos)
        ln, p3 = ber(data, p2)
        if p3 + ln > len(data):
            break
        secs[cid] = (p3, ln)
        pos = p3 + ln
    return data, secs


def looks_like_chipset(name_bytes, chip_files):
    if name_bytes in chip_files:
        return True
    low = name_bytes.lower()
    return low.endswith(b".xyz") or low.endswith(b".png") or low.endswith(b".bmp")


def try_read_items(buf, pos, end, max_items):
    """按 [条目号][0x01 名字][字段...] 试读条目, 失败返回 None"""
    items = []
    while pos < end and len(items) < max_items:
        try:
            idx, p2 = ber(buf, pos)
            cid, p3 = ber(buf, p2)
            if cid != 0x01:
                return None
            ln, p4 = ber(buf, p3)
            name = buf[p4:p4 + ln]
            pos = p4 + ln
            fields = {}
            while pos < end:
                cid, q2 = ber(buf, pos)
                ln, q3 = ber(buf, q2)
                if cid in (0x02, 0x03, 0x04, 0x05):
                    fields[cid] = buf[q3:q3 + ln]
                    pos = q3 + ln
                else:
                    break
            items.append((idx, name, fields))
        except IndexError:
            return None
    return items


def ber_ints(data):
    """把整段字节解成 BER 整数序列(地形表/通行表)"""
    vals, pos = [], 0
    while pos < len(data):
        v, pos = ber(data, pos)
        vals.append(v)
    return vals


def parse_ldb_chipsets(path, chip_dir=None):
    """芯片组表 = LDB 0x14 区: [ID BER][0x01 显示名][0x02 文件名(无扩展名)]
    [0x03 通行表(约130字节 BER 整数)][0x04.. 其他]"""
    data, secs = ldb_sections(path)
    if 0x14 not in secs:
        return {}, None
    cp, ln = secs[0x14]
    end = cp + ln
    # 区开头是条目数量 BER 头, 跳过
    count, cp_items = ber(data, cp)
    chip_files = set(os.listdir(chip_dir)) if chip_dir and os.path.isdir(chip_dir) else set()
    # 目录里文件名 → 去扩展名的 stem 字符串。
    # Windows(GBK ANSI) 下 SJIS 文件名在 os.listdir 里呈现为同样的 GBK 乱码,
    # 与 LDB 原始字节用 gb18030 解出的乱码字符串一致, 故按字符串匹配。
    chip_by_stem = {}
    for f in chip_files:
        chip_by_stem[f.rsplit(".", 1)[0]] = f

    table = {}
    pos = cp_items
    while pos < end:
        try:
            idx, p2 = ber(data, pos)
            if p2 >= end:
                break
            item, pos = _read_ldb_item(data, p2, end)
            if item is None:
                break
            name, fields = item
            entry = {"name_raw_hex": name.hex()}
            txt, enc = decode_name(name)
            entry["name"], entry["name_encoding"] = txt, enc
            for fcid, fdata in fields.items():
                if fcid == 0x02:
                    entry["file_raw_hex"] = fdata.hex()
                    ftxt, fenc = decode_name(fdata)
                    entry["file"], entry["file_encoding"] = ftxt, fenc
                    # SJIS 正名(若可解且与 GBK 乱码不同, 说明原文件名是日文)
                    try:
                        sjis = fdata.decode("cp932")
                        if sjis != ftxt:
                            entry["file_sjis"] = sjis
                    except Exception:
                        pass
                    match = chip_by_stem.get(ftxt)
                    if match:
                        entry["chipset_file"] = match
                elif fcid == 0x03:
                    entry["passability"] = ber_ints(fdata)
                elif fcid == 0x04:
                    entry["terrain"] = ber_ints(fdata)
                else:
                    entry["field_%02x" % fcid] = fdata.hex()
            table[idx] = entry
            # LDB 数组条目以单字节 0x00 分隔；不跳过会把它误读为下一条的 ID 0。
            if pos < end and data[pos] == 0x00:
                pos += 1
        except IndexError:
            break
    return table, 0x14


def _read_ldb_item(buf, pos, end):
    """读 [0x01 名字(可省略)][字段块...], 返回 ((名字, 字段dict), 新pos)
    条目边界判定: 字段 chunk id 严格递增(0x01<0x02<0x03...),
    一旦遇到 <= 上一个字段 id 的 chunk id, 说明那是下一条目的条目号。"""
    last = 0
    name = b""
    fields = {}
    # 名字块(可省略: 无名条目直接以 0x02 字段开头)
    save = pos
    cid, p2 = ber(buf, pos)
    if cid == 0x01:
        ln, p3 = ber(buf, p2)
        if p3 + ln > end:
            return None, pos
        name = buf[p3:p3 + ln]
        pos = p3 + ln
        last = 0x01
    else:
        pos = save
    while pos < end:
        fcid, q2 = ber(buf, pos)
        fln, q3 = ber(buf, q2)
        if fcid in (0x02, 0x03, 0x04, 0x05, 0x0B, 0x0C) and fcid > last and q3 + fln <= end:
            fields[fcid] = buf[q3:q3 + fln]
            pos = q3 + fln
            last = fcid
        else:
            break
    return (name, fields), pos


# ---------------------------------------------------------------- LMU ----

def parse_lmu(path):
    d = open(path, "rb").read()
    p = d.index(b"LcfMapUnit") + 10
    info = {
        "file": os.path.basename(path),
        "chipset": None,
        "h": None,
        "w": None,
        "lower_cells": 0,
        "upper_cells": 0,
        "events_bytes": 0,
    }
    for cid, dp, ln in chunks_of(d, p, len(d)):
        if cid == 0x01 and ln == 1:
            info["chipset"] = d[dp]
        elif cid == 0x02:
            info["h"] = ber_of(d[dp:dp + ln])
        elif cid == 0x03:
            info["w"] = ber_of(d[dp:dp + ln])
        elif cid == 0x47:
            info["lower_cells"] = ln // 2
        elif cid == 0x48:
            info["upper_cells"] = ln // 2
        elif cid == 0x51:
            info["events_bytes"] = ln
    if info["w"] and info["h"]:
        info["dims_ok"] = info["w"] * info["h"] == info["lower_cells"]
    return info


# ---------------------------------------------------------------- main ---

def main():
    game_dir = sys.argv[1] if len(sys.argv) > 1 else GAME_DIR_DEFAULT
    out_json = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "map_tree.json")
    art_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
        os.path.dirname(HERE), "..", "art", "Tilesets")

    # --- 地图树 ---
    nodes = parse_lmt(os.path.join(game_dir, "RPG_RT.lmt"))
    tree = []
    for idx in sorted(nodes):
        n = nodes[idx]
        txt, enc = decode_name(n["name"])
        tree.append({
            "id": idx,
            "name": txt,
            "name_encoding": enc,
            "name_raw_hex": n["name"].hex(),
            "parent": ber_of(n.get(0x02, b"")),
            "indent": ber_of(n.get(0x03, b"")),
            "type": ber_of(n.get(0x04, b"")),
        })

    # --- 每张地图摘要 ---
    maps = {}
    for idx in sorted(nodes):
        lmu = os.path.join(game_dir, "Map%04d.lmu" % idx)
        if os.path.exists(lmu):
            maps[str(idx)] = parse_lmu(lmu)

    # --- 芯片组表 ---
    chip_dir = os.path.join(game_dir, "ChipSet")
    chipsets, section_id = parse_ldb_chipsets(
        os.path.join(game_dir, "RPG_RT.ldb"), chip_dir)

    # --- 素材启发式匹配: 芯片组名 ↔ art/Tilesets 文件 ---
    art_files = []
    if os.path.isdir(art_dir):
        art_files = os.listdir(art_dir)
    for cid, entry in chipsets.items():
        stem_hex = bytes.fromhex(entry["name_raw_hex"]).rsplit(b".", 1)[0]
        hits = []
        for af in art_files:
            afb = af.encode("utf-8", "surrogateescape")
            stem = afb.rsplit(b".", 1)[0]
            if stem == stem_hex or stem.startswith(stem_hex + b"_"):
                hits.append(af)
        if hits:
            entry["art_matches"] = hits

    out = {
        "game_dir": game_dir,
        "parsed_at": datetime.now().isoformat(timespec="seconds"),
        "ldb_chipset_section": ("0x%02X" % section_id) if section_id is not None else None,
        "map_tree": tree,
        "maps": maps,
        "chipsets": {str(k): v for k, v in sorted(chipsets.items())},
    }
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    # --- 控制台摘要 ---
    print("nodes: %d, maps: %d, chipsets: %s" % (len(tree), len(maps), len(chipsets)))
    print("chipset section: %s" % out["ldb_chipset_section"])
    for idx in sorted(nodes):
        t = next(x for x in tree if x["id"] == idx)
        m = maps.get(str(idx), {})
        dims = "%sx%s" % (m.get("w"), m.get("h")) if m.get("w") else "-"
        print("  %3d %-9s chip=%-4s %11s %s" % (
            idx, m.get("file", "-"), m.get("chipset", "-"),
            dims, t["name"] or "<noname>"))
    print("saved:", out_json)


if __name__ == "__main__":
    main()
