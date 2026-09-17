#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RM2K3 芯片组 → Godot 完整瓦片 atlas 的贴图合成器。

1:1 移植自 くらむぼん（krmbn0576）的网页转换器
（https://krmbn0576.github.io/rpgmakermv/converter.html）中 convertChipset() 的
合成部分，仅保留「图形装配」语义，去掉 HTML 交互。

移植要点
--------
原实现用 CanvasRenderingContext2D.putImageData(imageData, dx, dy, dirtyX,
dirtyY, dirtyW, dirtyH)：从**固定的源 imageData** 取一块 dirty 矩形，**覆盖式**
（非 alpha 混合）写入目标画布。所有坐标以「瓦片」为单位、允许 0.5 粒度；因为
源瓦片边长 16px，(n + 0.5) * 16 恒为整数，所以半格本质就是 8px 对齐。

⚠ 已修正原实现的坐标缺陷（2026-09-11 实证）
------------------------------------------
原代码写作 `putImageData(imageData, (dx - sx) * tileSize, ...)`，即把源瓦片
(sx, sy) 写到画布 (dx - sx, dy - sy)。该表达式在绝大多数调用点算出**负坐标**，
写入随即被画布裁掉：用 Node + 规范精确 putImageData 垫片运行原始 JS，
输出为空（A5/B 整张全空，A1 仅余 4 列细条）。

正确语义是 **目标 = (dx, dy)、源 = (sx, sy)**。此结论由原站文档内嵌的四张
golden 样例图独立印证：
  - A5 样例 8×16 全格有内容        ← 对应 put_rect 的 (0,0)6×16 / (6,0)2×8 / (6,8)2×8
  - B  样例仅 col 0–5 与 8–13      ← 对应四段 6×8 落点
  - A1 样例 col 0–5 + col 14–15    ← 对应水体三带与瀑布两列
  - D  样例 row 0–5 / 8–13 各 16 列 ← 对应四个 8×6 全图案块的 2×2 摆位
因此本模块按 golden 语义实现，而非照抄已回归的表达式。

与 MV 原生 A1/A2 的区别（为什么需要本模块）
------------------------------------------
MV 的 A1/A2/A3/A4 是**复合格式**：一个自动图块存成 2×3 或 3×4 个小碎片，由
MV 运行时拼装。Godot 的 TileSetAtlasSource 只能消费**每格都完整**的瓦片图，
因此本项目只采用该转换器的「附加素材 / おまけ」输出形态：
    put_all_auto_tile() → 单个自动图块展开成 48 个完整瓦片，8 列 × 6 行
