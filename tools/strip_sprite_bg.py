#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""strip_sprite_bg.py — RM2K→VX 转换行走图批量去背景（纯色键控 + 边缘 flood fill）

用法：
    python strip_sprite_bg.py            # 按下面内置路径执行
    python strip_sprite_bg.py --dry      # 只打印计划，不写文件

规则：
1. 规范名 = 剥掉文件名开头的 $ 前缀与 [..]- 转换标记（[2K-VX]-X.png → X.png，
   $[XP-VX]-X.png → $X.png 保留 $ 单角色格式标记）。
2. 去重：规范名与现有素材（art/Characters、未使用素材，剥 !$ 标记比较）相同，
   或目录内互相重复 → 只保留一个，跳过其余。
3. 去背景：四角+边中点采样背景色 → 与边缘连通且颜色距离 ≤ 容差的像素置透明
   （flood fill，主体内部同色像素不受影响）；已是透明背景的图直接复制。
4. 输出到 <输入目录>/已处理透明/，生成 _strip_report.txt 处理报告。
"""
import sys
import re
import argparse
from pathlib import Path
from collections import Counter, deque

import numpy as np
from PIL import Image

ROOT = Path(r"D:\!bird's-eye-view-arpg-test-\l3d-re-godot")
SRC = ROOT / "需要去掉背景的行走图"
OUT = SRC / "已处理透明"
EXIST_DIRS = [ROOT / "art" / "Characters", ROOT / "未使用素材"]
TOL = 40  # 颜色距离容差（欧氏，0-441）


def canonical(name: str) -> str:
    """剥掉前导 $ 与 [..]- 转换标记，得到用于比较/输出的规范名。"""
    n = name
    n = re.sub(r"^\[([^\]]*)\]-?", "", n)   # [2K-VX]-X → X
    n = re.sub(r"^\$\[([^\]]*)\]-?", "$", n)  # $[XP-VX]-X → $X
    return n


def compare_key(name: str) -> str:
    """更激进的比较键：再剥 !$ 与扩展名，用于与现有素材对齐。"""
    n = canonical(name)
    n = n.lstrip("!$") if not n.startswith("!!") else n
    return n.rsplit(".", 1)[0].lower()


def sample_bg(arr: np.ndarray):
    """四角+四边中点 8 个 5x5 块的均值，量化到 24 级取众数；全异则取左上。"""
    h, w = arr.shape[:2]
    pts = [(0, 0), (0, w - 5), (h - 5, 0), (h - 5, w - 5),
           (h // 2, 0), (h // 2, w - 5), (0, w // 2), (h - 5, w // 2)]
    cols = []
    for y, x in pts:
        y = max(0, min(y, h - 5)); x = max(0, min(x, w - 5))
        blk = arr[y:y + 5, x:x + 5, :3].reshape(-1, 3).mean(axis=0)
        cols.append(tuple((blk // 24).astype(int)))
    cnt = Counter(cols)
    top, n = cnt.most_common(1)[0]
    if n == 1:  # 全不同：取四角平均
        return tuple((arr[0:5, 0:5, :3].reshape(-1, 3).mean(axis=0)).astype(int)), False
    # 反量化：在采样块里找属于该量化桶的实际均值
    for y, x in pts:
        y = max(0, min(y, h - 5)); x = max(0, min(x, w - 5))
        m = arr[y:y + 5, x:x + 5, :3].reshape(-1, 3).mean(axis=0)
        if tuple((m // 24).astype(int)) == top:
            return tuple(m.astype(int)), True
    return (top[0] * 24 + 12, top[1] * 24 + 12, top[2] * 24 + 12), True


def strip_bg(path: Path):
    """去背景。返回 (输出数组, 背景色, 是否原本已透明)。"""
    img = Image.open(path).convert("RGBA")
    arr = np.array(img)
    if arr.shape[2] < 4 or arr[:, :, 3].min() >= 255:
        pass  # 无 alpha 或全不透明，继续键控
    else:
        corner = arr[0:3, 0:3, 3]
        if corner.mean() < 8:
            return arr, None, True  # 已是透明背景
    bg, ok = sample_bg(arr)
    rgb = arr[:, :, :3].astype(int)
    dist = np.sqrt(((rgb - np.array(bg)) ** 2).sum(axis=2))
    bg_mask = dist <= TOL
    h, w = bg_mask.shape
    # 边缘 flood fill：只清除与边框连通的背景
    reach = np.zeros((h, w), dtype=bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            if bg_mask[y, x] and not reach[y, x]:
                reach[y, x] = True; dq.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if bg_mask[y, x] and not reach[y, x]:
                reach[y, x] = True; dq.append((y, x))
    while dq:
        y, x = dq.popleft()
        for ny, nx in ((y-1, x), (y+1, x), (y, x-1), (y, x+1)):
            if 0 <= ny < h and 0 <= nx < w and bg_mask[ny, nx] and not reach[ny, nx]:
                reach[ny, nx] = True; dq.append((ny, nx))
    arr = arr.copy()
    arr[reach, 3] = 0
    return arr, bg, False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--tol", type=int, default=TOL)
    args = ap.parse_args()
    tol = args.tol

    existing = set()
    for d in EXIST_DIRS:
        if d.is_dir():
            for p in d.iterdir():
                if p.suffix.lower() == ".png":
                    existing.add(compare_key(p.name))
    files = sorted(p for p in SRC.iterdir() if p.suffix.lower() == ".png")
    seen = {}
    plan, dups_existing, dups_inner = [], [], []
    for p in files:
        key = compare_key(p.name)
        if key in existing:
            dups_existing.append(p.name); continue
        if key in seen:
            dups_inner.append((p.name, seen[key])); continue
        seen[key] = p.name
        plan.append(p)
    print(f"待处理 {len(plan)} / 与现有素材同名跳过 {len(dups_existing)} / 目录内重复跳过 {len(dups_inner)}")
    if args.dry:
        for n in dups_existing: print("  [现有同名]" , n)
        for n, keep in dups_inner: print(f"  [目录重复] {n}（保留 {keep}）")
        return

    OUT.mkdir(exist_ok=True)
    report = [f"# 去背景处理报告  tol={tol}", f"",
              f"- 输入 {len(files)} 张；处理 {len(plan)} 张；"
              f"与现有素材同名跳过 {len(dups_existing)}；目录内重复跳过 {len(dups_inner)}", ""]
    if dups_existing:
        report.append("## 与现有素材同名（未处理，留现有）")
        report += [f"- {n}" for n in dups_existing] + [""]
    if dups_inner:
        report.append("## 目录内重复（未处理）")
        report += [f"- {n}（保留 {keep}）" for n, keep in dups_inner] + [""]
    report.append("## 已处理")
    for p in plan:
        out_name = canonical(p.name)
        arr, bg, was_alpha = strip_bg(p) if tol == TOL else strip_tol(p, tol)
        Image.fromarray(arr).save(OUT / out_name)
        tag = "已是透明背景，直接复制" if was_alpha else f"背景色 RGB{bg}"
        report.append(f"- {p.name} → {out_name}（{tag}）")
    (OUT / "_strip_report.txt").write_text("\n".join(report), encoding="utf-8")
    print(f"完成，输出目录 {OUT}")


def strip_tol(p: Path, tol: int):
    global TOL
    old = TOL; TOL = tol
    r = strip_bg(p)
    TOL = old
    return r


if __name__ == "__main__":
    main()
