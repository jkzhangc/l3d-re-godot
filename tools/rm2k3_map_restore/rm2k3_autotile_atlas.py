#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RM2K3 芯片组左侧自动图块区 → Godot 可直接使用的「全图案」atlas（A1/A2/A3/A4）。

背景
----
RM2K3 芯片组左侧 192×256 区域共 16 个 48×64 的槽位，其中：
  - 12 个是自动图块块（对应 Block D 的 group 0..11，即地图图块 ID 4000+50·g+v）
  -  4 个是动画区（水体/瀑布；位于 px(0,0)-(96,128)），地图数据里另有一套图块 ID

Godot 的 TileSetAtlasSource 只能消费「每格都完整」的瓦片，而 VX Ace / MV 的
A1/A2/A3/A4 是**复合格式**（一个自动图块由若干 8×8 碎片组成，运行时拼装），
因此本项目采用参考转换器（くらむぼん）的「附加素材 / おまけ」输出形态：

    单个自动图块 → 48 个完整瓦片，8 列 × 6 行

48 即 3×3 邻接位掩码的有效组合数。两张 8×6 块可并排/堆叠为 16×16 的
512×512 atlas（32×32 瓦片），与参考转换器的おまけ输出尺寸完全一致。

与参考转换器的差异（有意为之）
------------------------------
参考转换器的おまけ表把「源块原样」和「拼装图案」混在一张 8×6 里，格位顺序
不构成变体索引，无法直接对应邻接掩码。本模块默认 `--layout variant`，在**同一种
格式**（48 个完整瓦片 / 8×6）下改用 variant 0..47 顺序，格位即 RM2K3 的自动
图块变体号，可直接配 Godot TileSet Terrain 或手工绘制。
`--layout reference` 可还原参考转换器 putAllAutoTile 的原始摆法用于对照。

象限拼装复用 `export_map.py` 的 D_QUARTER_OFFSETS / D_GROUP_ORIGIN（已按
EasyRPG GenerateAutotiles() 修正并在 Map0141 上与 RM2K3 编辑器逐区对齐过）。
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image

try:                                    # 直接以脚本方式运行（本目录在 sys.path 上）
    from export_map import D_GROUP_ORIGIN, D_QUARTER_OFFSETS, decode_xyz, find_chipset, read_lmu
    from rm2k3_patterns import PATTERN_COLS, PATTERN_ROWS, Compositor
except ImportError:                     # 作为包被导入（如 tools.rm2k3_map_restore.*）
    from .export_map import D_GROUP_ORIGIN, D_QUARTER_OFFSETS, decode_xyz, find_chipset, read_lmu
    from .rm2k3_patterns import PATTERN_COLS, PATTERN_ROWS, Compositor

_ = D_GROUP_ORIGIN                      # 保留引用：分组原点表是本模块布局的权威来源

SRC_TILE = 16          # RM2K3 源瓦片边长
PIECE = 8              # 象限碎片边长
BLOCKS_PER_ROW = 2     # atlas 中 8×6 块的排布列数
SHEET_COLS = PATTERN_COLS * BLOCKS_PER_ROW          # 16
SHEET_ROWS = PATTERN_ROWS * 2                       # 12


def _distinct_variants() -> list[int]:
    """象限表的互异图案代表号。

    D_QUARTER_OFFSETS 实为 50 项，但只有 **48 个互异图案**（表内 0 / 47 / 48
    是同一「四面相邻＝内部填充」图案）。返回 48 个首次出现的 variant 号，
    顺序即 atlas 的 8×6 格位顺序。
    """
    seen: dict = {}
    order: list[int] = []
    for index, entry in enumerate(D_QUARTER_OFFSETS):
        if entry not in seen:
            seen[entry] = len(order)
            order.append(index)
    return order


def _slot_for(variant: int) -> int:
    """variant 号（0..49）→ atlas 格位（0..47）。"""
    entry = D_QUARTER_OFFSETS[variant]
    for slot, representative in enumerate(VARIANT_ORDER):
        if D_QUARTER_OFFSETS[representative] == entry:
            return slot
    raise ValueError(f'variant {variant} has no slot')


