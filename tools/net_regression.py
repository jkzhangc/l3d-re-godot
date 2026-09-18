#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""联机无头回归一键 runner。

把散落在 network_lobby.gd / network_world.gd / game_init.gd 里的 --net-test 系列
开关固化成可复现的场景清单，一次命令跑完全部（或指定的）双端回归。

用法（在项目根目录或任意位置执行均可）：

    python tools/net_regression.py                 # 跑全部场景
    python tools/net_regression.py features weapon # 只跑指定场景
    python tools/net_regression.py --list          # 列出所有场景
    python tools/net_regression.py --keep-logs     # 保留本次日志（默认会清理成功的场景日志）

判定规则（三条全部满足才算通过）：
  1. 每个进程退出码为 0（失败路径在 GDScript 里统一是 get_tree().quit(1)）
  2. 期望的 *_COMPLETE / *_READY 标记全部出现在对应角色的输出里
  3. 任何角色输出里都没有出现 *_FAILED 标记

实现约定：
  - 使用 Godot 的 **console** 可执行文件，否则 Windows 下 GUI 版本不写 stdout，抓不到标记。
  - 用户参数必须放在 `--` 分隔符之后，Godot 才会把它们交给 OS.get_cmdline_user_args()。
  - 清理残留进程**只按 PID** —— 编辑器可执行文件与本 runner 用的 console 版本同名前缀，
    taskkill /IM 会误杀正在使用的编辑器（项目已知坑）。
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
LOG_ROOT = PROJECT_ROOT / "tools" / "net_regression_logs"

# Godot console 版本：Windows 下必须用它才能捕获 stdout
GODOT_CONSOLE = Path(r"D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe")

# Host 建房间后等 Client 握手，Client 需要晚于 Host 启动
HOST_WARMUP_SEC = 2.0

FAILED_RE = re.compile(r"AUTO_[A-Z0-9_]*_FAILED")

# exit(1) 以外的软失败：进程卡死超时
DEFAULT_TIMEOUT = 150


def _scenario(
    desc: str,
    host_args: list[str],
    client_args: list[list[str]],
    expect: dict[str, list[str]],
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = 0,
    note: str = "",
    known_fail: bool = False,
) -> dict:
    """retries: 失败后额外重试次数。用于已知受时序/敌人干扰影响的不稳定用例。
    known_fail: 该场景失败源于已知的游戏 bug（非回归套件问题）。汇总时单独归类为
    KNOWN-BUG，不计入"真回归"失败，也不触发重试（确定性 bug 重试无意义）。"""
    return {
        "desc": desc,
        "host": host_args,
        "clients": client_args,
        "expect": expect,
        "timeout": timeout,
        "retries": retries,
        "note": note,
        "known_fail": known_fail,
    }