这 48 格即 3×3 邻接位掩码的全部有效组合，可直接对应 Godot TileSet Terrain。
"""

from __future__ import annotations

from PIL import Image

SRC_TILE = 16          # RM2K3 源瓦片边长
PATTERN_COLS = 8       # 单个自动图块展开后的列数
PATTERN_ROWS = 6       # 单个自动图块展开后的行数（8×6 = 48 个完整瓦片）


def _hu(v: float) -> int:
    """瓦片坐标 → 半格整数单位。"""
    return int(round(v * 2))


class Compositor:
    """按参考转换器语义把源芯片组装配成目标画布。

    源图固定为整张芯片组（可带放大），目标画布逐个按需创建；
    所有 put_* 方法从 self.src 取值、以覆盖方式写入目标。
    """

    def __init__(self, source: Image.Image, scale: int = 2):
        if scale not in (1, 2, 3):
            raise ValueError('scale must be 1, 2 or 3 (mirrors the reference converter)')
        self.scale = scale
        self.tile = SRC_TILE * scale
        self.src = source if scale == 1 else source.resize(
            (source.width * scale, source.height * scale), Image.Resampling.NEAREST)

    # ── 目标画布 ────────────────────────────────────────────────
    def canvas(self, cols: int, rows: int) -> Image.Image:
        return Image.new('RGBA', (cols * self.tile, rows * self.tile), (0, 0, 0, 0))

    # ── 合成原语（对应 putFullTile / putHalfTile / putRectangle）──
    def put(self, dst: Image.Image, dx: float, dy: float,
            sx: float, sy: float, sw: float, sh: float) -> None:
        """把源图从 (sx, sy) 起的 sw×sh 瓦片块覆盖写到目标 (dx, dy)。

        目标坐标即 (dx, dy)（见模块头「已修正原实现的坐标缺陷」）。
        """
        dest_x = _hu(dx) * self.tile // 2
        dest_y = _hu(dy) * self.tile // 2
        src_x = _hu(sx) * self.tile // 2
        src_y = _hu(sy) * self.tile // 2
        w = _hu(sw) * self.tile // 2
        h = _hu(sh) * self.tile // 2
        if w <= 0 or h <= 0:
            return
        block = self.src.crop((src_x, src_y, src_x + w, src_y + h))
        # paste 为覆盖写（含 alpha），与 putImageData 语义一致；越界自动裁剪
        dst.paste(block, (dest_x, dest_y))

    def put_full(self, dst, dx, dy, sx, sy) -> None:
        self.put(dst, dx, dy, sx, sy, 1, 1)

    def put_half(self, dst, dx, dy, sx, sy) -> None:
        self.put(dst, dx, dy, sx, sy, 0.5, 0.5)

    def put_rect(self, dst, dx, dy, sx, sy, sw, sh) -> None:
        self.put(dst, dx, dy, sx, sy, sw, sh)

    # ── 自动图块装配 ────────────────────────────────────────────
    def put_circle(self, dst, dx, dy, sx, sy) -> None:
        """原 putCircle：四块半格拼出「孤立/内凹」图案。"""
        self.put_half(dst, dx + 0.5, dy + 0.5, sx + 2.5, sy + 0.5)
        self.put_half(dst, dx + 1, dy + 0.5, sx + 2, sy + 0.5)
        self.put_half(dst, dx + 0.5, dy + 1, sx + 2.5, sy + 0)
        self.put_half(dst, dx + 1, dy + 1, sx + 2, sy + 0)

    def put_auto_tile(self, dst, dx, dy, sx, sy) -> None:
        """原 putAutoTile：MV A2 的 6 格「角优先」装配（2 列 × 3 行）。"""
        self.put_full(dst, dx + 0, dy + 0, sx + 0, sy + 0)
        self.put_full(dst, dx + 1, dy + 0, sx + 2, sy + 0)
        self.put_full(dst, dx + 0, dy + 1, sx + 0, sy + 1)
        self.put_full(dst, dx + 1, dy + 1, sx + 2, sy + 1)
        self.put_full(dst, dx + 0, dy + 2, sx + 0, sy + 3)
        self.put_full(dst, dx + 1, dy + 2, sx + 2, sy + 3)

    def put_all_auto_tile(self, dst, dx, dy, sx, sy) -> None:
        """原 putAllAutoTile：把单个自动图块展开为 48 个完整瓦片（8×6）。

        Godot 可直接把该 8×6 区块做成 TileSetAtlasSource，每格都是完整瓦片。
        左上 3×4（u0..2, v0..3）保留源块原样，其余为装配出的邻接图案。
        """
        # 左上 3×4：源自动图块原样
        self.put_rect(dst, dx + 0, dy + 0, sx + 0, sy + 0, 3, 4)
        # 上边 / 下边（跨 2 格的贴边）
        self.put_half(dst, dx + 1, dy + 0, sx + 0, sy + 1)
        self.put_half(dst, dx + 1.5, dy + 0, sx + 2.5, sy + 1)
        self.put_half(dst, dx + 1, dy + 0.5, sx + 0, sy + 3.5)
        self.put_half(dst, dx + 1.5, dy + 0.5, sx + 2.5, sy + 3.5)
        # 中央填满
        self.put_full(dst, dx + 0, dy + 4, sx + 1, sy + 2)
        self.put_full(dst, dx + 1, dy + 4, sx + 1, sy + 2)
        self.put_full(dst, dx + 2, dy + 4, sx + 1, sy + 2)
        self.put_full(dst, dx + 0, dy + 5, sx + 1, sy + 2)
        self.put_full(dst, dx + 1, dy + 5, sx + 1, sy + 2)
        self.put_full(dst, dx + 2, dy + 5, sx + 1, sy + 2)
        # 左上/左下内角
        self.put_half(dst, dx + 0, dy + 4.5, sx + 2, sy + 0.5)
        self.put_half(dst, dx + 0, dy + 5, sx + 2, sy + 0)
        self.put_half(dst, dx + 0.5, dy + 4.5, sx + 2.5, sy + 0.5)
        self.put_half(dst, dx + 0.5, dy + 5, sx + 2.5, sy + 0)
        self.put_half(dst, dx + 1.5, dy + 4, sx + 2.5, sy + 0)
        self.put_half(dst, dx + 1.5, dy + 4.5, sx + 2.5, sy + 0.5)
        self.put_half(dst, dx + 2, dy + 4, sx + 2, sy + 0)
        self.put_half(dst, dx + 2, dy + 4.5, sx + 2, sy + 0.5)
        self.put_half(dst, dx + 1, dy + 5.5, sx + 2, sy + 0.5)
        self.put_half(dst, dx + 1.5, dy + 5, sx + 2.5, sy + 0)
        self.put_half(dst, dx + 2, dy + 5, sx + 2, sy + 0)
        self.put_half(dst, dx + 2.5, dy + 5.5, sx + 2.5, sy + 0.5)
        # 右上区块
        self.put_full(dst, dx + 3, dy + 0, sx + 1, sy + 2)
        self.put_full(dst, dx + 4, dy + 0, sx + 1, sy + 2)
        self.put_full(dst, dx + 3, dy + 1, sx + 1, sy + 2)
        self.put_full(dst, dx + 4, dy + 1, sx + 1, sy + 2)
        self.put_circle(dst, dx + 3, dy + 0, sx, sy)
        self.put_full(dst, dx + 3, dy + 2, sx + 2, sy + 0)
        self.put_full(dst, dx + 4, dy + 2, sx + 2, sy + 0)
        self.put_full(dst, dx + 3, dy + 3, sx + 2, sy + 0)
        self.put_full(dst, dx + 4, dy + 3, sx + 2, sy + 0)
        self.put_half(dst, dx + 3, dy + 2, sx + 1, sy + 2)
        self.put_half(dst, dx + 4.5, dy + 2, sx + 1.5, sy + 2)
        self.put_half(dst, dx + 3, dy + 3.5, sx + 1, sy + 2.5)
        self.put_half(dst, dx + 4.5, dy + 3.5, sx + 1.5, sy + 2.5)
        self.put_full(dst, dx + 3, dy + 4, sx + 0, sy + 1)
        self.put_full(dst, dx + 4, dy + 4, sx + 2, sy + 1)
        self.put_full(dst, dx + 3, dy + 5, sx + 0, sy + 3)
        self.put_full(dst, dx + 4, dy + 5, sx + 2, sy + 3)
        self.put_circle(dst, dx + 3, dy + 4, sx, sy)
        # 右边缘两列
        self.put_rect(dst, dx + 5, dy + 0, sx + 0, sy + 1, 0.5, 3)
        self.put_rect(dst, dx + 5.5, dy + 0, sx + 2.5, sy + 1, 0.5, 3)
        self.put_full(dst, dx + 6, dy + 0, sx + 0, sy + 2)
        self.put_full(dst, dx + 6, dy + 1, sx + 0, sy + 2)
        self.put_full(dst, dx + 6, dy + 2, sx + 0, sy + 2)
        self.put_full(dst, dx + 7, dy + 0, sx + 2, sy + 2)
        self.put_full(dst, dx + 7, dy + 1, sx + 2, sy + 2)
        self.put_full(dst, dx + 7, dy + 2, sx + 2, sy + 2)
        self.put_circle(dst, dx + 6, dy + 0, sx, sy)
        self.put_circle(dst, dx + 6, dy + 1, sx, sy)
        # 右下角
        self.put_rect(dst, dx + 5, dy + 3, sx + 0, sy + 1, 3, 0.5)
        self.put_rect(dst, dx + 5, dy + 3.5, sx + 0, sy + 3.5, 3, 0.5)
        self.put_full(dst, dx + 5, dy + 4, sx + 1, sy + 1)
        self.put_full(dst, dx + 6, dy + 4, sx + 1, sy + 1)
        self.put_full(dst, dx + 7, dy + 4, sx + 1, sy + 1)
        self.put_full(dst, dx + 5, dy + 5, sx + 1, sy + 3)
        self.put_full(dst, dx + 6, dy + 5, sx + 1, sy + 3)
        self.put_full(dst, dx + 7, dy + 5, sx + 1, sy + 3)
        self.put_circle(dst, dx + 5, dy + 4, sx, sy)
        self.put_circle(dst, dx + 6, dy + 4, sx, sy)
