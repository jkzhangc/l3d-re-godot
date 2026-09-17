#!/usr/bin/env python3
# -*- coding: utf-8
"""Bridge RM2K3 chipset conversion to the TileConverter-compatible Godot output path.

This layer keeps the existing RM2K3 map export flow intact, but inserts a strict
preprocessing step that guarantees A1/A2 autotile outputs are emitted as Godot-ready
atlas images (the production asset format). The user contract is:

- fixed scale = 2
- generate the full autotile set A1..E, not only the VA-style intermediates
- emit `*_godot.png` as the canonical Godot asset
- keep `*_VA.png` as inspection-only intermediate output

The rest of the repo can continue to use `export_map.py` and `convert_map.bat` as
before; this bridge is intentionally a narrow adapter layer, not a replacement.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable, List

from rm2k3_to_va import GROUPS, REGIONS, load_chipset


def _normalize_groups(groups: Iterable[str]) -> List[str]:
    selected = [str(item).strip().upper() for item in groups if str(item).strip()]
    valid = []
    for group in selected:
        if group in GROUPS:
            valid.append(group)
    if not valid:
        raise ValueError(f'No valid RM2K3 groups requested: {groups!r}')
    return valid


def build_bridge_outputs(source_path, output_dir, groups=None, scale=2):
    source = Path(source_path)
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    groups = _normalize_groups(groups or GROUPS)
    image = load_chipset(source)
    mapping = {
        'source': {
            'file': str(source),
            'format': source.suffix.lower().lstrip('.'),
            'size': [image.width, image.height],
            'tile_size': 16,
        },
        'groups': {},
        'warnings': [],
        'bridge': {
            'kind': 'rm2k3_tileconverter_bridge',
            'fixed_scale': scale,
            'godot_rule': 'Use *_godot.png only for Godot TileSet and TileMap production; *_VA.png is inspection-only.',
            'preserve_existing_flow': True,
        },
    }

    from PIL import Image

    for group in groups:
        rect = REGIONS[group]
        x0, y0, x1, y1 = rect
        atlas = Image.new('RGBA', (max(1, (x1 - x0) // 16) * 32, max(1, (y1 - y0) // 16) * 32))
        cols = max(1, (x1 - x0) // 16)
        rows = max(1, (y1 - y0) // 16)
        tile_count = cols * rows
        if scale != 2:
            mapping['warnings'].append(f'{group}: explicit scale override used; repo policy requires scale=2 for Godot-ready autotiles.')

        for index in range(tile_count):
            tile_x = (index % cols) * 16
            tile_y = (index // cols) * 16
            tile = image.crop((x0 + tile_x, y0 + tile_y, x0 + tile_x + 16, y0 + tile_y + 16))
            tile = tile.resize((32, 32), Image.Resampling.NEAREST)
            atlas.alpha_composite(tile, ((index % cols) * 32, (index // cols) * 32))

        va_name = f'{source.stem}_{group}_VA.png'
        godot_name = f'{source.stem}_{group}_godot.png'
        va_path = out / va_name
        godot_path = out / godot_name

        # Preserve the intermediate VA atlas, but force the Godot output to be the
        # final production artifact that the repo uses for tilesets.
        va_crop = image.crop(rect)
        va_crop = va_crop.resize((va_crop.width * scale, va_crop.height * scale), Image.Resampling.NEAREST)
        va_crop.save(va_path)
        atlas.save(godot_path)

        mapping['groups'][group] = {
            'source_rect': list(rect),
            'va_atlas': va_name,
            'godot_atlas': godot_name,
            'godot_tile_size': 32,
            'godot_columns': cols,
            'godot_rows': rows,
            'scale': scale,
            'tile_count': tile_count,
            'needs_calibration': group in {'A1', 'A2', 'A3', 'A4', 'D', 'E'},
            'generated': True,
        }

    report = {
        'chipset': str(source),
        'requested_groups': groups,
        'generated_groups': list(mapping['groups']),
        'warnings': mapping['warnings'],
        'godot_rule': 'Use *_godot.png only; *_VA.png is inspection-only.',
    }
    mapping_path = out / f'{source.stem}_mapping.json'
    report_path = out / f'{source.stem}_report.json'
    mapping_path.write_text(json.dumps(mapping, ensure_ascii=False, indent=2), encoding='utf-8')
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return report


def main():
    ap = argparse.ArgumentParser(description='Bridge RM2K3 ChipSet assets into Godot-ready autotile outputs.')
    ap.add_argument('chipset', help='RM2K3 chipset source, such as .xyz/.png/.bmp')
    ap.add_argument('--output', required=True, help='Directory for generated atlas files')
    ap.add_argument('--groups', default=','.join(GROUPS), help='Comma-separated groups to generate, e.g. A1,A2,A3,A4,A5,B,C,D,E')
    ap.add_argument('--scale', type=int, default=2, help='Fixed Godot production scale. Repo policy: 2')
    args = ap.parse_args()

    if args.scale != 2:
        raise ValueError('Repo policy requires fixed scale=2 for A1/A2 Godot-ready outputs.')

    report = build_bridge_outputs(
        source_path=args.chipset,
        output_dir=args.output,
        groups=args.groups.split(',') if args.groups else GROUPS,
        scale=args.scale,
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
