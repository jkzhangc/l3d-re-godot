#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把「一张图 = 一条动画」的 VX / RM2k 动画精灵表批量转成本工程的 anim/*.tscn。

用法：
    python tools/anim_import_sheets.py --src "E:/某工程/Graphics/Animations" --dry-run
    python tools/anim_import_sheets.py --src "..." --only 爆発,血 --fps 20 --cols 5

它做的事（每条 PNG）：
    1. 按 --cols（默认 5）切格子，行数 = ceil(高 / 格宽)；
    2. frame_sequence = 0..(列×行-1)；
    3. 生成 anim/anim_<文件名>.tscn（根节点 VXAnimSprite）；
    4. 把 PNG 复制到 art/Animations/（已存在则跳过，不覆盖）。

适用范围与限制：
    · 适合 VX Ace 的 `Graphics/Animations/*.png`（5 列标准表）；
      也适合任何「一张图里按格子顺序播放」的特效图。
    · **不读数据库**：VX Ace 的 Animations.rvdata2 / RM2k3 的 RPG_RT.ldb 里的
      「每条动画有哪几帧、每帧用哪张表的哪一格」尚未接入（见开发日志）。
      数据库里那些「不是顺序全表」的动画，请用场景编辑器 scene/anim_editor.tscn 手改。

自测（用工程里已有的一张动画表现场跑一遍）：
    python tools/anim_import_sheets.py --selftest
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def png_size(path: str) -> tuple[int, int]:
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG：%s" % path)
    w, h = struct.unpack(">II", head[16:24])
    return int(w), int(h)


def safe_stem(name: str) -> str:
    for k, v in {"/": "_", "\\": "_", ":": "_", "*": "_", "?": "_",
                 '"': "_", "<": "_", ">": "_", "|": "_"}.items():
        name = name.replace(k, v)
    return name.strip() or "anim"


def write_tscn(path: str, texture_res: str, frame_sequence: list[int], fps: float,
               h_frames: int = 5) -> None:
    seq = ", ".join(str(x) for x in frame_sequence)
    text = (
        '[gd_scene load_steps=3 format=3]\n\n'
        '[ext_resource type="Script" path="res://script/vx_anim_sprite.gd" id="1_sprite"]\n'
        '[ext_resource type="Texture2D" path="%s" id="2_sheet"]\n\n'
        '[node name="AnimEdit" type="Node2D"]\n'
        'script = ExtResource("1_sprite")\n'
        'texture = ExtResource("2_sheet")\n'
        'h_frames = %d\n'
        'fps = %g\n'
        'frame_sequence = Array[int]([%s])\n'
    ) % (texture_res, h_frames, fps, seq)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # .tscn 用 LF（工程约定）
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def detect_anim_dir(project: str) -> str:
    """在 RM 工程根目录里找动画素材目录。
    VA: <root>/Graphics/Animations   RM2k/2k3: <root>/Animations   本工程: <root>/art/Animations
    """
    cands = [
        os.path.join(project, "Graphics", "Animations"),
        os.path.join(project, "Animations"),
        os.path.join(project, "art", "Animations"),
    ]
    for c in cands:
        if os.path.isdir(c):
            return c
    return ""


def convert(src: str, out_dir: str, art_dir: str, cols: int, fps: float,
            only: list[str], prefix: str, force: bool, dry_run: bool,
            no_copy: bool = False) -> int:
    if not os.path.isdir(src):
        print("[ERROR] 目录不存在：%s" % src)
        return 2
    pngs = sorted(f for f in os.listdir(src) if f.lower().endswith(".png"))
    if only:
        pngs = [f for f in pngs if any(k in f for k in only)]
    print("待处理 %d 张：%s" % (len(pngs), src))
    made = 0
    skipped = 0
    for fn in pngs:
        stem = os.path.splitext(fn)[0]
        try:
            w, h = png_size(os.path.join(src, fn))
        except Exception as e:
            print("  [跳过] %s：%s" % (fn, e))
            skipped += 1
            continue
        real_cols = cols if cols > 0 else max(1, int(round(w / 192.0)))
        cell_w = max(1.0, float(w) / float(max(1, real_cols)))
        rows = max(1, int(math.ceil(float(h) / cell_w)))
        total = real_cols * rows
        dst_tscn = os.path.join(out_dir, "%s%s.tscn" % (prefix, safe_stem(stem)))
        if os.path.exists(dst_tscn) and not force:
            print("  [跳过] %s：%s 已存在（--force 覆盖）" % (fn, os.path.basename(dst_tscn)))
            skipped += 1
            continue
        print("  [导出] %-28s %dx%d → %d 格（%d列×%d行）" % (fn, w, h, total, real_cols, rows))
        if dry_run:
            made += 1
            continue
        dst_png = os.path.join(art_dir, fn)
        if not no_copy:
            os.makedirs(art_dir, exist_ok=True)
            if not os.path.exists(dst_png):
                shutil.copy2(os.path.join(src, fn), dst_png)
        elif not os.path.exists(dst_png):
            print("  [缺图] %s 不在 art/Animations（仍会生成 tscn，运行时会缺贴图）" % fn)
        write_tscn(dst_tscn, "res://art/Animations/%s" % fn, list(range(total)), fps, real_cols)
        made += 1
    print("\n完成：导出 %d，跳过 %d%s" % (made, skipped, "（dry-run）" if dry_run else ""))
    return 0


