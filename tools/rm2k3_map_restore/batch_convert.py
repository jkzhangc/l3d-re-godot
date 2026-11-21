#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RM2K3 地图批量转换：把 convert_map.bat 包装成可一次导出多张地图的工具。

用法:
    python batch_convert.py                      # 交互式输入地图 ID
    python batch_convert.py 30 31 35-37          # 直接指定多张
    python batch_convert.py 30:20x25 31          # 单图显式宽高
    python batch_convert.py 30-35 --rebuild      # 丢弃编辑器改动，重建 TileSet

地图 ID 写法（空格 / 逗号 / 分号分隔均可混用）:
    30            单张
    30,31,32      多张
    30-35         连续区间（含两端）
    30:20x25      该图显式指定宽高，只在 LMU 缺尺寸且无法反推时需要

每张地图仍然走 convert_map.bat 的三步（自动图块图集 -> LMU 导出 -> 生成场景），
单张失败不会中断其余地图，最后打印汇总表并以非零码退出。
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
BAT = HERE / "convert_map.bat"
DEFAULT_GAME_DIR = Path(r"E:\15.L3D")
DEFAULT_GODOT_DIR = HERE.parent.parent
DEFAULT_OUT_DIR = DEFAULT_GODOT_DIR / "art" / "Tilesets" / "rm2k3_auto"
LOG_ROOT = HERE / "_batch_logs"

ID_RE = re.compile(r"^(\d+)(?::(\d+)x(\d+))?$", re.I)
RANGE_RE = re.compile(r"^(\d+)-(\d+)$")
SEP = 56  # 分隔线宽度：避开 60/80 列终端"恰好满行"时的回绕错位

# convert_map.bat 会 chcp 65001 改掉控制台代码页，父进程若沿用启动时的本地编码，
# 子进程跑完后打印的中文会变成乱码；统一固定为 UTF-8（真实控制台走 WriteConsoleW，
# 不受影响；管道/重定向则保证与子进程输出同编码）。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def parse_map_spec(text):
    """解析用户输入 -> [(map_id, (w, h) | None)]，保持顺序并按 ID 去重。"""
    seen = {}
    order = []
    for raw in re.split(r"[,;\s]+", text.strip()):
        if not raw:
            continue
        rm = RANGE_RE.match(raw)
        if rm:
            lo, hi = int(rm.group(1)), int(rm.group(2))
            if lo > hi:
                lo, hi = hi, lo
            for mid in range(lo, hi + 1):
                if mid not in seen:
                    seen[mid] = None
                    order.append(mid)
            continue
        m = ID_RE.match(raw)
        if not m:
            raise ValueError("无法识别的写法 %r（示例：30 / 30,31 / 30-35 / 30:20x25）" % raw)
        mid = int(m.group(1))
        if not 1 <= mid <= 9999:
            raise ValueError("地图 ID 越界：%d（RM2K3 有效范围 1..9999）" % mid)
        dims = (int(m.group(2)), int(m.group(3))) if m.group(2) else None
        if dims and (dims[0] <= 0 or dims[1] <= 0):
            raise ValueError("宽高必须为正数：%r" % raw)
        # 同一张图出现多次时，保留先出现的顺序，但允许后来的写法补上宽高
        if mid in seen and dims and not seen[mid]:
            seen[mid] = dims
            continue
        if mid in seen:
            continue
        seen[mid] = dims
        order.append(mid)
    return [(mid, seen[mid]) for mid in order]


def resolve_python():
    """挑一个装了 Pillow 的解释器交给 convert_map.bat（环境变量 RM2K3_PY）。

    不能直接沿用 PATH 上的 python：不同启动方式（cmd / PowerShell / IDE / 内置
    运行时）指向的解释器可能没装 Pillow，三个 Python 步骤会在第一步就失败。
    逐个探测，全部失败返回 None，让 bat 退回自己的 `python`。
    """
    candidates = []
    env_py = os.environ.get("RM2K3_PY")
    if env_py:
        candidates.append(env_py)
    candidates.append(sys.executable)
    for name in ("python", "python3", "py"):
        found = shutil.which(name)
        if found and found not in candidates:
            candidates.append(found)
    for cand in candidates:
        try:
            probe = subprocess.run([cand, "-c", "import PIL"], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=20)
            if probe.returncode == 0:
                return cand
        except (OSError, subprocess.SubprocessError):
            continue
    return None