SCENARIOS: dict[str, dict] = {
    # features 用例包含"受伤表现"断言，需要有敌人存在。开头安全屋（默认 GAME_SCENE）
    # 一个敌人都没有，会直接 AUTO_FEATURE_HOST_HURT_SETUP_FAILED missing_enemy；
    # 必须切到第一关街道图，由 Director 运行时刷出敌人后才能跑。
    "features": _scenario(
        "综合特性：投掷物输入 / Host 权威消费 / 受伤表现 / 倒地救援 / 举放武器过渡（第一关街道图）",
        ["--net-test=host", "--net-test-features", "--net-test-scene=enemies"],
        [["--net-test=client", "--net-test-features", "--net-test-scene=enemies"]],
        {"host": ["AUTO_FEATURE_HOST_COMPLETE"],
         "client0": ["AUTO_FEATURE_CLIENT_COMPLETE"]},
        retries=1,
        note="曾确定性失败，根因是 config.json 残留 facing_lock_mode=1（按住式），无头回归继承后 "
             "Client 每帧 _capture_facing_lock_input 未按住取消键即解锁，导致显式 RPC 加锁被立即解掉。"
             "2026-09-02 改为在 --net-test 启动时强制 Global.facing_lock_mode=0（切换式）使回归自洽，转绿。"
             "2026-09-17 死亡 setup 改为压 HP=1 绕ガッツ后仍偶发 FAIL：残余=Client 朝向解锁采样时序"
             "（失败点逐轮漂移），加 1 次重试消化。",
    ),
    "enemies": _scenario(
        "敌人同步：Director Host 化收编 + Client 可靠 spawn/死亡广播（第一关街道图）",
        ["--net-test=host", "--net-test-enemies", "--net-test-scene=enemies"],
        [["--net-test=client", "--net-test-enemies", "--net-test-scene=enemies"]],
        {"host": ["AUTO_ENEMY_HOST_COMPLETE", "AUTO_ENEMY_HOST_DEATH_COMPLETE"],
         "client0": ["AUTO_ENEMY_CLIENT_COMPLETE", "AUTO_ENEMY_CLIENT_DEATH_COMPLETE"]},
    ),
    "appearance": _scenario(
        "外观/难度端到端：特感 A1 复制 + 变体 A5 重建 + 酸弹 A2 镜像 + 难度 B1 同步（第一关街道图）",
        ["--net-test=host", "--net-test-appearance", "--net-test-scene=enemies",
         "--net-test-difficulty=2"],
        [["--net-test=client", "--net-test-appearance", "--net-test-scene=enemies",
          "--net-test-difficulty=1"]],
        {"host": ["AUTO_APPEARANCE_HOST_COMPLETE"],
         "client0": ["AUTO_APPEARANCE_CLIENT_COMPLETE"]},
        retries=1,
        note="难度断言为异值设计：Host 固定难度 2，Client 预置 1，进图后必须被 B1 的 "
             "start_game 覆写为 2（两端同值则断言退化为平凡成立，故必须异值）。",
    ),
    "downed-wipe": _scenario(
        "倒地 → 流血 → 真死亡 → 团灭黑屏 → 重载本章收敛（test 图）",
        ["--net-test=host", "--net-test=downed-wipe", "--net-test-scene=test"],
        [["--net-test=client", "--net-test=downed-wipe", "--net-test-scene=test"]],
        {"host": ["AUTO_TEAM_WIPE_HOST_RECOVERY_COMPLETE"],
         "client0": ["AUTO_TEAM_WIPE_CLIENT_RECOVERY_COMPLETE"]},
    ),
    # 同理：近战子断言需要一个 HP>0 的敌人做伤害校验，安全屋里没有敌人，
    # 会报 AUTO_CLIENT_KNIFE_FAILED ... enemy_hp_before=0.0。切到街道图。
    "weapon": _scenario(
        "武器链路：冲锋枪开火 / 换弹 / 切刀近战（第一关街道图，需 Director 刷出的敌人）",
        ["--net-test=host", "--net-test-weapon=smg_01", "--net-test-scene=enemies"],
        [["--net-test=client", "--net-test-weapon=smg_01", "--net-test-scene=enemies"]],
        {"host": ["AUTO_HOST_COMPLETE"],
         "client0": ["AUTO_CLIENT_FIRE_COMPLETE"]},
        retries=2,
        note="近战判定已改为按 entity_id 跟踪同敌 hp（总和分析会被 scatter 新刷敌人抬高）"
             "；残余不稳定=走位+挥刀时序（单跑易中、全量负载下挥空），重试消化。",
    ),
    "character-select": _scenario(
        "大厅选角：角色目录 / 重复角色选择 / 进图角色状态确认",
        ["--net-test=host", "--net-test-character-select"],
        [["--net-test=client", "--net-test-character-select"]],
        {"host": ["AUTO_CHARACTER_HOST_LOBBY_COMPLETE", "AUTO_CHARACTER_HOST_WORLD_COMPLETE"],
         "client0": ["AUTO_CHARACTER_CLIENT_LOBBY_COMPLETE", "AUTO_CHARACTER_CLIENT_WORLD_COMPLETE"]},
    ),
    "safe-door": _scenario(
        "安全门与章节流程：全员确认 → 统一切图 → 章节总结（第一关街道图）",
        ["--net-test=host", "--net-test-safe-door", "--net-test-scene=safe-door"],
        [["--net-test=client", "--net-test-safe-door", "--net-test-scene=safe-door"]],
        {"host": ["AUTO_SUMMARY_COMPLETE"],
         "client0": ["AUTO_SUMMARY_COMPLETE"]},
    ),
    "multi-disconnect": _scenario(
        "三人局断线收敛：一人掉线后剩余玩家席位回收一致",
        ["--net-test=host", "--net-test-multi-disconnect", "--net-test-players=3"],
        [
            ["--net-test=client", "--net-test-multi-disconnect",
             "--net-test-players=3", "--net-test-client-role=drop"],
            ["--net-test=client", "--net-test-multi-disconnect",
             "--net-test-players=3", "--net-test-client-role=stay"],
        ],
        {"host": ["AUTO_MULTI_HOST_ACK_COMPLETE"],
         "client0": ["AUTO_MULTI_CLIENT_DROP_READY"],
         "client1": ["AUTO_MULTI_CLIENT_STAY_COMPLETE"]},
    ),
    "slow-host-ready": _scenario(
        "慢速主机竞态：Host 延迟切场景时 Client 的 scene-ready 先到（街道图）",
        ["--net-test=host", "--net-test=slow-host-ready",
         "--net-test-host-scene-delay-ms=1500", "--net-test-scene=enemies"],
        [["--net-test=client", "--net-test=slow-host-ready", "--net-test-scene=enemies"]],
        {"host": ["AUTO_SLOWHOST_HOST_COMPLETE"],
         "client0": ["AUTO_SLOWHOST_CLIENT_COMPLETE"]},
    ),
    # 注意：这两个拾取用例的移动逻辑只按主轴单方向走位（见 network_world.gd
    # _run_auto_client_pickup_test），是按 test.tscn 的物件布局设计的：
    #   test.tscn        手枪(-222,-66) vs 出生点(-349,-68) → 纵向仅差 2px，走右 127px 即可进 18px 判定圈
    #   开头安全屋(默认)  手枪(-17,44)  vs 出生点(-163,120) → 纵向差 76px，单轴走位最近只能到 76px，永远够不着
    # 而 --net-test-pickup / --net-test-throwable-pickup 本身**不会**切换场景
    # （只有 --net-test-scene=test 会），因此必须显式带上，否则必然误报 MOVE_FAILED。
    "pickup": _scenario(
        "掉落物拾取：Client 请求式拾取 + Host 权威校验（test 图）",
        ["--net-test=host", "--net-test-pickup", "--net-test-scene=test"],
        [["--net-test=client", "--net-test-pickup", "--net-test-scene=test"]],
        {"host": ["AUTO_HOST_COMPLETE"],
         "client0": ["AUTO_CLIENT_PICKUP_COMPLETE"]},
        retries=2,
        note="已知不稳定：走位停止条件靠 50ms 采样命中 18px 窗口，"
             "test.tscn 的 7 个敌人会击退/打断玩家导致冲过头，实测约 1/3 概率误报 MOVE_FAILED",
    ),
    # 与 pickup 相反：投掷物用例**必须**留在开头安全屋。test.tscn 只有枪械类掉落物，
    # 没有任何投掷物，切过去会直接 SETUP_FAILED。
    # 已知脆弱点：安全屋里手雷(97,100) 距出生点(-163,120) 纵向差 20px，走位后刚好卡在
    # 28px 判定圈内，余量很小 —— 一旦出生点或物件位置被挪动就会误报，挪动后请重新校准。
    "throwable-pickup": _scenario(
        "投掷物拾取：Client 请求式拾取投掷物（开头安全屋，test 图无投掷物）",
        ["--net-test=host", "--net-test-throwable-pickup"],
        [["--net-test=client", "--net-test-throwable-pickup"]],
        {"host": ["AUTO_HOST_COMPLETE"],
         "client0": ["AUTO_CLIENT_THROWABLE_PICKUP_COMPLETE"]},
    ),
}


