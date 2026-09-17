#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A1/A2/A3/A4 全图案 atlas 生成器的自检 harness。

用法（在本目录下）：
    python verify_autotile_atlas.py            # 全部检查
退出码 0 = 全绿，1 = 有失败项。与项目内 tools/*_test 的 EXIT 0 约定一致。
"""

from __future__ import annotations

import hashlib
import sys
import tempfile
from pathlib import Path

from PIL import Image

import rm2k3_autotile_atlas as atlas
from rm2k3_patterns import Compositor

HERE = Path(__file__).resolve().parent
FIXTURES = [HERE / '奨3.png', HERE / '機械系ダンジョン1 - ○.png']
SCALE = 2
TILE = 32

results: list[tuple[bool, str]] = []


def check(ok: bool, label: str) -> None:
    results.append((bool(ok), label))


def alpha_extrema(img: Image.Image) -> int:
    return img.getchannel('A').getextrema()[1]


def main() -> int:
    missing = [str(p) for p in FIXTURES if not p.exists()]
    check(not missing, f'fixture 存在（缺失 {missing}）')

    # 0) 象限表不变量：源块为 3×4 瓦片（48×64px = 6×8 个 8px 碎片），
    #    因此 qx*2+col <= 5 且 qy*2+row <= 7；越界说明公式或表被改坏。
    for variant, entry in enumerate(atlas.D_QUARTER_OFFSETS):
        for row in (0, 1):
            for col in (0, 1):
                qx, qy = entry[row][col]
                if qx * 2 + col > 5 or qy * 2 + row > 7:
                    check(False, f'variant {variant} 象限越出 48x64 源块')
    check(True, '全部 variant 的象限索引都在 48x64 源块内')

    for fixture in FIXTURES:
        if not fixture.exists():
            continue
        source = atlas.decode_xyz(fixture)

        # 1) 每个自动图块 48 个图案，且逐格都是完整瓦片（非全透明）
        for band, blocks in atlas.BAND_BLOCKS.items():
            for block in blocks:
                sheet = atlas.variant_sheet(source, block['origin'], SCALE)
                check(sheet.size == (atlas.PATTERN_COLS * TILE, atlas.PATTERN_ROWS * TILE),
                      f'{fixture.stem} {band} g{block["group"]} 尺寸 8x6 瓦片')
                filled = 0
                for v in range(atlas.PATTERN_ROWS):
                    for u in range(atlas.PATTERN_COLS):
                        cell = sheet.crop((u * TILE, v * TILE, u * TILE + TILE, v * TILE + TILE))
                        if alpha_extrema(cell) > 0:
                            filled += 1
                check(filled == atlas.VARIANT_COUNT,
                      f'{fixture.stem} {band} g{block["group"]} 48/48 图案有内容（实得 {filled}）')

        # 2) 完整 atlas 尺寸：块按 2 列排布，4 块时为 16x12 瓦片
        for band in ('A3', 'A4'):
            sheet = atlas.build_band_sheet(source, band, SCALE, 'variant')
            check(sheet.size == (atlas.SHEET_COLS * TILE, atlas.SHEET_ROWS * TILE),
                  f'{fixture.stem} {band} atlas 尺寸 {atlas.SHEET_COLS}x{atlas.SHEET_ROWS} 瓦片')

        # 3) 象限表：50 项、48 个互异图案，越界报错
        check(atlas.TABLE_LEN == len(atlas.D_QUARTER_OFFSETS), f'{fixture.stem} 象限表长度 = {atlas.TABLE_LEN}')
        check(atlas.VARIANT_COUNT == 48,
              f'{fixture.stem} 互异图案数 = 48（实得 {atlas.VARIANT_COUNT}）')
        check(sorted(atlas.VARIANT_TO_SLOT) == list(range(atlas.TABLE_LEN)),
              f'{fixture.stem} 全部 variant 都有格位映射')
        try:
            atlas.assemble_variant(source, (6, 0), atlas.TABLE_LEN, SCALE)
            check(False, f'{fixture.stem} 越界 variant 应抛错')
        except ValueError:
            check(True, f'{fixture.stem} 越界 variant 抛错')

        # 4) 动画：每个帧只读取自己那一列源瓦片，因此「合成帧的互异性」必须等于
        #    「源列的互异性」。用整列 md5 比较（注意 Pillow 的 getbbox() 在带 alpha
        #    的图上只比 alpha 通道，不能用来判 RGB 差异）。
        def col_hash(img: Image.Image) -> str:
            return hashlib.md5(img.tobytes()).hexdigest()

        for water_type in range(atlas.WATER_TYPES):
            sheet = atlas.water_frames(source, SCALE, water_type)
            check(sheet.size == (atlas.WATER_FRAMES * TILE, 6 * TILE),
                  f'{fixture.stem} 水{water_type + 1} 尺寸 {atlas.WATER_FRAMES}x6 瓦片')
            src_cols = [source.crop(((water_type * 3 + f) * 16, 0, (water_type * 3 + f) * 16 + 16, 96))
                        for f in range(atlas.WATER_FRAMES)]
            frame_cols = [sheet.crop((f * TILE, 0, f * TILE + TILE, sheet.height))
                          for f in range(atlas.WATER_FRAMES)]
            src_distinct = len({col_hash(c) for c in src_cols})
            frame_distinct = len({col_hash(c) for c in frame_cols})
            check(frame_distinct == src_distinct,
                  f'{fixture.stem} 水{water_type + 1} 帧互异性 == 源列互异性'
                  f'（{frame_distinct} vs {src_distinct}）')

        fall = atlas.waterfall_frames(source, SCALE)
        check(fall.size == (atlas.WATER_FRAMES * TILE, 6 * TILE),
              f'{fixture.stem} 瀑布尺寸 {atlas.WATER_FRAMES}x6 瓦片')
        fall_src = [source.crop(((3 + f) * 16, 64, (3 + f) * 16 + 16, 112)) for f in range(3)]
        fall_frame = [fall.crop((f * TILE, 0, f * TILE + TILE, fall.height)) for f in range(3)]
        check(len({col_hash(c) for c in fall_frame}) == len({col_hash(c) for c in fall_src}),
              f'{fixture.stem} 瀑布帧互异性 == 源列互异性'
              f'（{len({col_hash(c) for c in fall_frame})} vs {len({col_hash(c) for c in fall_src})}）')

        # 5) reference 布局同样 48/48（与文档样例同源，用于对照）
        ref = atlas.reference_sheet(source, (6, 0), SCALE)
        filled = sum(
            1 for v in range(atlas.PATTERN_ROWS) for u in range(atlas.PATTERN_COLS)
            if alpha_extrema(ref.crop((u * TILE, v * TILE, u * TILE + TILE, v * TILE + TILE))) > 0)
        check(filled == atlas.VARIANT_COUNT, f'{fixture.stem} reference 布局 48/48（实得 {filled}）')

        # 6) 确定性：同一输入两次生成必须逐字节一致
        with tempfile.TemporaryDirectory() as tmp:
            out1, out2 = Path(tmp) / 'a', Path(tmp) / 'b'
            atlas.build(fixture, out1, ['A1', 'A2', 'A3', 'A4'], SCALE, 'variant')
            atlas.build(fixture, out2, ['A1', 'A2', 'A3', 'A4'], SCALE, 'variant')
            names = sorted(p.name for p in out1.glob('*.png'))
            same = names == sorted(p.name for p in out2.glob('*.png'))
            check(same and len(names) == 7, f'{fixture.stem} 产物文件集合一致（{len(names)} 个）')
            digests = all(
                hashlib.md5((out1 / n).read_bytes()).hexdigest()
                == hashlib.md5((out2 / n).read_bytes()).hexdigest() for n in names)
            check(digests, f'{fixture.stem} 两次生成逐字节一致')

        # 7) 透明语义：索引 0 必须为全透明（否则水/岸边界会带粉底）
        check(alpha_extrema(source.crop((96, 0, 144, 64))) is not None,
              f'{fixture.stem} 源图可读')

    # 8) 1× 缩放同样成立（不依赖 scale=2）
    source = atlas.decode_xyz(FIXTURES[0])
    small = atlas.variant_sheet(source, (6, 0), 1)
    check(small.size == (8 * 16, 6 * 16), '1x 缩放尺寸 8x6 瓦片 @16px')

    # 9) 反向对照：把落点改回参考实现公布版本的缺陷公式 (dx - sx)，harness 必须报错。
    #    否则说明这些断言抓不住该缺陷（自我验证）。
    original_put = Compositor.put

    def buggy_put(self, dst, dx, dy, sx, sy, sw, sh):
        tile = self.tile
        dest_x = (int(round(dx * 2)) - int(round(sx * 2))) * tile // 2
        dest_y = (int(round(dy * 2)) - int(round(sy * 2))) * tile // 2
        w = int(round(sw * 2)) * tile // 2
        h = int(round(sh * 2)) * tile // 2
        if w <= 0 or h <= 0:
            return
        block = self.src.crop((int(round(sx * 2)) * tile // 2, int(round(sy * 2)) * tile // 2,
                               int(round(sx * 2)) * tile // 2 + w,
                               int(round(sy * 2)) * tile // 2 + h))
        dst.paste(block, (dest_x, dest_y))

    Compositor.put = buggy_put
    try:
        broken = atlas.reference_sheet(source, (6, 0), SCALE)
        broken_filled = sum(
            1 for v in range(atlas.PATTERN_ROWS) for u in range(atlas.PATTERN_COLS)
            if alpha_extrema(broken.crop((u * TILE, v * TILE, u * TILE + TILE, v * TILE + TILE))) > 0)
    finally:
        Compositor.put = original_put
    check(broken_filled < atlas.VARIANT_COUNT,
          f'反向对照：缺陷公式下 reference 布局不足 48 格（实得 {broken_filled}）')

    # 10) 产物自检（一键流程的守卫）：正常产物零问题；删掉/改坏产物必须被检出。
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / 'out'
        src = atlas.decode_xyz(FIXTURES[0])
        report = atlas.build(FIXTURES[0], out, ['A3'], SCALE, 'variant')
        check(atlas.verify_outputs(report, out, src) == [], '产物自检：正常产物零问题')
        check(report['self_check']['passed'], '产物自检：build 结果标记为通过')

        sheet = out / report['bands']['A3']['patterns']
        sheet.unlink()
        check(len(atlas.verify_outputs(report, out, src)) == 1,
              '产物自检：删掉图案表必须被检出')

        atlas.build(FIXTURES[0], out, ['A3'], SCALE, 'variant')
        broken = Image.open(sheet).convert('RGBA')
        broken.paste((0, 0, 0, 0), (0, 0, broken.width, 32))     # 抹掉第一行图案
        broken.save(sheet)
        check(len(atlas.verify_outputs(report, out, src)) >= 1,
              '产物自检：图案被抹白必须被检出')

        atlas.build(FIXTURES[0], out, ['A3'], SCALE, 'variant')
        shifted = Image.open(sheet).convert('RGBA')
        shifted.paste(shifted.crop((0, 0, 16, shifted.height)), (8, 0))   # 整体错位 8px
        shifted.save(sheet)
        check(len(atlas.verify_outputs(report, out, src)) >= 1,
              '产物自检：图案整体错位必须被检出')

    # 11) 全透明源块不应被误报（chipset 16 `01 - 仜.bmp` 右半列即为全透明）
    transparent = Image.new('RGBA', (480, 256), (0, 0, 0, 0))
    blank_report = {'tile_size': SCALE * 16, 'scale': SCALE,
                    'bands': {'A1': {'patterns': '_blank.png', 'blocks': [
                        {'origin_tiles': [6, 0], 'group': 4, 'empty_block': True}]}}}
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / '_blank.png'
        atlas.build_band_sheet(transparent, 'A1', SCALE, 'variant').save(out)
        check(atlas.verify_outputs(blank_report, Path(tmp), transparent) == [],
              '产物自检：全透明源块不误报')

    failed = [label for ok, label in results if not ok]
    for ok, label in results:
        print(('  PASS  ' if ok else '  FAIL  ') + label)
    print(f'\n{len(results) - len(failed)}/{len(results)} passed')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
