# -*- coding: utf-8 -*-
"""发布打包：导出 Windows 版 → 压成 zip（并报告体积）。

## 为什么需要它（2026-10-03 体积调研结论）
Godot 的 PCK 是**原样存储**的，不像 APK 那样本身就是 zip。所以同样一份游戏：
    exe 207.5 MB ／ apk 91.7 MB  ← 差距几乎全来自"APK 会 deflate"
实测把 exe 用 zip(deflate) 压一遍：**207.5 → 98.8 MB（48%）**，10 秒完成。
结论：**PC 端不需要任何引擎层面的改动，只要分发时给压缩包**即可（Steam / itch.io 的标准做法）。
本脚本把这个动作固定下来，避免"忘了压、直接把 200MB 原始 exe 传上去"。

## 用法
    python tools/package_release.py            # 导出 + 压缩
    python tools/package_release.py --no-export  # 只压缩（复用上一次导出的 exe）

## 产物
    release/l3dre_v<版本>.exe        ← 原始可执行（解压即玩）
    release/l3dre_v<版本>_win.zip    ← **用于分发/上传**的压缩包

## ⚠ 注意
- 导出前**必须关闭 Godot 编辑器**：编辑器会在退出/导出时把内存里的
  `export_presets.cfg` 写回磁盘，覆盖掉对导出配置的修改。
- 版本号从 `project.godot` 的 `config/version` 读，与 `title_screen.gd` 的
  `CHANGELOG_VERSION_TEXT` 必须同步（MEMORY 铁律）。
"""

import os
import re
import subprocess
import sys
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE_DIR = os.path.join(ROOT, "release")
GODOT = r"D:/Godot_v4.6.3-stable_win64.exe/Godot_v4.6.3-stable_win64_console.exe"
PRESET_NAME = "Windows Desktop"
# zip 压缩级别：6 = 速度/体积的平衡点（实测与 9 级差不到 1 MB，但快一倍）
ZIP_LEVEL = 6


def read_version() -> str:
    """从 project.godot 读 config/version（如 "0.32"）。"""
    path = os.path.join(ROOT, "project.godot")
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^config/version="([^"]+)"', line.strip())
            if m:
                return m.group(1)
    raise SystemExit("！读不到 project.godot 的 config/version")


def human(n: int) -> str:
    return "%.1f MB" % (n / 1048576.0)


def do_export() -> str:
    """调 Godot 导出；返回 exe 路径。导出路径由 export_presets.cfg 的 export_path 决定。"""
    print("[1/3] 导出 Windows 版 …")
    t0 = time.time()
    proc = subprocess.run(
        [GODOT, "--headless", "--path", ROOT, "--export-release", PRESET_NAME],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        print(out[-2000:])
        raise SystemExit("！导出失败（退出码 %d）" % proc.returncode)
    # 从预设里读实际导出路径，避免脚本与配置各写一份版本号
    preset_path = os.path.join(ROOT, "export_presets.cfg")
    exe_rel = None
    with open(preset_path, "r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^export_path="([^"]+)"', line.strip())
            if m:
                exe_rel = m.group(1)
                break
    if not exe_rel:
        raise SystemExit("！export_presets.cfg 里读不到 export_path")
    exe = os.path.join(ROOT, exe_rel)
    if not os.path.isfile(exe):
        raise SystemExit("！导出完成但找不到产物：%s" % exe)
    print("      完成，用时 %.0fs → %s (%s)" % (time.time() - t0, exe_rel, human(os.path.getsize(exe))))
    return exe


def do_zip(exe: str) -> str:
    """把 exe 压成 zip；返回 zip 路径。"""
    print("[2/3] 压缩 …")
    t0 = time.time()
    base = os.path.splitext(os.path.basename(exe))[0]
    zip_path = os.path.join(RELEASE_DIR, base + "_win.zip")
    src = os.path.getsize(exe)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=ZIP_LEVEL) as z:
        z.write(exe, os.path.basename(exe))
        # 一并带上操作说明（玩家解压后能直接看到；也是 controls_guide 读的那份）
        guide = os.path.join(ROOT, "操作说明.txt")
        if os.path.isfile(guide):
            z.write(guide, "操作说明.txt")
    dst = os.path.getsize(zip_path)
    print("      完成，用时 %.0fs → %s (%s，压缩率 %.0f%%，省 %s)"
          % (time.time() - t0, os.path.basename(zip_path), human(dst),
             100.0 * dst / max(1, src), human(src - dst)))
    return zip_path


def main() -> None:
    version = read_version()
    print("== L3D 发布打包 ==  版本 v%s\n" % version)
    no_export = "--no-export" in sys.argv
    if no_export:
        exe_rel = None
        with open(os.path.join(ROOT, "export_presets.cfg"), "r", encoding="utf-8") as f:
            for line in f:
                m = re.match(r'^export_path="([^"]+)"', line.strip())
                if m:
                    exe_rel = m.group(1)
                    break
        exe = os.path.join(ROOT, exe_rel)
        if not os.path.isfile(exe):
            raise SystemExit("！--no-export 但 exe 不存在：%s" % exe_rel)
        print("[1/3] 跳过导出（--no-export），复用 %s" % exe_rel)
    else:
        exe = do_export()
    zip_path = do_zip(exe)
    print("\n[3/3] 分发用文件：%s" % os.path.relpath(zip_path, ROOT))
    print("      把它上传到 itch.io / 网盘即可；玩家解压后运行同名 exe。")


if __name__ == "__main__":
    main()