VARIANT_ORDER = _distinct_variants()                # 48 项
VARIANT_COUNT = len(VARIANT_ORDER)                  # = 48
TABLE_LEN = len(D_QUARTER_OFFSETS)                  # = 50，地图数据可寻址的范围
VARIANT_TO_SLOT = {v: _slot_for(v) for v in range(TABLE_LEN)}

# 左侧 192×256 的 16 个 48×64 槽位：band 为存储分区，group 为 Block D 的
# group 序号（tile_id = 4000 + 50 * group + variant），origin 为 16px 瓦片原点。
# 4 个动画槽位（px 0..96 × 0..128）不属于 Block D，单列在 ANIM 里。
BAND_BLOCKS: dict[str, list[dict]] = {
    'A1': [
        {'group': 4, 'origin': [6, 0]},
        {'group': 5, 'origin': [9, 0]},
    ],
    'A2': [
        {'group': 6, 'origin': [6, 4]},
        {'group': 7, 'origin': [9, 4]},
    ],
    'A3': [
        {'group': 0, 'origin': [0, 8]},
        {'group': 1, 'origin': [3, 8]},
        {'group': 8, 'origin': [6, 8]},
        {'group': 9, 'origin': [9, 8]},
    ],
    'A4': [
        {'group': 2, 'origin': [0, 12]},
        {'group': 3, 'origin': [3, 12]},
        {'group': 10, 'origin': [6, 12]},
        {'group': 11, 'origin': [9, 12]},
    ],
}

# 动画区（不属于 Block D）：px(0,0)-(96,96) 为水体（6×6 瓦片），
# 瀑布另取自瓦片 (3..5, 4..6)。参考转换器的 A1 段即按此读取。
ANIM_REGION = {'water': [0, 0, 6, 6], 'waterfall': [3, 4, 3, 3]}
WATER_FRAMES = 3
WATER_TYPES = 2        # pass1 = 源列 0,1,2；pass2 = 源列 3,4,5


# ────────────────────────────────────────────────────────────────
# 自动图块全图案
# ────────────────────────────────────────────────────────────────
def assemble_variant(source: Image.Image, origin, variant: int, scale: int) -> Image.Image:
    """按 variant 的象限表拼出一个完整瓦片（scale=2 时 32×32）。"""
    if not 0 <= variant < TABLE_LEN:
        raise ValueError(f'variant out of range: {variant}')
    ox, oy = origin
    offsets = D_QUARTER_OFFSETS[variant]
    out = Image.new('RGBA', (SRC_TILE * scale, SRC_TILE * scale), (0, 0, 0, 0))
    for row in (0, 1):
        for col in (0, 1):
            qx, qy = offsets[row][col]
            x = ((ox + qx) * 2 + col) * PIECE
            y = ((oy + qy) * 2 + row) * PIECE
            piece = source.crop((x, y, x + PIECE, y + PIECE))
            if scale != 1:
                piece = piece.resize((PIECE * scale, PIECE * scale), Image.Resampling.NEAREST)
            out.alpha_composite(piece, (col * PIECE * scale, row * PIECE * scale))
    return out


def variant_sheet(source: Image.Image, origin, scale: int) -> Image.Image:
    """单个自动图块 → 8×6 = 48 个完整瓦片。

    格位 (u, v) 的顺序即 VARIANT_ORDER（互异图案的首次出现顺序）；
    具体 variant 号到格位的换算见 VARIANT_TO_SLOT / 报告里的 variant_to_slot。
    """
    tile = SRC_TILE * scale
    sheet = Image.new('RGBA', (PATTERN_COLS * tile, PATTERN_ROWS * tile), (0, 0, 0, 0))
    for slot, variant in enumerate(VARIANT_ORDER):
        u, v = slot % PATTERN_COLS, slot // PATTERN_COLS
        sheet.alpha_composite(assemble_variant(source, origin, variant, scale), (u * tile, v * tile))
    return sheet


def reference_sheet(source: Image.Image, origin, scale: int) -> Image.Image:
    """参考转换器 putAllAutoTile 的原始摆法（用于与文档样例对照）。"""
    compositor = Compositor(source, scale)
    sheet = compositor.canvas(PATTERN_COLS, PATTERN_ROWS)
    compositor.put_all_auto_tile(sheet, 0, 0, origin[0], origin[1])
    return sheet