def selftest() -> int:
    """拿工程里现成的一张动画表跑一遍完整流程（复制 PNG + 写 tscn）。"""
    sample = os.path.join(ROOT, "art", "Animations", "血＋.png")
    if not os.path.isfile(sample):
        # 兜底：找任意一张
        adir = os.path.join(ROOT, "art", "Animations")
        cand = sorted(f for f in os.listdir(adir) if f.endswith(".png")) if os.path.isdir(adir) else []
        if not cand:
            print("[ERROR] art/Animations 下没有 PNG 可做自测")
            return 2
        sample = os.path.join(adir, cand[0])
    fails = 0

    def chk(label: str, cond: bool) -> None:
        nonlocal fails
        print(("  OK   " if cond else "  FAIL ") + label)
        if not cond:
            fails += 1

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        os.makedirs(src)
        fn = os.path.basename(sample)
        shutil.copy2(sample, os.path.join(src, fn))
        out_dir = os.path.join(tmp, "anim")
        art_dir = os.path.join(tmp, "art")
        rc = convert(src, out_dir, art_dir, 5, 20.0, [], "anim_", False, False)
        chk("转换返回 0", rc == 0)
        stem = os.path.splitext(fn)[0]
        tscn = os.path.join(out_dir, "anim_%s.tscn" % safe_stem(stem))
        chk("生成了 tscn", os.path.isfile(tscn))
        if os.path.isfile(tscn):
            txt = open(tscn, encoding="utf-8").read()
            chk("引用了 art/Animations", "res://art/Animations/%s" % fn in txt)
            chk("有帧序列", "frame_sequence = Array[int]([0," in txt)
            chk("行尾是 LF", "\r\n" not in txt)
        chk("复制了 PNG", os.path.isfile(os.path.join(art_dir, fn)))
    print("\n失败 %d 项" % fails)
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="动画精灵表 → anim/*.tscn 批量导入")
    ap.add_argument("--src", help="源目录（如 RMVA 的 Graphics/Animations）")
    ap.add_argument("--project", help="RM 工程根目录：自动找 Graphics/Animations（VA）或 Animations（2k/2k3）")
    ap.add_argument("--out", default=os.path.join(ROOT, "anim"))
    ap.add_argument("--art", default=os.path.join(ROOT, "art", "Animations"))
    ap.add_argument("--cols", type=int, default=0,
                    help="每行格数；0 = 自动（按 192px 格宽从图片宽度推算）")
    ap.add_argument("--fps", type=float, default=20.0)
    ap.add_argument("--only", default="", help="只处理文件名含这些关键字的（逗号分隔）")
    ap.add_argument("--prefix", default="anim_", help="输出文件名前缀")
    ap.add_argument("--force", action="store_true", help="覆盖已存在的 tscn")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-copy", action="store_true", help="不复制 PNG（素材已在工程里时用）")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    src = args.src
    if args.project:
        found = detect_anim_dir(args.project)
        if not found:
            print("[ERROR] 没在 %s 下找到 Graphics/Animations、Animations 或 art/Animations" % args.project)
            return 2
        src = found
        print("自动识别素材目录：%s" % src)
    if not src:
        ap.print_help()
        return 2
    only = [x for x in args.only.split(",") if x]
    return convert(src, args.out, args.art, args.cols, args.fps, only, args.prefix,
                   args.force, args.dry_run, args.no_copy)


if __name__ == "__main__":
    sys.exit(main())
