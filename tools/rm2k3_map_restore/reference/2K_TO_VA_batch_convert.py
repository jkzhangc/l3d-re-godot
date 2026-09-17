#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
RM2K3 Chipset → VX Ace Tileset 批量转换工具 (Python + Pillow)
像素精确，无 GDI+ 偏移问题
"""
from __future__ import print_function
from PIL import Image
import os, sys, glob

CHIPSET_DIR = 'ChipSet'
OUTPUT_DIR  = 'Output'

def detect_bg_key(img):
    """
    检测全图背景色键：chipset 四条边必然是背景色，
    采样四边像素取频率最高的颜色，不会被 tile 内容干扰。
    """
    from collections import Counter
    pixels = img.load()
    w, h = img.size
    samples = []
    # 上边 + 下边
    for x in range(0, w, 2):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, h-1][:3])
    # 左边 + 右边 (跳过四角避免重复)
    for y in range(2, h-2, 2):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[w-1, y][:3])
    return Counter(samples).most_common(1)[0][0]

def make_transparent(img, key, tolerance=80):
    """将图像中匹配色键的像素变透明。"""
    pixels = img.load()
    for y in range(img.height):
        for x in range(img.width):
            px = pixels[x, y]
            dist = abs(px[0] - key[0]) + abs(px[1] - key[1]) + abs(px[2] - key[2])
            if dist <= tolerance:
                pixels[x, y] = (0, 0, 0, 0)
    return img

def convert_chipset(src_path, out_dir, bg_tolerance=80):
    """Convert a single RM2K3 chipset to VX Ace format tilesets."""
    name = os.path.splitext(os.path.basename(src_path))[0]
    src = Image.open(src_path).convert('RGBA')
    w, h = src.size

    # ---- 全图边缘检测背景色键并统一去除 ----
    bg_key = detect_bg_key(src)
    make_transparent(src, bg_key, bg_tolerance)

    # ---- A2: Autotiles (512x384) ----
    a2 = Image.new('RGBA', (512, 384))
    unit_idx = 0
    for row in range(4):
        for col in range(4):
            sx, sy = col * 48, row * 64

            # Extract 6 tiles from the 3x4 autotile unit
            topL = src.crop((sx,      sy,      sx+16, sy+16))   # (0,0)
            topR = src.crop((sx+32,   sy,      sx+48, sy+16))   # (2,0)
            bTL  = src.crop((sx,      sy+16,   sx+16, sy+32))   # (0,1)
            bTR  = src.crop((sx+32,   sy+16,   sx+48, sy+32))   # (2,1)
            bBL  = src.crop((sx,      sy+48,   sx+16, sy+64))   # (0,3)
            bBR  = src.crop((sx+32,   sy+48,   sx+48, sy+64))   # (2,3)

            # Assemble into 32x48
            asm = Image.new('RGBA', (32, 48))
            asm.paste(topL, (0,  0))
            asm.paste(topR, (16, 0))
            asm.paste(bTL,  (0,  16))
            asm.paste(bTR,  (16, 16))
            asm.paste(bBL,  (0,  32))
            asm.paste(bBR,  (16, 32))

            # 2x Nearest Neighbor → 64x96
            vx = asm.resize((64, 96), Image.NEAREST)

            # Place on A2 canvas (8 units per row)
            ox = (unit_idx % 8) * 64
            oy = (unit_idx // 8) * 96
            a2.paste(vx, (ox, oy))
            unit_idx += 1

    a2.save(os.path.join(out_dir, name + '_A2.png'))

    # ---- A5: Lower layer tiles (256x512) ----
    # Source: x=192..288 (96px = 6 tiles@16px), full height
    a5_src = src.crop((192, 0, 288, h))
    a5 = a5_src.resize((192, h * 2), Image.NEAREST)  # 2x scale → 192x512
    # Pad to standard 256x512 canvas
    a5_full = Image.new('RGBA', (256, 512))
    a5_full.paste(a5, (0, 0))
    a5_full.save(os.path.join(out_dir, name + '_A5.png'))

    # ---- B: Upper layer tiles (512x512) ----
    # Source: x=288..w (remaining width), full height
    b_src = src.crop((288, 0, w, h))
    b_w, b_h = b_src.size
    b = b_src.resize((b_w * 2, b_h * 2), Image.NEAREST)  # 2x scale
    # Pad to standard 512x512 canvas
    b_full = Image.new('RGBA', (512, 512))
    b_full.paste(b, (0, 0))
    b_full.save(os.path.join(out_dir, name + '_B.png'))

    return True

def main():
    if not os.path.exists(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)

    files = sorted(glob.glob(os.path.join(CHIPSET_DIR, '*.png')))
    total = len(files)
    ok = 0
    fail = 0

    print('Batch converting {} files (Python+Pillow)...'.format(total))
    print('=' * 50)

    for i, f in enumerate(files, 1):
        name = os.path.basename(f)
        print('[{}/{}] {} ... '.format(i, total, name), end='')
        try:
            convert_chipset(f, OUTPUT_DIR)
            print('OK')
            ok += 1
        except Exception as e:
            print('FAIL: {}'.format(e))
            fail += 1

    print('=' * 50)
    print('Done! Total={}  OK={}  Failed={}'.format(total, ok, fail))
    print('Output: {}'.format(OUTPUT_DIR))

if __name__ == '__main__':
    main()