def build_band_sheet(source: Image.Image, band: str, scale: int, layout: str) -> Image.Image:
    """把 band 内最多 4 个自动图块拼成 16×16 的 atlas（32×32 瓦片时 512×512）。"""
    blocks = BAND_BLOCKS[band]
    tile = SRC_TILE * scale
    sheet = Image.new('RGBA', (SHEET_COLS * tile, SHEET_ROWS * tile), (0, 0, 0, 0))
    for index, block in enumerate(blocks):
        slot_x, slot_y = index % BLOCKS_PER_ROW, index // BLOCKS_PER_ROW
        if layout == 'reference':
            block_img = reference_sheet(source, block['origin'], scale)
        else:
            block_img = variant_sheet(source, block['origin'], scale)
        sheet.alpha_composite(block_img, (slot_x * PATTERN_COLS * tile, slot_y * PATTERN_ROWS * tile))
    return sheet


# ────────────────────────────────────────────────────────────────
# 水 / 瀑布动画（参考转换器 A1 段，坐标缺陷已修正）
# ────────────────────────────────────────────────────────────────
def _put_water_frame(compositor: Compositor, dst: Image.Image, dx: int, dy: int,
                     sx: int, sy_base: int) -> None:
    """参考转换器 A1 段水体单个帧的 2×3 瓦片装配（逐行照搬，仅修正落点）。"""
    put_full, put_half = compositor.put_full, compositor.put_half
    put_full(dst, dx + 0, dy + 0, sx + 0, sy_base + 0)
    put_full(dst, dx + 1, dy + 0, sx + 0, sy_base + 3)
    put_half(dst, dx + 0, dy + 1, sx + 0, sy_base + 0)
    put_half(dst, dx + 0.5, dy + 1, sx + 0.5, sy_base + 2)
    put_half(dst, dx + 1, dy + 1, sx + 0, sy_base + 2)
    put_half(dst, dx + 1.5, dy + 1, sx + 0.5, sy_base + 0)
    put_half(dst, dx + 0, dy + 1.5, sx + 0, sy_base + 1.5)
    put_half(dst, dx + 0.5, dy + 1.5, sx + 0.5, sy_base + 4.5)
    put_half(dst, dx + 1, dy + 1.5, sx + 0, sy_base + 4.5)
    put_half(dst, dx + 1.5, dy + 1.5, sx + 0.5, sy_base + 1.5)
    put_half(dst, dx + 0, dy + 2, sx + 0, sy_base + 1)
    put_half(dst, dx + 0.5, dy + 2, sx + 0.5, sy_base + 4)
    put_half(dst, dx + 1, dy + 2, sx + 0, sy_base + 4)
    put_half(dst, dx + 1.5, dy + 2, sx + 0.5, sy_base + 1)
    put_half(dst, dx + 0, dy + 2.5, sx + 0, sy_base + 0.5)
    put_half(dst, dx + 0.5, dy + 2.5, sx + 0.5, sy_base + 2.5)
    put_half(dst, dx + 1, dy + 2.5, sx + 0, sy_base + 2.5)
    put_half(dst, dx + 1.5, dy + 2.5, sx + 0.5, sy_base + 0.5)


def _stack_frames(frames: list[Image.Image], cols: int, rows: int) -> Image.Image:
    """把每帧的 cols×rows 示意块重排为「行=图案、列=连续帧」。

    Godot 的 TileSetAtlasSource 要求动画帧是 atlas 中**连续的水平格**，
    因此统一采用该排布，而不是参考转换器的「帧横向并排成 2×3 块」。
    """
    cell = frames[0].width // cols
    sheet = Image.new('RGBA', (len(frames) * cell, cols * rows * cell), (0, 0, 0, 0))
    for r in range(rows):
        for c in range(cols):
            pattern_row = r * cols + c
            for f, img in enumerate(frames):
                piece = img.crop((c * cell, r * cell, c * cell + cell, r * cell + cell))
                sheet.alpha_composite(piece, (f * cell, pattern_row * cell))
    return sheet


