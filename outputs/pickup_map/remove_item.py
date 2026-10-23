# -*- coding: utf-8 -*-
"""把一个物品资源从「掉落池 + 所有地图场景」里彻底摘掉，并删除资源文件。

用法（项目根目录）：
    python outputs/pickup_map/remove_item.py item_pills.tres [item_xxx.tres ...]

做三件事：
1. 删掉指向该资源的 [ext_resource] 行；
2. 从各 DropPoolData 的 `items` 数组里删掉对应元素，并**同步删掉 weights 同一下标**
   （两者按下标对齐，只删一边会让整池权重错位）；
3. 删除 object/<name> 本体（含 .uid）。

⚠ 必须在 Godot 编辑器里**关掉这些场景**再跑：编辑器会把内存里的旧副本存回去，
   把已删掉的 ext_resource 引用重新写回磁盘（2026-10-23 实际踩到过）。
"""
import os
import re
import glob
import sys
import tempfile


def write_atomic(path, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
    os.close(fd)
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text if text.endswith("\n") else text + "\n")
    os.replace(tmp, path)


def strip_array(line, key, remove_ids):
    """从 `key = Array[...]([...])` 里删掉指定 id 的项；返回 (新行, 被删下标集合|None)。"""
    inner = line[line.index("([") + 2: line.rindex("])")]
    toks = [x.strip() for x in inner.split(",") if x.strip()]
    idxs = [i for i, t in enumerate(toks) if any(t == 'ExtResource("%s")' % d for d in remove_ids)]
    if not idxs:
        return line, None
    for i in sorted(idxs, reverse=True):
        toks.pop(i)
    prefix = line[:line.index("([")]          # 例如 `items = Array[Resource]`
    return "%s([%s])" % (prefix, ", ".join(toks)), set(idxs)


def main(argv):
    targets = [os.path.basename(a) for a in argv[1:] if a.endswith(".tres")]
    if not targets:
        print("用法: remove_item.py item_xxx.tres [...]")
        return 1
    files = sorted(glob.glob("scene/**/*.tscn", recursive=True)) + \
        sorted(glob.glob("object/*.tres"))
    for f in files:
        lines = open(f, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
        kill_ids, kill_lines = set(), set()
        for i, l in enumerate(lines):
            if l.startswith("[ext_resource") and any(t in l for t in targets):
                m = re.search(r'(?<!u)\bid="([^"]+)"', l)
                if m:
                    kill_ids.add(m.group(1))
                    kill_lines.add(i)
        if not kill_ids:
            continue
        removed = 0
        for i, l in enumerate(lines):
            if not l.startswith("items = Array[Resource](["):
                continue
            new_line, idxs = strip_array(l, "items", kill_ids)
            if idxs is None:
                continue
            lines[i] = new_line
            removed += len(idxs)
            if i + 1 < len(lines) and lines[i + 1].startswith("weights = Array[float](["):
                wl = lines[i + 1]
                ws = [x.strip() for x in wl[wl.index("([") + 2: wl.rindex("])")].split(",") if x.strip()]
                if len(ws) == len(idxs) + len([x for x in new_line[new_line.index("([") + 2: new_line.rindex("])")].split(",") if x.strip()]):
                    for k in sorted(idxs, reverse=True):
                        ws.pop(k)
                    lines[i + 1] = "weights = Array[float]([%s])" % ", ".join(ws)
                else:
                    print("  !! %s 第%d行 权重长度不匹配，已跳过权重" % (f, i + 1))
        out = [l for i, l in enumerate(lines) if i not in kill_lines]
        text = re.sub(r"\n{3,}", "\n\n", "\n".join(out))
        write_atomic(f, text)
        print("%-52s 摘除条目 %d / 声明 %d" % (f, removed, len(kill_lines)))

    for t in targets:
        p = os.path.join("object", t)
        for x in (p, p + ".uid"):
            if os.path.exists(x):
                os.remove(x)
                print("已删除", x)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
