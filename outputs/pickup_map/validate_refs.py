# -*- coding: utf-8 -*-
"""文本级校验：.tscn/.tres 里是否有悬垂 ExtResource/SubResource 引用、
掉落池 items 与 weights 长度是否一致。
不需要 Godot，--script 模式下没法加载带 autoload 的脚本，所以用这个兜底。
"""
import re
import glob


def main():
    files = sorted(glob.glob("scene/**/*.tscn", recursive=True) + glob.glob("object/*.tres"))
    bad = 0
    for f in files:
        txt = open(f, encoding="utf-8").read()
        decl = set()
        for l in txt.splitlines():
            if l.startswith("[ext_resource") or l.startswith("[sub_resource"):
                for m in re.finditer(r'(?<!u)\bid="([^"]+)"', l):
                    decl.add(m.group(1))
        used = set(re.findall(r'ExtResource\("([^"]+)"\)', txt)) | \
            set(re.findall(r'SubResource\("([^"]+)"\)', txt))
        miss = used - decl
        if miss:
            bad += 1
            print("!! %s 悬垂引用: %s" % (f, sorted(miss)))
        lines = txt.splitlines()
        for i, l in enumerate(lines):
            if l.startswith("items = Array[Resource]([") and i + 1 < len(lines) \
                    and lines[i + 1].startswith("weights = Array[float](["):
                it = [x for x in l[l.index("([") + 2:l.rindex("])")].split(",") if x.strip()]
                wl = lines[i + 1]
                wt = [x for x in wl[wl.index("([") + 2:wl.rindex("])")].split(",") if x.strip()]
                if len(it) != len(wt):
                    bad += 1
                    print("!! %s 第%d行 items=%d weights=%d" % (f, i + 1, len(it), len(wt)))
                if not it:
                    bad += 1
                    print("!! %s 第%d行 空掉落池" % (f, i + 1))
    print("检查 %d 个文件，问题 %d" % (len(files), bad))


if __name__ == "__main__":
    main()
