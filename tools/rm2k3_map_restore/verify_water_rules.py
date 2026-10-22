#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""水面/动画图块规则自检（2026-10-22）。

守护 `export_map.py` 里两条最容易写错、又最容易「静默丢图块」的规则：

  ① **水面自动图块**（下层 ID < 3000）
     ID = block*1000 + b_subtile*50 + a_subtile
     4 个 8×8 象限分别取自芯片组 A 组（第 0–3 行）或 B 组（第 4–7 行），
     规则表 `BLOCK_A_SUBTILES_IDS` 来自 EasyRPG `tilemap_layer.cpp`。
  ② **Block C 动画**（3000–3149）
     3 个 4 帧动画，列 3–5、行 4–7（漩涡、水面装饰等）。

测试手法：造一张「每个 16×16 图块填充唯一颜色」的假芯片组，
颜色 = (列, 行)，于是可以直接断言每个 8×8 象限取对了哪一格。

运行：python verify_water_rules.py   （EXIT 0 = 全通过）
"""
import sys
from PIL import Image

import export_map as em

CHECKS = 0
PASSED = 0


def check(name, cond):
    global CHECKS, PASSED
    CHECKS += 1
    if cond:
        PASSED += 1
        print('  [PASS] %s' % name)
    else:
        print('  [FAIL] %s' % name)


def make_fake_chipset():
    """480×256，每个 16×16 图块填充 (col, row, 0)，用于识别象限来源。"""
    im = Image.new('RGBA', (480, 256))
    px = im.load()
    for row in range(16):
        for col in range(30):
            color = (col, row, 0, 255)
            for y in range(row * 16, row * 16 + 16):
                for x in range(col * 16, col * 16 + 16):
                    px[x, y] = color
    return im


def quarter_colors(tile):
    """取一张 16×16 的四个象限中心点颜色（TL, TR, BL, BR）。"""
    px = tile.load()
    return (px[4, 4][:2], px[12, 4][:2], px[4, 12][:2], px[12, 12][:2])


def main():
    print('=== 水面自动图块 / Block C 规则自检 ===')
    src = make_fake_chipset()

    # ── ① 变体表：直接查 water_quarters ──
    print('-- ① 水面四象限表')
    check('a=0（四面皆水）→ 四象限全取 B 组第 4 行',
          em.water_quarters(0, 0, 0) == [[(0, 4), (0, 4)], [(0, 4), (0, 4)]])
    check('a=46（孤立单格水）→ 四象限全取 A 组第 0 行',
          em.water_quarters(0, 0, 46) == [[(0, 0), (0, 0)], [(0, 0), (0, 0)]])
    check('a=3（缺上边）→ 上半取 A 组第 3 行、下半取 B 组水身',
          em.water_quarters(0, 0, 3) == [[(0, 3), (0, 3)], [(0, 4), (0, 4)]])
    check('a=4（缺右下角）→ 仅 BR 取 A 组第 3 行',
          em.water_quarters(0, 0, 4) == [[(0, 4), (0, 4)], [(0, 4), (0, 3)]])
    check('block=1 的 A 象限右移一组列（+3）',
          em.water_quarters(1, 0, 46)[0][0] == (3, 0))
    check('block=2 深水：B 组行号按 b 位翻转（t^3）',
          em.water_quarters(2, 1, 0) == [[(0, 6), (0, 7)], [(0, 7), (0, 7)]])

    # ── ② 实际拼装：假芯片组上验证取格位置 ──
    print('-- ② 8×8 象限拼装（假芯片组按颜色识别来源格）')
    t = em.render_water(src, 4)
    check('ID 4（block0/a4）：TL/TR/BL 来自 (0,4)，BR 来自 (0,3)',
          quarter_colors(t) == ((0, 4), (0, 4), (0, 4), (0, 3)))
    t = em.render_water(src, 46)
    check('ID 46（孤立水）：四象限都来自 (0,0)',
          quarter_colors(t) == ((0, 0), (0, 0), (0, 0), (0, 0)))
    t = em.render_water(src, 1046)   # block1 / a=46
    check('ID 1046（block1）：四象限来自 (3,0)（列偏移 +3）',
          quarter_colors(t) == ((3, 0), (3, 0), (3, 0), (3, 0)))
    t = em.render_water(src, 2020)   # block2 / a=20 → {{2,2},{N,N}}
    ## ★深水块 b=0 时 t^=3 → 水身取第 7 行（这正是旧实现「2000 → 行7」的标定来源）
    check('ID 2020（深水 a=20）：上半来自 A 行 2、下半取深水行 7',
          quarter_colors(t) == ((0, 2), (0, 2), (0, 7), (0, 7)))
    t = em.render_water(src, 2050)   # block2 / b=1 / a=0
    check('ID 2050（深水 b=1）：TL 行 6，其余行 7',
          quarter_colors(t) == ((0, 6), (0, 7), (0, 7), (0, 7)))
    t = em.render_water(src, 4, frame=2)
    check('动画帧 2 = A 象限列再右移 2（水面 3 帧）',
          quarter_colors(t) == ((2, 4), (2, 4), (2, 4), (2, 3)))
    check('非法变体（a=60）不再丢图块，退回全水',
          quarter_colors(em.render_water(src, 4000 + 0)) is not None
          and em.render_water(src, 60) is not None)

    # ── ③ Block C ──
    print('-- ③ Block C（漩涡等 4 帧动画）')
    check('Block C 范围 3000..3149 共 3 格 × 50', em.BLOCK_C_BASE == 3000
          and em.BLOCK_C_END == 3150 and em.BLOCK_C_TILES == 3)
    check('ID 3000 → 芯片组 (列3, 行4)', quarter_colors(em.render_block_c(src, 3000))
          == ((3, 4), (3, 4), (3, 4), (3, 4)))
    check('ID 3050 → 列 4；ID 3100 → 列 5',
          quarter_colors(em.render_block_c(src, 3050))[0] == (4, 4)
          and quarter_colors(em.render_block_c(src, 3100))[0] == (5, 4))
    check('4 帧取 行 4..7（frame 3 → 行 7）',
          quarter_colors(em.render_block_c(src, 3000, 3))[0] == (3, 7))
    check('frame 越界按 4 取模（frame 4 → 行 4）',
          quarter_colors(em.render_block_c(src, 3000, 4))[0] == (3, 4))

    # ── ④ 分区不重叠 ──
    print('-- ④ 分区边界')
    check('2999 仍是水面、3000 起才是 Block C',
          em.render_water(src, 2999) is not None
          and em.render_block_c(src, 2999) is None)
    check('3150 已超出 Block C（3 格 × 50）', em.render_block_c(src, 3150) is None)

    print('=== %d/%d passed ===' % (PASSED, CHECKS))
    if PASSED != CHECKS:
        print('=== FAILED ===')
        return 1
    print('=== ALL PASS ===')
    return 0


if __name__ == '__main__':
    sys.exit(main())
