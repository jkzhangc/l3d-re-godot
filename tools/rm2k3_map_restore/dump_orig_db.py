#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dump_orig_db.py — 把原作 RM2K3 的 RPG_RT.ldb 导出成日文（UTF-8）表格

原作工程用 **Shift-JIS** 存文本，按 UTF-8 读 / 按字节 grep 都会显示成"乱码"，
本工具正确解码，输出 `outputs/orig_db/<区名>.tsv`（编号 / 日文名 / 日文说明 / 数值字段）。

记录边界不用「chunk id 递减」判（RM2K3 的记录末尾 chunk id 会跳号，容易走偏），
改用**记录头特征扫描**：`[记录号 BER][0x01][长度][日文名][0x02][长度][说明]`，
特征足够独特，不会误命中。

用法：
    python tools/rm2k3_map_restore/dump_orig_db.py
    python tools/rm2k3_map_restore/dump_orig_db.py --section 0x0D
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import parse_lcf as P

LDB = r"E:/15.L3D/RPG_RT.ldb"
OUT = "outputs/orig_db"

## 区 id → 名称（RM2K3 LcfDataBase）
SECTIONS = {
    0x0B: "terrain",
    0x0C: "item_b",         # 与 0x0D 同构（装备类道具）
    0x0D: "weapon",
    0x0E: "armor",
    0x0F: "enemy",
    0x10: "troop",
    0x11: "terrain2",
    0x12: "attribute",
    0x13: "skill",
    0x14: "chipset",
    0x15: "condition",
    0x16: "battle_anim",
    0x17: "battler_anim",
    0x18: "animation",
    0x19: "common_event",
    0x1D: "sec_1D",
    0x1E: "sec_1E",
    0x20: "vocab",
}


def sjis(bs: bytes) -> str:
    return bs.decode("shift_jis", "replace")


def is_text(bs: bytes) -> bool:
    """能不能当作品名/说明：解出来没有替换符与控制字符。"""
    if len(bs) > 120:
        return False
    try:
        t = bs.decode("shift_jis")
    except UnicodeDecodeError:
        return False
    for ch in t:
        if ch == "\ufffd" or (ord(ch) < 0x20 and ch not in "\n"):
            return False
    return True


def scan_records(data, off, end):
    """返回 [(记录号, 名字, 记录起始pos, 名字结束pos)]，按出现顺序。"""
    out = []
    p = off
    while p < end - 4:
        q = p
        try:
            idx, q = P.ber(data, q)
        except IndexError:
            break
        if not (1 <= idx <= 5000):
            p += 1
            continue
        if q >= end or data[q] != 0x01:
            p += 1
            continue
        try:
            ln, r = P.ber(data, q + 1)
        except IndexError:
            p += 1
            continue
        if ln > 80 or r + ln + 1 >= end:
            p += 1
            continue
        name_bs = data[r:r + ln]
        if not is_text(name_bs) or data[r + ln] != 0x02:
            p += 1
            continue
        out.append((idx, sjis(name_bs), p, r + ln))
        p = r + ln
    return out


def read_chunks(data, pos, end):
    """从记录头之后按 [id][len][data] 读，直到 id 不再递增或越界。"""
    chunks = []
    last = 0x01          # 名字 chunk(0x01) 已读过，从 pos 起下一个应是 0x02 说明
    cur = pos
    while cur < end:
        try:
            cid, p2 = P.ber(data, cur)
            ln, p3 = P.ber(data, p2)
        except IndexError:
            break
        if cid <= last or p3 + ln > end:
            break
        chunks.append((cid, data[p3:p3 + ln]))
        last = cid
        cur = p3 + ln
    return chunks


def as_int(payload):
    if not payload:
        return None
    if len(payload) <= 4:
        try:
            return P.ber_of(payload)
        except Exception:
            return None
    return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--section", default="")
    ap.add_argument("--ldb", default=LDB)
    args = ap.parse_args()

    data, secs = P.ldb_sections(args.ldb)
    os.makedirs(OUT, exist_ok=True)
    for cid in sorted(secs):
        if args.section and args.section.lower() not in ("0x%02x" % cid, str(cid)):
            continue
        off, ln = secs[cid]
        end = off + ln
        recs = scan_records(data, off, end)
        if not recs:
            continue
        name = SECTIONS.get(cid, "sec_%02X" % cid)
        rows = []
        for i, (idx, nm, start, name_end) in enumerate(recs):
            rec_end = recs[i + 1][2] if i + 1 < len(recs) else end
            chunks = read_chunks(data, name_end, rec_end)
            desc = ""
            fields = {}
            for c, payload in chunks:
                if c == 0x02:
                    desc = sjis(payload)
                elif c != 0x01:
                    fields[c] = payload
            rows.append((idx, nm, desc, fields))
        if not rows:
            continue
        nums = sorted({c for r in rows for c in r[3]})
        path = os.path.join(OUT, "%s.tsv" % name)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("id\tname_ja\tdesc_ja\t" + "\t".join("f%02X" % c for c in nums) + "\n")
            for idx, nm, ds, fields in rows:
                vals = []
                for c in nums:
                    v = as_int(fields.get(c))
                    vals.append("" if v is None else str(v))
                f.write("%d\t%s\t%s\t%s\n" % (
                    idx, nm.replace("\t", " "),
                    ds.replace("\n", " ").replace("\t", " "), "\t".join(vals)))
        print("%-14s 记录 %4d → %s" % (name, len(rows), path))


if __name__ == "__main__":
    main()
