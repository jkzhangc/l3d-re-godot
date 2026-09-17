# -*- coding: utf-8 -*-
"""T-002 暴君：散件 → 正式行走图表（保真，帧 128x144）。

产出到 art/Characters/T002/：
  T002_body.png    —— 行走 + 待机（idx0=walk, idx1=idle）
  T002_attack.png  —— 攻击 4 阶段（idx0..idx3）
  T002_extra.png   —— 横を見る / 死亡 / 蹲 1-2（idx0..idx3）

帧尺寸由素材反算：Fw = W/3, Fh = H/4（== 128x144）。
输出表尺寸 = 角色格数 * 3 * Fw  x  1 * 4 * Fh（单行角色格，索引线性递增）。
"""
import sys, os, io
from PIL import Image

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

SRC_FRAMES, SRC_DIRS = 3, 4
SRCDIR = "art/Characters"
OUTDIR = "art/Characters/T002"

TABLES = [
    ("T002_body", [
        ("walk", "T-002タイラント走る"),
        ("idle", "T-002タイラント01"),
    ]),
    ("T002_attack", [
        ("attack1", "T-002タイラント攻撃1"),
        ("attack2", "T-002タイラント攻撃2"),
        ("attack3", "T-002タイラント攻撃3"),
        ("attack4", "T-002タイラント攻撃4"),
    ]),
    ("T002_extra", [
        ("look",    "T-002タイラント横を見る"),
        ("crouch1", "T-002タイラントしゃがみ1"),
        ("crouch2", "T-002タイラントしゃがみ2"),
        ("death",   "T-002タイラント死亡"),
    ]),
]


def load_grid(path):
    src = Image.open(path).convert("RGBA")
    W, H = src.size
    fw, fh = W // SRC_FRAMES, H // SRC_DIRS
    grid = [[src.crop((f * fw, d * fh, (f + 1) * fw, (d + 1) * fh))
             for f in range(SRC_FRAMES)] for d in range(SRC_DIRS)]
    return fw, fh, grid


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    for tname, entries in TABLES:
        fw = fh = None
        loaded = []
        for name, stem in entries:
            p = os.path.join(SRCDIR, f"!${stem}.png")
            if not os.path.isfile(p):
                print(f"  [{tname}] 缺源文件 {p}")
                continue
            fw_i, fh_i, grid = load_grid(p)
            if fw is None:
                fw, fh = fw_i, fh_i
            loaded.append((name, grid))
        if not loaded:
            continue
        cols = len(loaded)
        out = Image.new("RGBA", (cols * SRC_FRAMES * fw, SRC_DIRS * fh), (0, 0, 0, 0))
        for i, (name, grid) in enumerate(loaded):
            for d in range(SRC_DIRS):
                for f in range(SRC_FRAMES):
                    out.alpha_composite(grid[d][f], (i * SRC_FRAMES * fw + f * fw, d * fh))
        dst = os.path.join(OUTDIR, f"{tname}.png")
        out.save(dst)
        print(f"{tname}: {out.size}  帧={fw}x{fh}  " +
              " ".join(f"{n}→idx{i}" for i, (n, _) in enumerate(loaded)))


if __name__ == "__main__":
    main()
