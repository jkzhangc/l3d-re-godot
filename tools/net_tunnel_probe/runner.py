#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ENet-over-UDP-tunnel 实测编排器。

背景：互联网联机方案要求「房主经 UDP 隧道被外网连接」，但 ENet 走 UDP 经
一层隧道代理时有三个未经验证的假设。本编排器用**真实 ENet + 真实 UDP 中继**
在本机把这三个假设跑成数字：

  A) baseline  —— Host 与 Client 直连（127.0.0.1），验证探针自身可用（对照组）
  B) multi     —— 3 个 Client 经**同一个** UDP 中继连接，验证多客户端是否被正确区分
  C) payload   —— 1 个 Client 经中继发指定字节数的可靠 RPC，测 ENet 分片与隧道包长上限
  D) snapshot  —— 用与 network_world.gd 同构的快照结构，按真实 60Hz 测 4 人局带宽

为什么不用 frps 本体：官方 Go 二进制常被杀软误报/隔离。udp_relay.py 是纯 Python，
行为对齐 frps 的 UDP 代理（按来源地址分会话转发、可限单包长度、逐包统计），
测的是同一件事（UDP 包经一层代理转发的行为）。

用法（在项目根目录或任意位置执行均可）：
  python tools/net_tunnel_probe/runner.py --case baseline
  python tools/net_tunnel_probe/runner.py --case multi
  python tools/net_tunnel_probe/runner.py --case payload --bytes 3000 --max-packet 1300
  python tools/net_tunnel_probe/runner.py --case snapshot --clients 3 --enemies 30

Godot 路径：默认取环境变量 GODOT_CONSOLE；未设置则用 _DEFAULT_GODOT。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

## 项目根：从本文件向上找到含 project.godot 的目录（对目录搬家免疫）。
def _find_project_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "project.godot").exists():
            return parent
    raise RuntimeError("找不到 project.godot；请把本脚本放在项目树内")

PROJECT = _find_project_root()
HERE = Path(__file__).resolve().parent

## Windows 下必须用 console 版可执行文件，否则 GUI 版不写 stdout，抓不到标记。
_DEFAULT_GODOT = Path(r"D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe")
GODOT = Path(os.environ.get("GODOT_CONSOLE", str(_DEFAULT_GODOT)))

PROBE_SCENE = "res://tools/net_tunnel_probe/probe.tscn"
SNAPSHOT_SCENE = "res://tools/net_tunnel_probe/snapshot_probe.tscn"
LOG_DIR = HERE / "logs"
RELAY = HERE / "udp_relay.py"
PY = sys.executable


def launch(name: str, user_args: list[str], scene: str = PROBE_SCENE):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = LOG_DIR / f"{name}.log"
    h = log.open("w", encoding="utf-8", errors="replace")
    cmd = [str(GODOT), "--headless", "--path", str(PROJECT), scene, "--", *user_args]
    p = subprocess.Popen(cmd, stdout=h, stderr=subprocess.STDOUT, cwd=str(PROJECT))
    return p, log


def kill(p: subprocess.Popen) -> None:
    """只按 PID 终止 —— 切勿用 taskkill /IM（与编辑器可执行文件同名会被误杀）。"""
    if p.poll() is None:
        p.kill()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass


def read(log: Path) -> str:
    try:
        return log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def wait_for(log: Path, token: str, timeout: float) -> bool:
    t0 = time.time()
    while time.time() - t0 < timeout:
        if token in read(log):
            return True
        time.sleep(0.3)
    return False


def grep(text: str, pattern: str) -> list:
    return re.findall(pattern, text)


