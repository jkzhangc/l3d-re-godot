#!/usr/bin/env python3
"""从 2D 贴图生成法线贴图（normal map），供 Godot 4 的 2D 灯光使用。

为什么需要它
------------
`PointLight2D` 只有在被照对象的**法线贴图**存在、且灯光的 `height > 0` 时才会
产生"表面起伏被光扫过"的效果。没有法线贴图，灯只是一个圆形亮斑，像素块永远正对光。

三种模式
--------
`dome`（默认，适合角色）：
    用 alpha 轮廓做**距离场**，把剪影像一个鼓起来的半球来打光。
    像素小人/敌人用这个最稳：边缘自然收光，脸和身体有体积感，不会破坏原画颜色。

`luma`（适合图块 / 带厚涂阴影的物件）：
    亮度当高度做 Sobel 求法线。墙砖、铁门、地面这些本来就有明暗关系的图块效果好；
    平涂色块的图会得到"描边式"的倒角。

`hybrid`：
    轮廓鼓包 + 亮度细节各占一半。角色既圆又有衣纹。

数据格式（Godot 要求）
----------------------
RGB 存法线向量（x,y 映射到 0~255，z 由推导得到），A 保留原图 alpha。
Godot 的 2D 法线贴图约定：**+X 向右、+Y 向下、+Z 朝屏幕外**，所以 y 分量不翻转。

用法
----
    python tools/gen_normal_maps.py art/Characters/のび太セット.png
    python tools/gen_normal_maps.py art/Tilesets/Inside_A2.png --mode luma --strength 2.5
    python tools/gen_normal_maps.py art/Characters --glob "*.png" --out-dir art/Characters/n

默认输出到源文件同目录，文件名加 `_n` 后缀。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent


def _load_luma(img: Image.Image) -> np.ndarray:
    """亮度 0~1。用 Rec.601，和 Godot 的 CanvasModulate 观感接近。"""
    rgb = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
    return rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114


def _height_from_alpha(img: Image.Image) -> np.ndarray:
    """把剪影当成一个鼓包：反复模糊 alpha 近似"到边缘的距离"。

    没用 scipy 的 distance_transform，是为了少一个依赖；
    15 次 3x3 均值模糊在 64px 的行走图上足够得到平滑的圆顶。
    """
    a = np.asarray(img.convert("RGBA"), dtype=np.float32)[..., 3] / 255.0
    h = a.copy()
    for _ in range(15):
        blurred = Image.fromarray((h * 255).astype(np.uint8), mode="L").filter(ImageFilter.BoxBlur(1))
        h = np.asarray(blurred, dtype=np.float32) / 255.0
    # 归一化到 0~1，边缘 0、内部最高
    hi = float(h.max())
    if hi > 1e-6:
        h = h / hi
    h = h * h * (3.0 - 2.0 * h)  # smoothstep，让顶部更平、边缘更陡
    return h * a


def _height_field(img: Image.Image, mode: str, blur: float) -> np.ndarray:
    if mode == "dome":
        h = _height_from_alpha(img)
    elif mode == "luma":
        h = _load_luma(img)
        if blur > 0:
            h = np.asarray(
                Image.fromarray((h * 255).astype(np.uint8), mode="L").filter(ImageFilter.GaussianBlur(blur)),
                dtype=np.float32,
            ) / 255.0
    elif mode == "hybrid":
        dome = _height_from_alpha(img)
        lum = _load_luma(img)
        if blur > 0:
            lum = np.asarray(
                Image.fromarray((lum * 255).astype(np.uint8), mode="L").filter(ImageFilter.GaussianBlur(blur)),
                dtype=np.float32,
            ) / 255.0
        h = dome * 0.65 + lum * 0.35
    else:
        raise ValueError(f"未知模式: {mode}")
    return h.astype(np.float32)


def to_normal(img: Image.Image, mode: str = "dome", strength: float = 1.6,
              blur: float = 0.0) -> Image.Image:
    h = _height_field(img, mode, blur)
    # Sobel：x 向右、y 向下，与 Godot 2D 法线约定一致
    dx = np.zeros_like(h)
    dy = np.zeros_like(h)
    dx[:, 1:-1] = (h[:, 2:] - h[:, :-2]) * 0.5
    dy[1:-1, :] = (h[2:, :] - h[:-2, :]) * 0.5

    nx = -dx * strength
    ny = -dy * strength
    nz = np.ones_like(h)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx /= length
    ny /= length
    nz /= length

    rgb = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5], axis=-1)
    alpha = np.asarray(img.convert("RGBA"), dtype=np.float32)[..., 3] / 255.0
    out = np.dstack([rgb, alpha])
    return Image.fromarray(np.clip(out * 255.0, 0, 255).astype(np.uint8), mode="RGBA")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("targets", nargs="+", help="图片或目录")
    ap.add_argument("--glob", default="*.png", help="目录模式下匹配的文件名（默认 *.png）")
    ap.add_argument("--mode", default="dome", choices=["dome", "luma", "hybrid"])
    ap.add_argument("--strength", type=float, default=1.6, help="起伏强度，1~3 比较自然")
    ap.add_argument("--blur", type=float, default=0.0, help="高度场预模糊（luma 模式建议 0.6~1.0）")
    ap.add_argument("--suffix", default="_n", help="输出文件名后缀")
    ap.add_argument("--out-dir", default="", help="输出目录（默认与源文件同目录）")
    args = ap.parse_args()

    files: list[Path] = []
    for t in args.targets:
        p = Path(t)
        if not p.is_absolute():
            p = ROOT / p
        if p.is_dir():
            files += sorted(x for x in p.glob(args.glob) if not x.name.endswith(args.suffix + ".png"))
        else:
            files.append(p)

    if not files:
        print("没有匹配到图片")
        return 1

    out_dir = Path(args.out_dir).resolve() if args.out_dir else None

    for f in files:
        try:
            img = Image.open(f)
        except Exception as e:  # noqa: BLE001
            print(f"[跳过] {f.name}: {e}")
            continue
        normal = to_normal(img, args.mode, args.strength, args.blur)
        dst = (out_dir or f.parent) / f"{f.stem}{args.suffix}.png"
        dst.parent.mkdir(parents=True, exist_ok=True)
        normal.save(dst)
        print(f"{f.name} → {dst.name}  ({img.size[0]}x{img.size[1]}, mode={args.mode})")

    print(f"\n完成 {len(files)} 张。Godot 侧导入保持 Lossless 压缩即可；"
          f"\n如果受光偏灰/偏亮，再检查该贴图的 Import 里有没有被套上 sRGB 转换（法线图 RGB 是向量不是颜色）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