def water_frames(source: Image.Image, scale: int, water_type: int) -> Image.Image:
    """一种水体的 3 帧；每行 = 一个示意格，横向 3 格即连续帧。"""
    if not 0 <= water_type < WATER_TYPES:
        raise ValueError(f'water_type out of range: {water_type}')
    compositor = Compositor(source, scale)
    frames = []
    for frame in range(WATER_FRAMES):
        img = compositor.canvas(2, 3)
        _put_water_frame(compositor, img, 0, 0, water_type * WATER_FRAMES + frame, 0)
        frames.append(img)
    return _stack_frames(frames, cols=2, rows=3)


def _put_waterfall(compositor: Compositor, dst: Image.Image,
                   sx: int, sy: int) -> None:
    """参考转换器 A1 段瀑布：每帧为 2 列 × 3 行，帧沿纵向堆叠（共 9 行）。"""
    for frame in range(3):
        for k in range(3):
            compositor.put_full(dst, 0, frame * 3 + k, sx + frame, sy + k)
            compositor.put_full(dst, 1, frame * 3 + k, sx + frame, sy + k)


def waterfall_frames(source: Image.Image, scale: int) -> Image.Image:
    """瀑布：3 帧；每行 = 一个示意格，横向 3 格即连续帧。"""
    compositor = Compositor(source, scale)
    tile = compositor.tile
    raw = compositor.canvas(2, 9)
    _put_waterfall(compositor, raw, ANIM_REGION['waterfall'][0], ANIM_REGION['waterfall'][1])
    frames = [raw.crop((0, f * 3 * tile, 2 * tile, f * 3 * tile + 3 * tile)) for f in range(3)]
    return _stack_frames(frames, cols=2, rows=3)