def _start_relay(listen: int, target: str, max_packet: int, duration: int):
    return subprocess.Popen([PY, str(RELAY), "--listen", str(listen),
                             "--target", target, "--max-packet", str(max_packet),
                             "--duration", str(duration)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def _dump_relay_stats(relay, timeout: float) -> None:
    """等中继自然退出（--duration 到点）以拿到 RELAY_STATS；超时再硬杀。"""
    try:
        out, _ = relay.communicate(timeout=timeout)
        for line in out.splitlines():
            if line.startswith("RELAY_STATS"):
                print(line)
    except subprocess.TimeoutExpired:
        relay.terminate()
        print("relay 未自然退出（超时），统计缺失")


# ─────────────────────────── A) baseline ───────────────────────────

def case_baseline() -> int:
    print("=== CASE baseline: direct 127.0.0.1（对照组，不经过中继）===")
    host, hlog = launch("base_host", ["--probe=host", "--probe-port=27015"])
    assert wait_for(hlog, "HOST_LISTENING", 20), "host 未监听"
    time.sleep(1.0)
    c1, c1log = launch("base_c1", ["--probe=client", "--probe-addr=127.0.0.1",
                                   "--probe-port=27015", "--probe-name=C1"])
    time.sleep(0.5)
    c2, c2log = launch("base_c2", ["--probe=client", "--probe-addr=127.0.0.1",
                                   "--probe-port=27015", "--probe-name=C2"])
    time.sleep(22)
    for p in (host, c1, c2):
        kill(p)
    ht, c1t, c2t = read(hlog), read(c1log), read(c2log)
    peers = grep(ht, r"HOST_PEERS t=.*ids=(\[[^\]]*\])")
    print("HOST_PEERS sightings:", peers[-3:] if peers else "NONE")
    print("c1 handshake:", "CLIENT_HANDSHAKE_OK" in c1t)
    print("c2 handshake:", "CLIENT_HANDSHAKE_OK" in c2t)
    ok = bool(peers) and len(json.loads(peers[-1])) >= 3
    print("RESULT baseline:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


# ─────────────────────────── B) multi ───────────────────────────

def case_multi() -> int:
    print("=== CASE multi: 3 客户端经同一个 UDP 中继 ===")
    relay = _start_relay(40000, "127.0.0.1:27015", 1500, 40)
    time.sleep(1.5)
    host, hlog = launch("multi_host", ["--probe=host", "--probe-port=27015"])
    assert wait_for(hlog, "HOST_LISTENING", 20), "host 未监听"
    time.sleep(1.0)
    clients = []
    for nm in ["M1", "M2", "M3"]:
        c, clog = launch(f"multi_{nm}", ["--probe=client", "--probe-addr=127.0.0.1",
                                         "--probe-port=40000", "--probe-name=" + nm])
        clients.append((c, clog))
        time.sleep(0.4)
    time.sleep(22)
    for p, _ in clients:
        kill(p)
    kill(host)
    ht = read(hlog)
    peers = grep(ht, r"HOST_PEERS t=.*ids=(\[[^\]]*\])")
    print("HOST_PEERS sightings:", peers[-3:] if peers else "NONE")
    for _, cl in clients:
        t = read(cl)
        print(f"  {cl.stem}: handshake={'CLIENT_HANDSHAKE_OK' in t}")
    distinct = len(json.loads(peers[-1])) if peers else 0
    print("distinct peers seen by host:", distinct)
    relay.terminate()
    _dump_relay_stats_terminated(relay)
    ok = distinct >= 4  # host + 3 clients
    print("RESULT multi:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def _dump_relay_stats_terminated(relay) -> None:
    try:
        out, _ = relay.communicate(timeout=10)
        for line in out.splitlines():
            if line.startswith("RELAY_STATS"):
                print(line)
    except Exception as e:  # noqa: BLE001
        print("relay stats err:", e)


# ─────────────────────────── C) payload ───────────────────────────

def case_payload(nbytes: str, max_packet: int) -> int:
    sizes = [int(x) for x in nbytes.split(",") if x.strip()]
    print(f"=== CASE payload: sizes={sizes}, relay max_packet={max_packet} ===")
    life = 25
    relay = _start_relay(40000, "127.0.0.1:27015", max_packet, life + 10)
    time.sleep(1.5)
    host, hlog = launch("pay_host", ["--probe=host", "--probe-port=27015", f"--probe-life={life}"])
    assert wait_for(hlog, "HOST_LISTENING", 20), "host 未监听"
    time.sleep(1.0)
    c, clog = launch("pay_c1", ["--probe=client", "--probe-addr=127.0.0.1",
                                "--probe-port=40000", "--probe-name=PC",
                                f"--probe-life={life}", f"--probe-payloads={nbytes}"])
    # 逐级加压：每个尺寸等回执（或超时）后再发下一个，故给足总时长
    time.sleep(life + 2)
    kill(c)
    kill(host)
    ct = read(clog)
    sent = grep(ct, r"PAYLOAD_SEND bytes=(\d+)")
    ack = grep(ct, r"CLIENT_RECV_ACK bytes=(\d+) declared=(\d+) rtt_ms=(\d+)")
    print("sizes sent :", sent)
    print("acks       :", ack)
    _dump_relay_stats(relay, timeout=life + 20)
    ok = len(ack) == len(sizes) and len(sent) > 0
    print("RESULT payload:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


# ─────────────────────────── D) snapshot ───────────────────────────

def case_snapshot(enemies: int, clients: int, life: int, max_packet: int) -> int:
    print(f"=== CASE snapshot: clients={clients} enemies={enemies} life={life}s "
          f"max_packet={max_packet} ===")
    relay = _start_relay(40000, "127.0.0.1:27015", max_packet, life + 12)
    time.sleep(1.5)
    host, hlog = launch("snap_host", ["--snap=host", "--snap-port=27015",
                                      f"--snap-enemies={enemies}", f"--snap-life={life}"],
                        scene=SNAPSHOT_SCENE)
    assert wait_for(hlog, "HOST_LISTENING", 20), "host 未监听"
    time.sleep(1.0)
    cps = []
    for i in range(clients):
        c, clog = launch(f"snap_c{i}", ["--snap=client", "--snap-addr=127.0.0.1",
                                        "--snap-port=40000", f"--snap-life={life}"],
                         scene=SNAPSHOT_SCENE)
        cps.append((c, clog))
        time.sleep(0.5)
    time.sleep(life + 8)
    for p, _ in cps:
        kill(p)
    kill(host)
    ht = read(hlog)
    done = grep(ht, r"DONE sent_players=(\d+) sent_enemies=(\d+)")
    print("host snapshot ticks (players,enemies):", done)
    try:
        out, _ = relay.communicate(timeout=life + 25)
        for line in out.splitlines():
            if line.startswith("RELAY_STATS"):
                stats = json.loads(line[len("RELAY_STATS "):])
                print(line)
                # c2t = client->host；t2c = host->client（上行）
                up = stats["t2c_bytes"] / life
                down = stats["c2t_bytes"] / life
                print(f"  host->client (上行) = {up:.0f} B/s = {up*8/1024:.1f} Kbit/s "
                      f"(共 {clients} 客户端合计)")
                print(f"  client->host (下行) = {down:.0f} B/s = {down*8/1024:.1f} Kbit/s")
                print(f"  最大单包 c2t={stats['max_seen_packet']} B / "
                      f"t2c={stats.get('max_seen_packet_t2c', '?')} B, "
                      f"丢弃超限包 = {stats['dropped_oversize']}")
    except subprocess.TimeoutExpired:
        relay.terminate()
        print("relay 未自然退出（超时），统计缺失")
    ok = bool(done) and int(done[0][0]) > 0
    print("RESULT snapshot:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main() -> None:
    ap = argparse.ArgumentParser(description="ENet-over-UDP-tunnel 实测编排器")
    ap.add_argument("--case", required=True,
                    choices=["baseline", "multi", "payload", "snapshot"])
    ap.add_argument("--bytes", type=str, default="1200",
                    help="payload 用例的尺寸序列，逗号分隔，如 1200,3000,60000")
    ap.add_argument("--max-packet", type=int, default=1500,
                    help="模拟隧道单包上限（frps udpPacketSize 默认 1500；ENet MTU=1392）")
    ap.add_argument("--enemies", type=int, default=15, help="snapshot 用例的敌人数量")
    ap.add_argument("--clients", type=int, default=1, help="snapshot 用例的客户端数量")
    ap.add_argument("--life", type=int, default=20, help="snapshot 用例运行秒数")
    a = ap.parse_args()

    if not GODOT.exists():
        print(f"[错误] 找不到 Godot console 可执行文件: {GODOT}")
        print("       请设置环境变量 GODOT_CONSOLE，或修改本脚本顶部的 _DEFAULT_GODOT。")
        sys.exit(2)

    if a.case == "baseline":
        sys.exit(case_baseline())
    elif a.case == "multi":
        sys.exit(case_multi())
    elif a.case == "payload":
        sys.exit(case_payload(a.bytes, a.max_packet))
    else:
        sys.exit(case_snapshot(a.enemies, a.clients, a.life, a.max_packet))


if __name__ == "__main__":
    main()
