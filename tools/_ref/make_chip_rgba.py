#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把芯片组 PNG/XYZ 解成裸 RGBA，供 run_ref.js 的探针读取。

解码规则与项目一致：palette index 0 → alpha 0（不用颜色容差抠图）。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'rm2k3_map_restore'))

from export_map import decode_xyz  # noqa: E402


def main() -> int:
    if len(sys.argv) < 2:
        print('用法: python make_chip_rgba.py <芯片组.png|.xyz> [输出.rgba]')
        return 2
    source = Path(sys.argv[1])
    target = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent / 'chip.rgba'
    image = decode_xyz(source)
    target.write_bytes(image.tobytes())
    print(f'{source.name} -> {target.name}  {image.size} {len(image.tobytes())} bytes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