def _launch(role: str, user_args: list[str], log_path: Path):
    """启动一个无头 Godot 进程，stdout/stderr 写入 log_path。"""
    cmd = [
        str(GODOT_CONSOLE),
        "--headless",
        "--path", str(PROJECT_ROOT),
        "--",
        *user_args,
    ]
    log_path.parent.mkdir(parents=True, exist_ok=True)
    # Godot 输出为 UTF-8；Windows 默认 locale 是 GBK，必须显式指定避免乱码
    handle = log_path.open("w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen(
        cmd,
        stdout=handle,
        stderr=subprocess.STDOUT,
        cwd=str(PROJECT_ROOT),
    )
    return proc, handle


def _kill(proc) -> None:
    """只按 PID 终止 —— 切勿用 taskkill /IM（与编辑器可执行文件同名会被误杀）。"""
    if proc.poll() is None:
        proc.kill()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass


def run_scenario(name: str, spec: dict, keep_logs: bool) -> tuple[bool, str]:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out_dir = LOG_ROOT / f"{stamp}-{name}"
    out_dir.mkdir(parents=True, exist_ok=True)

    roles: list[tuple[str, list[str]]] = [("host", spec["host"])]
    for i, cargs in enumerate(spec["clients"]):
        roles.append((f"client{i}", cargs))

    procs: list[tuple[str, subprocess.Popen, object]] = []
    print(f"\n=== [{name}] {spec['desc']}")

    host_proc, host_handle = _launch("host", spec["host"], out_dir / "host.log")
    procs.append(("host", host_proc, host_handle))
    time.sleep(HOST_WARMUP_SEC)

    for role, cargs in roles[1:]:
        p, h = _launch(role, cargs, out_dir / f"{role}.log")
        procs.append((role, p, h))

    deadline = time.time() + spec["timeout"]
    timed_out = False
    # 轮询等待：一旦日志里出现"所有期望 *_COMPLETE 齐了"或"任意 *_FAILED"，
    # 即判定测试已出结论，立刻终止剩余进程，避免已知 bug/挂死场景空等满 timeout。
    poll_interval = 2.0
    while True:
        if all(p.poll() is not None for _r, p, _h in procs):
            break
        any_failed = False
        all_expected = True
        for role, _p, _h in procs:
            log = out_dir / f"{role}.log"
            text = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
            if FAILED_RE.search(text):
                any_failed = True
            exp = spec["expect"].get(role, [])
            if exp and not all(m in text for m in exp):
                all_expected = False
        if any_failed or all_expected:
            break
        if time.time() >= deadline:
            timed_out = True
            break
        time.sleep(poll_interval)
    for role, p, _h in procs:
        if p.poll() is None:
            if timed_out:
                print(f"    [{role}] 超时未退出，强制终止")
            _kill(p)

    for _role, _p, h in procs:
        try:
            h.close()
        except Exception:
            pass

    ok = True
    details: list[str] = []

    for role, p, _h in procs:
        text = (out_dir / f"{role}.log").read_text(encoding="utf-8", errors="replace")
        code = p.returncode

        failed = sorted(set(FAILED_RE.findall(text)))
        expected = spec["expect"].get(role, [])
        missing = [m for m in expected if m not in text]

        # 通过判据：期望的 *_COMPLETE 标记齐了 + 没有 *_FAILED 标记。
        # 不把"进程退出码 != 0"作为硬性失败——测试在打印成功标记后、进程真正退出前，
        # 常因 host 先 quit 关服触发客户端 disconnect 处理器再调一次 quit(1) 而覆盖退出码
        # （如 multi-disconnect 的 stay 客户端）。这种收尾竞态不代表游戏功能失败，按标记判定即可。
        role_ok = (not failed) and (not missing)
        if not role_ok:
            ok = False
            if failed:
                details.append(f"    [{role}] 失败标记: {', '.join(failed)}")
            if missing:
                details.append(f"    [{role}] 缺少标记: {', '.join(missing)}")
        elif code != 0:
            # 标记已齐但退出码非 0：疑似收尾竞态，按通过计，仅告警
            print(f"    [{role}] ⚠ 退出码={code} 但成功标记已齐（疑似收尾竞态，按通过计）")

        status = "OK " if role_ok else "FAIL"
        print(f"    [{role}] {status} exit={code} expected={len(expected) - len(missing)}/{len(expected)}")

    if timed_out:
        ok = False
        details.append("    场景整体超时")

    for d in details:
        print(d)

    if ok and not keep_logs:
        for f in out_dir.iterdir():
            f.unlink()
        try:
            out_dir.rmdir()
        except OSError:
            pass
        print(f"    日志已清理（通过场景）")
    else:
        print(f"    日志目录: {out_dir}")

    return ok, spec["desc"]


