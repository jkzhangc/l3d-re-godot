#!/usr/bin/env python3
"""RPG Maker 素材文件名乱码 ↔ 日文 双向转换。

## 这个乱码是怎么来的
日文版 RM2K/2K3 工程的文件名是 **Shift-JIS(CP932)** 字节。整包复制到中文 Windows 后，
资源管理器和 RM 编辑器都按 **GBK** 去解读同一串字节 —— 于是「火炎放射器」变成「壩墛曻幩婍」。

转换是**一一对应**的，可以无损来回：
    日文 --CP932编码--> 字节 --GBK解码--> 乱码
    乱码 --GBK编码-->   字节 --CP932解码--> 日文

## 用法
    python tools/rm_name_decode.py 壩墛曻幩婍            # 乱码 → 日文
    python tools/rm_name_decode.py --to-mojibake 火炎放射器  # 日文 → 乱码
    python tools/rm_name_decode.py --scan "D:/某工程/CharSet"  # 列出整目录的对照表
    python tools/rm_name_decode.py --scan "D:/某工程/CharSet" --filter 炎火

## 已知的火焰类素材（原作「野比大雄的生化危机G版2代」）
    炎キャラチップ.xyz      墛僉儍儔僠僢僾.xyz        火焰角色图（火堆/火球/中火/小火，4 方向 × 3 帧）
    火炎放射器.png          壩墛曻幩婍.png           火焰喷射器（角色 + 火焰）
    職員ゾンビ炎上.png      怑堳僝儞價墛忋.png        着火职员僵尸
"""

from __future__ import annotations

import argparse
import os
import sys

SRC_ENC = "cp932"   # 素材的原始编码（日文 Shift-JIS）
DST_ENC = "gbk"     # 中文 Windows 误读用的编码


def decode_name(mojibake: str) -> str:
    """乱码字串 → 日文原名。无法解码时返回带说明的字符串。"""
    try:
        return mojibake.encode(DST_ENC).decode(SRC_ENC)
    except (UnicodeEncodeError, UnicodeDecodeError) as exc:
        return "<无法解码: %s>" % exc


def encode_name(japanese: str) -> str:
    """日文原名 → 中文系统上显示的乱码字串。"""
    try:
        return japanese.encode(SRC_ENC).decode(DST_ENC)
    except (UnicodeEncodeError, UnicodeDecodeError) as exc:
        return "<无法编码: %s>" % exc


def scan(directory: str, keyword: str = "") -> int:
    """列出目录下每个文件名的「乱码 → 日文」对照。返回文件数。"""
    if not os.path.isdir(directory):
        print("目录不存在: %s" % directory, file=sys.stderr)
        return 0
    names = sorted(os.listdir(directory))
    rows = []
    for name in names:
        stem, ext = os.path.splitext(name)
        jp = decode_name(stem)
        if jp.startswith("<无法解码"):
            continue
        if keyword and not any(k in jp for k in keyword):
            continue
        rows.append((jp, name))
    rows.sort()
    print("%-30s %s" % ("日文名", "磁盘上的乱码名"))
    print("-" * 78)
    for jp, name in rows:
        print("%-30s %s" % (jp, name))
    print("-" * 78)
    print("共 %d 项（目录总计 %d 个文件）" % (len(rows), len(names)))
    return len(rows)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="RPG Maker 素材文件名乱码 ↔ 日文 双向转换",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("name", nargs="?", help="要转换的文件名（不含扩展名也可以）")
    parser.add_argument("--to-mojibake", action="store_true",
                        help="反向：日文 → 中文系统上的乱码")
    parser.add_argument("--scan", metavar="DIR", help="列出整目录的对照表")
    parser.add_argument("--filter", metavar="CHARS",
                        help="配合 --scan：只保留日文名含这些字的项（逐字匹配）")
    args = parser.parse_args(argv)

    if args.scan:
        scan(args.scan, args.filter or "")
        return 0

    if not args.name:
        parser.print_help()
        return 1

    stem, ext = os.path.splitext(args.name)
    if args.to_mojibake:
        print("%s%s" % (encode_name(stem), ext))
    else:
        print("%s%s" % (decode_name(stem), ext))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