# ────────────────────────────────────────────────────────────────
# 生成后自检（供一键流程使用：产物不合格即中断，不留半成品）
# ────────────────────────────────────────────────────────────────
def verify_outputs(report: dict, output: Path, source: Image.Image) -> list[str]:
    """回读落盘产物，与「按定义重新拼装的结果」逐格逐像素比对。

    不用「格子是否非空」计数：部分地图集（如 chipset 16 `01 - 仜.bmp`）的右半列
    自动图块在源图里就是全透明的，计数会误报。逐像素比对既无误报，也能抓出
    截断写入、偏移错位、尺寸不符。
    """
    tile = report['tile_size']
    scale = report['scale']
    expected_size = (SHEET_COLS * tile, SHEET_ROWS * tile)
    problems: list[str] = []
    for band, assets in report['bands'].items():
        sheet_path = output / assets['patterns']
        if not sheet_path.exists():
            problems.append(f'{band}: {sheet_path.name} 缺失')
            continue
        sheet = Image.open(sheet_path).convert('RGBA')
        if sheet.size != expected_size:
            problems.append(f'{band}: {sheet_path.name} 尺寸 {sheet.size} != {expected_size}')
            continue
        mismatch = 0
        for index, block in enumerate(assets['blocks']):
            base_x = (index % BLOCKS_PER_ROW) * PATTERN_COLS * tile
            base_y = (index // BLOCKS_PER_ROW) * PATTERN_ROWS * tile
            for slot, variant in enumerate(VARIANT_ORDER):
                want = assemble_variant(source, block['origin_tiles'], variant, scale)
                u, v = slot % PATTERN_COLS, slot // PATTERN_COLS
                got = sheet.crop((base_x + u * tile, base_y + v * tile,
                                  base_x + u * tile + tile, base_y + v * tile + tile))
                if got.tobytes() != want.tobytes():
                    mismatch += 1
        if mismatch:
            problems.append(f'{band}: {sheet_path.name} 有 {mismatch} 个图案与定义不符')
        for key, meta in assets.items():
            if key in ('patterns', 'blocks'):
                continue
            anim_path = output / meta['file']
            if not anim_path.exists():
                problems.append(f'{band}: {anim_path.name} 缺失')
                continue
            anim = Image.open(anim_path).convert('RGBA')
            expect = (meta['frames'] * tile, 6 * tile)
            if anim.size != expect:
                problems.append(f'{band}: {anim_path.name} 尺寸 {anim.size} != {expect}')
    return problems


# ────────────────────────────────────────────────────────────────
# 入口
# ────────────────────────────────────────────────────────────────
def build(chipset_path: Path, output: Path, bands, scale: int, layout: str) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    source = decode_xyz(chipset_path)
    stem = chipset_path.stem
    report = {
        'chipset': str(chipset_path),
        'scale': scale,
        'tile_size': SRC_TILE * scale,
        'layout': layout,
        'format': ('single autotile expanded to 48 complete tiles (8 cols x 6 rows); '
                   'sheets pack up to 4 blocks into a 16x16 atlas'),
        'bands': {},
        'warnings': [],
    }
    for band in bands:
        blocks = BAND_BLOCKS[band]
        sheet = build_band_sheet(source, band, scale, layout)
        name = f'{stem}_{band}_patterns.png'
        sheet.save(output / name)
        entries = []
        for index, block in enumerate(blocks):
            slot_x, slot_y = index % BLOCKS_PER_ROW, index // BLOCKS_PER_ROW
            ox, oy = block['origin']
            # 互异图案数：源块本身可能是均匀填充（RM2K3 里等价于普通图块），
            # 此时 48 个图案全同，并非转换错误 —— 报告里显式标出。
            distinct = len({assemble_variant(source, block['origin'], v, 1).tobytes()
                            for v in range(TABLE_LEN)})
            empty = all(
                assemble_variant(source, block['origin'], v, 1).getchannel('A').getextrema()[1] == 0
                for v in range(TABLE_LEN))
            entries.append({
                'block_index': index,
                'group': block['group'],
                'tile_id_base': 4000 + 50 * block['group'],
                'source_rect_tiles': [ox, oy, ox + 3, oy + 4],
                'source_rect_px': [ox * SRC_TILE, oy * SRC_TILE,
                                   (ox + 3) * SRC_TILE, (oy + 4) * SRC_TILE],
                'origin_tiles': [ox, oy],
                'sheet_slot_tiles': [slot_x * PATTERN_COLS, slot_y * PATTERN_ROWS],
                'pattern_origin_tiles': [slot_x * PATTERN_COLS, slot_y * PATTERN_ROWS],
                'distinct_patterns': distinct,
                'uniform_block': distinct == 1 and not empty,
                'empty_block': empty,
                'variant_to_slot': {str(v): VARIANT_TO_SLOT[v] for v in range(TABLE_LEN)},
                'slot_to_variant': VARIANT_ORDER,
                'pattern_coord': ('slot = (slot_to_variant index); (u, v) = (slot % 8, slot // 8); '
                                  'atlas coords = pattern_origin_tiles + (u, v)'),
                'tile_id_note': ('tile_id = 4000 + 50 * group + variant，variant 0..49；'
                                 '0/47/48 为同一图案，故 48 个互异格位覆盖全部 variant'),
            })
        assets = {'patterns': name, 'blocks': entries}
        if band == 'A1':
            for water_type in range(WATER_TYPES):
                anim = water_frames(source, scale, water_type)
                anim_name = f'{stem}_{band}_water{water_type + 1}_frames.png'
                anim.save(output / anim_name)
                assets[f'water{water_type + 1}_frames'] = {
                    'file': anim_name,
                    'source_tiles': {'x': water_type * WATER_FRAMES, 'y': 0,
                                     'w': WATER_FRAMES, 'h': 6},
                    'frames': WATER_FRAMES,
                    'layout': 'rows = 6 schematic cells (2 cols x 3 rows), columns = consecutive frames',
                    'tile_size_px': SRC_TILE * scale,
                    'needs_calibration': True,
                    'note': ('水体动画的帧拼装按参考转换器 A1 段 1:1 移植并经文档样例校验；'
                             '水体的邻接变体（岸边）语义仍待按 RM2K3 编辑器确认'),
                }
        if band == 'A2':
            fall = waterfall_frames(source, scale)
            fall_name = f'{stem}_{band}_waterfall_frames.png'
            fall.save(output / fall_name)
            assets['waterfall_frames'] = {
                'file': fall_name,
                'source_tiles': ANIM_REGION['waterfall'],
                'frames': 3,
                'layout': 'rows = 6 schematic cells (2 cols x 3 rows), columns = consecutive frames',
                'tile_size_px': SRC_TILE * scale,
                'needs_calibration': True,
                'note': '参考转换器注明第 4 帧在 RM2K3 源素材中缺失',
            }
        report['bands'][band] = assets
        report['warnings'].append(
            f'{band}: positions follow the validated quadrant table; '
            f'verify against the RM2K3 editor before hand painting'
        )
    problems = verify_outputs(report, output, source)
    report['self_check'] = {'passed': not problems, 'problems': problems}
    (output / f'{stem}_A1A4_report.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    if problems:
        raise RuntimeError('产物自检未通过：' + '；'.join(problems))
    return report


def resolve_targets(game_dir: str | None, chipset_ids: str | None,
                    map_id: int | None, chipset: str | None) -> list[Path]:
    """把命令行给出的三种入口统一解析成芯片组文件列表（按文件名去重）。"""
    targets: list[Path] = []
    if game_dir and map_id is not None:
        unit = read_lmu(Path(game_dir) / ('Map%04d.lmu' % map_id))
        if unit['chipset'] is None:
            raise SystemExit('LMU 不含芯片组字段，无法按地图解析')
        targets.append(find_chipset(Path(game_dir), unit['chipset'], None))
    elif game_dir and chipset_ids:
        game = Path(game_dir)
        for raw in chipset_ids.split(','):
            targets.append(find_chipset(game, int(raw.strip()), None))
    elif chipset:
        targets.append(Path(chipset))
    else:
        raise SystemExit('需要提供 <chipset>、--game-dir 配合 --map-id，或 --game-dir 配合 --chipset-ids')

    unique: list[Path] = []
    seen: set[str] = set()
    for target in targets:              # 同一素材被多个 ID 引用时只生成一次
        if target.name in seen:
            continue
        seen.add(target.name)
        unique.append(target)
    return unique


def main() -> None:
    ap = argparse.ArgumentParser(description='RM2K3 芯片组 A1/A2/A3/A4 → Godot 全图案 atlas')
    ap.add_argument('chipset', nargs='?', help='芯片组文件（.xyz/.png/.bmp）')
    ap.add_argument('--game-dir', help='RM2K3 工程目录；配合 --map-id 或 --chipset-ids 解析芯片组')
    ap.add_argument('--map-id', type=int, help='地图 ID：从 LMU 的芯片组字段解析，一键流程用')
    ap.add_argument('--chipset-ids', help='芯片组 ID（逗号分隔），按 --game-dir 解析')
    ap.add_argument('--output', required=True)
    ap.add_argument('--bands', default='A1,A2,A3,A4')
    ap.add_argument('--scale', type=int, default=2)
    ap.add_argument('--layout', choices=('variant', 'reference'), default='variant')
    args = ap.parse_args()
    bands = [b.strip().upper() for b in args.bands.split(',') if b.strip()]
    unknown = [b for b in bands if b not in BAND_BLOCKS]
    if unknown:
        raise SystemExit('unknown bands: ' + ','.join(unknown))

    for target in resolve_targets(args.game_dir, args.chipset_ids, args.map_id, args.chipset):
        report = build(target, Path(args.output), bands, args.scale, args.layout)
        print(f'== {target.name}')
        for band, assets in report['bands'].items():
            extra = ' '.join(assets[k]['file'] for k in assets if k not in ('patterns', 'blocks'))
            empty = sum(1 for b in assets['blocks'] if b['empty_block'])
            uniform = sum(1 for b in assets['blocks'] if b['uniform_block'])
            notes = []
            if empty:
                notes.append(f'{empty} 个空块')
            if uniform:
                notes.append(f'{uniform} 个均匀填充块')
            note = ('（' + '，'.join(notes) + '）') if notes else ''
            print(f'  {band}: {assets["patterns"]} ({len(assets["blocks"])} blocks){note} {extra}')
        print('  自检：通过' if report['self_check']['passed'] else '  自检：未通过')
    print('output:', args.output)


if __name__ == '__main__':
    main()