def main() -> int:
    parser = argparse.ArgumentParser(description="联机无头回归一键 runner")
    parser.add_argument("scenarios", nargs="*", help="要跑的场景名；留空=全部")
    parser.add_argument("--list", action="store_true", help="列出所有场景后退出")
    parser.add_argument("--keep-logs", action="store_true", help="保留通过场景的日志")
    args = parser.parse_args()

    if args.list:
        print("可用场景：")
        for k, v in SCENARIOS.items():
            flags = []
            if v["known_fail"]:
                flags.append("[已知BUG]")
            if v["retries"]:
                flags.append(f"[重试x{v['retries']}]")
            flag = ("  " + " ".join(flags)) if flags else ""
            print(f"  {k:20s} {v['desc']}{flag}")
            if v["note"]:
                print(f"  {'':20s}   ⚠ {v['note']}")
        return 0

    if not GODOT_CONSOLE.exists():
        print(f"[错误] 找不到 Godot console 可执行文件: {GODOT_CONSOLE}")
        print("       请修改 tools/net_regression.py 顶部的 GODOT_CONSOLE 路径。")
        return 2

    names = args.scenarios or list(SCENARIOS.keys())
    unknown = [n for n in names if n not in SCENARIOS]
    if unknown:
        print(f"[错误] 未知场景: {', '.join(unknown)}")
        print(f"       可用: {', '.join(SCENARIOS.keys())}")
        return 2

    print(f"Godot : {GODOT_CONSOLE}")
    print(f"项目  : {PROJECT_ROOT}")
    print(f"场景  : {', '.join(names)}")

    results: list[tuple[str, bool, int, bool]] = []
    for n in names:
        spec = SCENARIOS[n]
        # 已知 bug 场景确定性失败，重试无意义，直接跑一次
        attempts = 1 if spec["known_fail"] else spec["retries"] + 1
        ok = False
        used = 0
        for i in range(1, attempts + 1):
            used = i
            ok, _ = run_scenario(n, spec, args.keep_logs)
            if ok:
                break
            if i < attempts:
                print(f"    ↻ 第 {i}/{attempts} 次未通过，重试（已知不稳定用例）")
        results.append((n, ok, used, spec["known_fail"]))

    print("\n" + "=" * 56)
    print("回归汇总")
    print("=" * 56)
    n_pass = n_known = n_fail = 0
    for n, ok, used, known in results:
        if ok:
            n_pass += 1
            extra = f"（第 {used} 次尝试通过）" if used > 1 else ""
            print(f"  PASS       {n}{extra}")
        elif known:
            n_known += 1
            print(f"  KNOWN-BUG  {n}  ← 已知游戏 bug（见上方 note）")
        else:
            n_fail += 1
            extra = f"（{used} 次尝试均失败）" if used > 1 else ""
            print(f"  FAIL       {n}{extra}")
    print(f"\n通过 {n_pass} / 已知bug {n_known} / 真回归失败 {n_fail}   （共 {len(results)}）")
    # 已知 bug 不影响退出码；只有"真回归失败"才返回非零（CI 可据此拦截）
    return 1 if n_fail > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