def build_command(bat, game_dir, godot_dir, out_dir, map_id, dims, rebuild):
    """拼出 cmd 调用；用 call 前缀避免 cmd /c 对首段引号的特殊解析。"""
    args = [str(bat), str(game_dir), str(map_id), str(godot_dir), str(out_dir)]
    if dims:
        args += [str(dims[0]), str(dims[1])]
    elif rebuild:
        # 第 5/6 位占位，才能让第 7 位的 rebuild 落在正确位置
        args += ["", ""]
    if rebuild:
        args.append("rebuild")
    return ["cmd", "/c", "call"] + args


def run_one(cmd, log_path, py_exe=None):
    """执行一次转换，实时回显并写日志；返回 (returncode, 秒)。"""
    env = os.environ.copy()
    # bat 会把子进程输出接到管道，强制 UTF-8 才能和 Godot 的输出用同一套解码
    env["PYTHONIOENCODING"] = "utf-8"
    if py_exe:
        env["RM2K3_PY"] = py_exe
    start = time.perf_counter()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1, env=env)
        assert proc.stdout is not None
        for line in proc.stdout:
            print(line, end="")
            log.write(line)
        rc = proc.wait()
    return rc, time.perf_counter() - start


def prompt_map_ids():
    """交互式读取地图 ID，返回 [(id, dims)]；空输入返回 None 表示退出。"""
    print("输入地图 ID（可多张），例如：")
    print("  30            单张")
    print("  30,31,32      多张")
    print("  30-35         连续区间")
    print("  30:20x25      显式宽高（LMU 缺尺寸且无法反推时）")
    print("直接回车退出。")
    while True:
        try:
            line = input("地图 ID: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return None
        if not line:
            return None
        if line.lower() in ("q", "quit", "exit"):
            return None
        try:
            parsed = parse_map_spec(line)
        except ValueError as exc:
            print("! %s" % exc)
            continue
        if parsed:
            return parsed


def pad(text, width):
    """按终端显示宽度补空格（中文占 2 列），用于汇总表对齐。"""
    shown = sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)
    return text + " " * max(1, width - shown)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="批量调用 convert_map.bat 导出 RM2K3 地图",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  python batch_convert.py\n"
               "  python batch_convert.py 30 31 35-37\n"
               "  python batch_convert.py 30:20x25 --rebuild\n")
    ap.add_argument("map_ids", nargs="*", help="地图 ID：30 / 30,31 / 30-35 / 30:20x25")
    ap.add_argument("--game-dir", default=str(DEFAULT_GAME_DIR), help="RM2K3 工程目录")
    ap.add_argument("--godot-dir", default=str(DEFAULT_GODOT_DIR), help="Godot 工程根目录")
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR), help="atlas/JSON 输出目录")
    ap.add_argument("--rebuild", action="store_true",
                    help="传给 convert_map.bat 的第 7 个参数：丢弃编辑器改动重建 TileSet")
    ap.add_argument("--stop-on-error", action="store_true", help="任一地图失败即停止")
    ap.add_argument("--dry-run", action="store_true", help="只打印将要执行的命令")
    ap.add_argument("--yes", "-y", action="store_true", help="交互模式下跳过确认")
    args = ap.parse_args(argv)

    bat = BAT
    game_dir = Path(args.game_dir).expanduser().resolve()
    godot_dir = Path(args.godot_dir).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser().resolve()

    for path, label in ((bat, "convert_map.bat"), (game_dir, "源工程目录"), (godot_dir, "Godot 工程目录")):
        if not path.exists():
            print("[FATAL] %s 不存在: %s" % (label, path))
            return 2

    py_exe = None if args.dry_run else resolve_python()
    print("=" * SEP)
    print(" RM2K3 地图批量转换")
    print("   源工程: %s" % game_dir)
    print("   Godot : %s" % godot_dir)
    print("   输出  : %s" % out_dir)
    if args.rebuild:
        print("   模式  : rebuild（重建 TileSet，丢弃编辑器侧碰撞/z_index）")
    if args.dry_run:
        print("   Python: （dry-run 不执行）")
    elif py_exe:
        print("   Python: %s" % py_exe)
    else:
        print("   Python: 未找到带 Pillow 的解释器，将退回 PATH 上的 python")
    print("=" * SEP)

    if args.map_ids:
        try:
            targets = parse_map_spec(" ".join(args.map_ids))
        except ValueError as exc:
            print("! %s" % exc)
            return 2
    else:
        if not sys.stdin or not sys.stdin.isatty():
            print("! 没有地图 ID 且当前不是交互终端；请直接写在命令行里，例如：")
            print("  python batch_convert.py 30 31")
            return 2
        targets = prompt_map_ids()
        if not targets:
            print("已退出。")
            return 0
        if not args.yes:
            print()
            print("将转换 %d 张地图: %s" % (
                len(targets), ", ".join("%04d" % m for m, _ in targets)))
            ans = input("继续？[Y/n] ").strip().lower()
            if ans and ans not in ("y", "yes"):
                print("已取消。")
                return 0
        print()

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_dir = LOG_ROOT / stamp
    results = []
    total_start = time.perf_counter()

    for idx, (map_id, dims) in enumerate(targets, 1):
        cmd = build_command(bat, game_dir, godot_dir, out_dir, map_id, dims, args.rebuild)
        print()
        print("-" * SEP)
        print("[%d/%d] Map%04d%s" % (idx, len(targets), map_id,
                                     "  (%dx%d)" % dims if dims else ""))
        print("-" * SEP)
        if args.dry_run:
            print("  " + subprocess.list2cmdline(cmd))
            results.append((map_id, "DRY", 0.0, "-"))
            continue

        rc, elapsed = run_one(cmd, log_dir / ("Map%04d.log" % map_id), py_exe)
        scene = godot_dir / "scene" / "maps_auto" / ("Map%04d_auto.tscn" % map_id)
        lower_ts = godot_dir / "tres" / ("Map%04d_lower_tileset.tres" % map_id)
        upper_ts = godot_dir / "tres" / ("Map%04d_upper_tileset.tres" % map_id)
        if rc != 0:
            status = "FAIL"
        elif not (scene.exists() and lower_ts.exists() and upper_ts.exists()):
            status = "WARN"
        else:
            status = "OK"
        results.append((map_id, status, elapsed, scene.name if scene.exists() else "-"))
        print("[%s] Map%04d  %.1fs" % (status, map_id, elapsed))
        if status != "OK" and args.stop_on_error:
            print("! 按 --stop-on-error 中止，剩余 %d 张未处理" % (len(targets) - idx))
            break

    print()
    print("=" * SEP)
    print(" 汇总（总耗时 %.1fs）" % (time.perf_counter() - total_start))
    print("=" * SEP)
    print(" " + pad("地图", 6) + pad("结果", 6) + pad("耗时", 9) + "产物")
    for map_id, status, elapsed, name in results:
        print(" " + pad("%04d" % map_id, 6) + pad(status, 6) + pad("%.1fs" % elapsed, 9) + name)

    failed = [r for r in results if r[1] in ("FAIL", "WARN")]
    ok = [r for r in results if r[1] == "OK"]
    print()
    print(" 成功 %d / %d" % (len(ok), len(targets)))
    if failed:
        print(" 失败或产物缺失: %s" % ", ".join("%04d" % r[0] for r in failed))
        if not args.dry_run:
            print(" 日志目录: %s" % log_dir)
        return 1
    if not args.dry_run:
        print(" 日志目录: %s" % log_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
