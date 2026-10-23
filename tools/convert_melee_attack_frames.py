#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""convert_melee_attack_frames.py — 近战武器「攻击动作图」批量转换

把 `未使用素材/` 里各近战武器的挥击帧（RM2K3 原生 1x，画布 104x74 / 106x74 等）
去纯色背景并放大 2 倍，输出到 `art/WeaponAttack/<武器名>/`，每帧一张图、保留原文件名。

为什么是 2 倍：
    本项目角色帧是 48x64 = RM2K3 角色帧（24x32）的 2 倍；
    这些武器图是同一套 1x 素材，不放大 2 倍会和角色比例对不上。

去背景规则（与 tools/strip_sprite_bg.py 同一套）：
    从**画布四边** flood fill，颜色距离 ≤ TOL 的像素判为背景置透明。
    只清与边框连通的区域 —— 武器内部/残影内部恰好同色的像素不会被误伤。

用法：
    python tools/convert_melee_attack_frames.py --dry     # 只列清单
    python tools/convert_melee_attack_frames.py           # 实际转换
"""
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(r"D:\!bird's-eye-view-arpg-test-\l3d-re-godot")
SRC = ROOT / "未使用素材"
OUT = ROOT / "art" / "WeaponAttack"
SCALE = 2
TOL = 26          # 颜色距离容差（欧氏 0–441）
FULL = "０１２３４５６７８９"

## ── 纳入范围：近战武器（刀剑 / 钝器 / 长柄），按「族名」列出 ──
## 每族下面的 01…16（+ 05B…16B / 05C…08C）会整族一起转换。
## 判定依据：画布 104x74 / 106x74（RM2K3 武器动作帧格式），
## 且内容只有武器本体 + 挥击残影（不含角色、不含技能特效）。
MELEE_FAMILIES: list[str] = [
    # 刀剑
    "DF剣",
    "アンジェロソード",
    "クラウザーブレイード",
    "ゼットセイバー",
    "ゼットセイバー炎",
    "ゼットセイバー氷",
    "ゼットセイバー雷",
    "スカルブレード",
    "スカルブレード刺",
    "ネロ剣",
    "ネロ剣刺",
    "ポスタルソード",
    "人斬り包丁",
    "大剣",
    "大剣刺",
    "伝説剣",
    "伝説剣刺",
    "貫きの剣",
    "貫きの剣刺",
    "理力刃",
    "理力刃刺",
    "閻魔刀",
    "閻魔刀刃",
    "閻魔刀刃(咲夜)",
    "打刀",
    "木刀",
    "Ｎソード",
    "マクベの刺剣",
    "カマイタチの刃",
    "赤姫",
    "赤姫刃",
    "赤姫炎",
    "赤姫左",
    "赤姫左炎",
    # 钝器 / 长柄 / 其它近战
    "金属バット",
    "鉄パイプ",
    "消火器",
    "デッキブラシ",
    "シャベル",
    "スレッジハンマー",
    "防火斧",
    "処刑者の大斧",
    "デスサイズ",
    "ディファイラー",
    "チェンソー",
    "小型チェーンソー",
    "小型チェーンソー左",
    "鎧剣",
    "鎧剣(炎)",
    "鎧斧槍(大型)",
    "塔の槍",
    "槍(お手製)",
    "大鎌",
    "爪",
]

## 族名 → 允许的文件名后缀模式（全角数字 + 可选 B/C）。
## 大剣族另有 `大剣０５(雷)` 这类带括号的变体，单独放行。
EXTRA_ALLOW = ("大剣",)   # 允许 base+(内容) 形式


def frame_files(family: str) -> list[Path]:
    out = []
    for p in sorted(SRC.iterdir()):
        if p.suffix.lower() not in (".png", ".bmp"):
            continue
        stem = p.stem
        if not stem.startswith(family):
            continue
        rest = stem[len(family):]
        if rest == "":
            continue
        # rest 必须是「全角数字 + 可选 B/C」或（少数族）「全角数字(内容)」
        ok = False
        if all(ch in FULL for ch in rest):
            ok = True
        elif rest[-1] in ("B", "C", "Ｂ", "Ｃ") and all(ch in FULL for ch in rest[:-1]):
            ok = True
        elif family in EXTRA_ALLOW and rest.endswith(")") and "(" in rest:
            head = rest[:rest.index("(")]
            ok = all(ch in FULL for ch in head)
        if ok:
            out.append(p)
    return out


def strip_bg(arr: np.ndarray) -> tuple[np.ndarray, tuple, bool]:
    """四边 flood fill 去背景。返回 (新数组, 背景色, 是否本来就是透明底)。"""
    h, w = arr.shape[:2]
    alpha = arr[:, :, 3]
    if alpha.min() < 250 and alpha[0:3, 0:3].mean() < 8:
        return arr, None, True  # 已经是透明底
    rgb = arr[:, :, :3].astype(int)
    # 背景色 = 四边出现最多的颜色
    border = np.concatenate([rgb[0, :, :], rgb[h - 1, :, :], rgb[:, 0, :], rgb[:, w - 1, :]])
    cols, counts = np.unique(border, axis=0, return_counts=True)
    bg = cols[int(counts.argmax())]
    dist = np.sqrt(((rgb - bg) ** 2).sum(axis=2))
    near = dist <= TOL

    reach = np.zeros((h, w), dtype=bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near[y, x] and not reach[y, x]:
                reach[y, x] = True
                dq.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if near[y, x] and not reach[y, x]:
                reach[y, x] = True
                dq.append((y, x))
    while dq:
        y, x = dq.popleft()
        for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
            if 0 <= ny < h and 0 <= nx < w and near[ny, nx] and not reach[ny, nx]:
                reach[ny, nx] = True
                dq.append((ny, nx))
    arr = arr.copy()
    arr[reach, 3] = 0
    # 第二遍：武器轮廓**内部**被围住的同色空洞（刀身与护手之间的缝等）flood fill 够不到，
    # 不处理会在成品上留几个绿色小点。用「与背景色完全相等」精确匹配清掉，不吃掉近似色。
    arr[dist == 0, 3] = 0
    return arr, tuple(int(v) for v in bg), False


def main() -> None:
    import sys
    dry = "--dry" in sys.argv

    total = 0
    report = ["# 近战武器攻击图转换报告", "",
              "源：`未使用素材/`（RM2K3 1x）；输出：`art/WeaponAttack/<武器>/`（2x，透明底）", ""]
    for fam in MELEE_FAMILIES:
        files = frame_files(fam)
        if not files:
            print(f"!! 空族 {fam}")
            continue
        total += len(files)
        sizes = sorted({Image.open(p).size for p in files})
        print(f"{fam:<18} {len(files):>3} 帧  {'/'.join('%dx%d' % s for s in sizes)}")
        if dry:
            continue
        dst = OUT / fam
        dst.mkdir(parents=True, exist_ok=True)
        for p in files:
            im = Image.open(p).convert("RGBA")
            arr, bg, was_alpha = strip_bg(np.array(im))
            out = Image.fromarray(arr).resize(
                (im.width * SCALE, im.height * SCALE), Image.NEAREST)
            out.save(dst / (p.stem + ".png"))
        report.append(f"## {fam}（{len(files)} 帧）")
        report.append(f"- {files[0].stem} … {files[-1].stem}，"
                      f"画布 {sizes[0][0]}x{sizes[0][1]} → "
                      f"{sizes[0][0] * SCALE}x{sizes[0][1] * SCALE}")
        report.append("")

    print(f"\n合计 {total} 帧 / {len(MELEE_FAMILIES)} 族")
    if dry:
        return
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "_convert_report.md").write_text("\n".join(report), encoding="utf-8")
    print(f"输出目录 {OUT}")


if __name__ == "__main__":
    main()
