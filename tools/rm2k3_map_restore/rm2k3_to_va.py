#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convert an RM2K3 480x256 chipset into VA intermediates and Godot tiles.

The *_VA.png files are inspection/intermediate assets. Godot must consume the
*_godot.png files, whose every cell is a complete 32x32 tile. Autotile groups
are deliberately kept separate and their source mapping is recorded in JSON.
"""
import argparse, json, zlib
from pathlib import Path
from PIL import Image

GROUPS = ('A1', 'A2', 'A3', 'A4', 'A5', 'B', 'C', 'D', 'E')
REGIONS = {
    'A1': (0, 0, 192, 64), 'A2': (0, 64, 192, 128),
    'A3': (0, 128, 192, 192), 'A4': (0, 192, 192, 256),
    'A5': (192, 0, 288, 256), 'B': (288, 0, 480, 128),
    'C': (288, 128, 480, 160), 'D': (0, 0, 192, 256),
    'E': (288, 160, 480, 256),
}

def decode_xyz(path):
    raw = path.read_bytes()
    if raw[:4] == b'XYZ1':
        payload = zlib.decompress(raw[8:])
        if len(payload) != 768 + 480 * 256: raise ValueError('unexpected XYZ payload')
        pixels = payload[768:]
        image = Image.frombytes('P', (480, 256), pixels)
        image.putpalette(payload[:768])
        image = image.convert('RGBA')
        image.putalpha(Image.frombytes('L', image.size, bytes(0 if i == 0 else 255 for i in pixels)))
        return image
    indexed = Image.open(path)
    if indexed.size != (480, 256): raise ValueError('chipset must be 480x256, got %s' % (indexed.size,))
    if indexed.mode == 'P':
        pixels = indexed.copy()
        rgba = pixels.convert('RGBA')
        if pixels.info.get('transparency') is None:
            rgba.putalpha(Image.frombytes('L', pixels.size, bytes(0 if i == 0 else 255 for i in pixels.tobytes())))
        return rgba
    return indexed.convert('RGBA')

def load_chipset(path):
    return decode_xyz(path)

def crop_tiles(image, rect, scale):
    x0, y0, x1, y1 = rect
    src = image.crop(rect)
    return src.resize((src.width * scale, src.height * scale), Image.Resampling.NEAREST)

def godot_atlas(image, rect, scale):
    x0, y0, x1, y1 = rect
    tiles = []
    for y in range(y0 // 16, y1 // 16):
        for x in range(x0 // 16, x1 // 16):
            tiles.append(image.crop((x * 16, y * 16, x * 16 + 16, y * 16 + 16)).resize((32, 32), Image.Resampling.NEAREST))
    cols = max(1, min(16, (x1 - x0) // 16))
    rows = max(1, (len(tiles) + cols - 1) // cols)
    atlas = Image.new('RGBA', (cols * 32, rows * 32))
    for i, tile in enumerate(tiles): atlas.alpha_composite(tile, ((i % cols) * 32, (i // cols) * 32))
    return atlas, cols, rows

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('chipset')
    ap.add_argument('--output', required=True)
    ap.add_argument('--groups', default=','.join(GROUPS))
    ap.add_argument('--scale', type=int, default=2)
    ap.add_argument('--frames', type=int, default=3)
    ap.add_argument('--frame-duration', type=float, default=0.3)
    args = ap.parse_args()
    source_path, out = Path(args.chipset), Path(args.output); out.mkdir(parents=True, exist_ok=True)
    image = load_chipset(source_path); selected = [x.strip().upper() for x in args.groups.split(',') if x.strip()]
    mapping = {'source': {'file': str(source_path), 'format': source_path.suffix.lower().lstrip('.'), 'size': [480, 256], 'tile_size': 16}, 'groups': {}, 'warnings': []}
    stem = source_path.stem
    for group in selected:
        if group not in REGIONS: mapping['warnings'].append('unknown group: '+group); continue
        rect = REGIONS[group]; va = crop_tiles(image, rect, args.scale); godot, cols, rows = godot_atlas(image, rect, args.scale)
        va_name, godot_name = f'{stem}_{group}_VA.png', f'{stem}_{group}_godot.png'
        va.save(out / va_name); godot.save(out / godot_name)
        entries = []
        for i in range((rect[2]-rect[0])//16 * (rect[3]-rect[1])//16):
            entries.append({'source_tile_index': i, 'godot_coord': [i % cols, i // cols]})
        info = {'va_atlas': va_name, 'godot_atlas': godot_name, 'source_rect': list(rect), 'godot_tile_size': 32, 'godot_columns': cols, 'godot_rows': rows, 'entries': entries}
        if group in ('A1', 'A2', 'A3', 'A4', 'D', 'E'):
            info['needs_calibration'] = True
            info['animation'] = {'frames': args.frames, 'frame_duration': args.frame_duration, 'layout': 'horizontal-after-semantic-calibration'}
            mapping['warnings'].append('%s output is structural; RM2K3 semantic/autotile calibration is required' % group)
        mapping['groups'][group] = info
    mapping_path = out / f'{stem}_mapping.json'; report_path = out / f'{stem}_report.json'
    mapping_path.write_text(json.dumps(mapping, ensure_ascii=False, indent=2), encoding='utf-8')
    report = {'chipset': str(source_path), 'requested_groups': selected, 'generated_groups': list(mapping['groups']), 'warnings': mapping['warnings'], 'godot_rule': 'Use *_godot.png only; *_VA.png is an intermediate for inspection.'}
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('generated groups:', ', '.join(mapping['groups']))
    print('mapping:', mapping_path); print('report:', report_path)

if __name__ == '__main__': main()
