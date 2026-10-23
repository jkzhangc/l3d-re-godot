# -*- coding: utf-8 -*-
"""把 art/WeaponAttack/<族>/ 的单帧图拼成「4 方向 × 3 帧」的图集。

布局（与项目角色表行序一致，`FaceDir`: 下=0 / 左=1 / 右=2 / 上=3）：

        col0 前摇(举起)   col1 挥动(带残影)   col2 后摇
row0 下
row1 左
row2 右
row3 上

帧号 → 方向的对应（源素材约定）：
    01→上 02→右 03→下 04→左        （举起）
    05→上 06→右 07→下 08→左        （挥动）
    05B..08B                        （同位置去残影 = 后摇）
    09..16 / 13B..16B               （第二段连招，另出一张图集）

输出：
    art/WeaponAttack/<族>/<族>_attack1.png   第一段
    art/WeaponAttack/<族>/<族>_attack2.png   第二段（仅 16 帧族）
    art/WeaponAttack/_sheets_report.txt
"""
import os
import re

from PIL import Image

ROOT = "art/WeaponAttack"
FULL = "０１２３４５６７８９"
## 帧块（源编号）→ 方向。方向名仅用于报告。
BLOCKS = {
    "A1": ([1, 2, 3, 4], "前摇"),
    "A2": ([5, 6, 7, 8], "挥动"),
    "A3": ([5, 6, 7, 8], "后摇"),      # 后缀 B
    "B1": ([9, 10, 11, 12], "前摇"),
    "B2": ([13, 14, 15, 16], "挥动"),
    "B3": ([13, 14, 15, 16], "后摇"),  # 后缀 B
}
## 方向顺序：源素材 01/02/03/04 → 上/右/下/左（2026-10-23 用户定稿）
SRC_DIRS = ["上", "右", "下", "左"]
## 图集行序（= FaceDir）
ROW_DIRS = ["下", "左", "右", "上"]


def fw(n: int) -> str:
    return "".join(chr(0xFF10 + int(c)) for c in "%02d" % n)


def find_frame(index: dict, num: int, suffix: str = "") -> Image.Image | None:
    """在图族索引里找 `族+全角两位数(+后缀)`，suffix 兼容半角/全角 B。"""
    for suf in ([suffix, suffix.replace("B", "Ｂ")] if suffix else [""]):
        p = index.get(fw(num) + suf)
        if p:
            return Image.open(p).convert("RGBA")
    return None


def build(fam: str, files: list[str]) -> list[tuple[str, dict]]:
    """返回 [(输出名, {block: {dir: 图}})]。"""
    index = {}
    for f in files:
        stem = os.path.splitext(f)[0]
        index[stem[len(fam):]] = os.path.join(ROOT, fam, f)

    def has(num: int, suffix: str = "") -> bool:
        return any((fw(num) + s) in index for s in ([suffix, suffix.replace("B", "Ｂ")]
                                                    if suffix else [""]))

    out = []
    for tag, blocks in (("attack1", ("A1", "A2", "A3")), ("attack2", ("B1", "B2", "B3"))):
        if tag == "attack2" and not (has(9) and has(13)):
            continue
        cells = {}
        for b in blocks:
            nums, _label = BLOCKS[b]
            suffix = "B" if b == "A3" else ("B" if b == "B3" else "")
            per_dir = {}
            for i, dirname in enumerate(SRC_DIRS):
                img = find_frame(index, nums[i], suffix)
                if img is None and suffix:          # 没有去残影版 → 退回带残影那帧
                    img = find_frame(index, nums[i], "")
                if img is not None:
                    per_dir[dirname] = img
            if per_dir:
                cells[b] = per_dir
        if cells:
            out.append((tag, cells))
    return out


def render(fam: str, tag: str, cells: dict) -> tuple[str, list[str]]:
    notes = []
    cw = max(i.width for d in cells.values() for i in d.values())
    ch = max(i.height for d in cells.values() for i in d.values())
    cols = ["A1", "A2", "A3"] if tag == "attack1" else ["B1", "B2", "B3"]
    sheet = Image.new("RGBA", (cw * len(cols), ch * len(ROW_DIRS)), (0, 0, 0, 0))
    for ci, b in enumerate(cols):
        if b not in cells:
            notes.append("缺 %s" % b)
            continue
        for di, dirname in enumerate(ROW_DIRS):
            img = cells[b].get(dirname)
            if img is None:
                notes.append("缺 %s/%s" % (b, dirname))
                continue
            x = ci * cw + (cw - img.width) // 2
            y = di * ch + (ch - img.height) // 2
            sheet.alpha_composite(img, (x, y))
    path = os.path.join(ROOT, fam, "%s_%s.png" % (fam, tag))
    sheet.save(path)
    return path, notes


def main() -> None:
    fams = sorted(f for f in os.listdir(ROOT)
                  if os.path.isdir(os.path.join(ROOT, f)))
    lines = ["# 武器攻击图集生成报告", "", "布局：3 列（前摇/挥动/后摇）× 4 行（下/左/右/上）", ""]
    made = 0
    for fam in fams:
        files = [f for f in os.listdir(os.path.join(ROOT, fam))
                 if f.endswith(".png") and "_attack" not in f]
        if not files:
            continue
        for tag, cells in build(fam, files):
            path, notes = render(fam, tag, cells)
            made += 1
            line = "- %s  (%dx%d)" % (path, Image.open(path).width, Image.open(path).height)
            if notes:
                line += "  缺失：" + "、".join(notes)
            lines.append(line)
    lines.insert(1, "共 %d 张" % made)
    open(os.path.join(ROOT, "_sheets_report.txt"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("生成 %d 张图集" % made)
    for l in lines[3:8]:
        print(l)


if __name__ == "__main__":
    main()
