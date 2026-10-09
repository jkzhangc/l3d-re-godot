#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""纯 Python UDP 中继 —— 用于替代 frps 做「ENet over UDP 隧道」实测。

为什么用它：frps.exe（Go 编译、无签名）在用户机器上常被杀毒软件误报并隔离。
本脚本是纯文本 Python，不含二进制，不会触发杀软；同时**行为对齐 frps 的 UDP 代理**：
  - 公网侧监听一个端口（模拟穿透服务的公网 UDP 端口）；
  - 收到任一新来源的包 → 建立 `来源地址 -> 本地端口` 的会话映射；
  - 转发给本地端口（模拟 frpc 把流量交给本机游戏进程）；
  - 本地端口回包 → 按会话映射转发回原来源；
  - **丢弃超过 max_packet 的入站包并计数**（对齐 frps `udpPacketSize`，默认 1500）。

用法（由 runner.py 调用；也可手动跑）：
  python udp_relay.py --listen 40000 --target 127.0.0.1:27015 --max-packet 1500
统计在退出时（或 Ctrl+C）打印到 stdout，格式 `RELAY_STATS {...}` 便于解析。

相关文档：`互联网联机模式策划方案.md` §12（实测报告）。
"""

from __future__ import annotations

import argparse
import json
import socket
import threading
import time

# 会话空闲多久后回收（frps 对 UDP 会话也有老化）。
SESSION_IDLE_SEC = 60.0


class UdpRelay:
    def __init__(self, listen_port: int, target_host: str, target_port: int, max_packet: int):
        self.listen_port = listen_port
        self.target = (target_host, target_port)
        self.max_packet = max_packet

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", listen_port))

        # 客户端来源地址 -> 该来源在"本机本地"的转发套接字（隔离每个会话）
        self.sessions: dict[tuple[str, int], socket.socket] = {}
        self.lock = threading.Lock()
        self.running = True

        # 统计
        self.stat = {
            "listen_port": listen_port,
            "target": f"{target_host}:{target_port}",
            "max_packet": max_packet,
            "c2t_packets": 0,        # client -> target 方向包数
            "c2t_bytes": 0,
            "t2c_packets": 0,        # target -> client 方向包数
            "t2c_bytes": 0,
            "dropped_oversize": 0,   # 超过 max_packet 被丢弃的包数
            "max_seen_packet": 0,    # c2t 方向最大单包（入站，受 max_packet 约束）
            "max_seen_packet_t2c": 0,  # t2c 方向最大单包（出站，仅观测不丢弃）
            "sessions": 0,
        }

    def _new_session(self, client_addr: tuple[str, int]) -> socket.socket:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))

        def pump():
            last = time.time()
            s.settimeout(1.0)
            while self.running:
                try:
                    data, _ = s.recvfrom(65535)
                except socket.timeout:
                    if time.time() - last > SESSION_IDLE_SEC:
                        break
                    continue
                except OSError:
                    break
                last = time.time()
                with self.lock:
                    self.stat["t2c_packets"] += 1
                    self.stat["t2c_bytes"] += len(data)
                    self.stat["max_seen_packet_t2c"] = max(self.stat["max_seen_packet_t2c"], len(data))
                try:
                    self.sock.sendto(data, client_addr)
                except OSError:
                    break
            try:
                s.close()
            except OSError:
                pass
            with self.lock:
                self.sessions.pop(client_addr, None)

        threading.Thread(target=pump, daemon=True).start()
        return s

    def run(self) -> None:
        print(f"RELAY_READY listen={self.listen_port} target={self.target[0]}:{self.target[1]} "
              f"max_packet={self.max_packet}", flush=True)
        self.sock.settimeout(1.0)
        while self.running:
            try:
                data, client_addr = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break

            with self.lock:
                self.stat["max_seen_packet"] = max(self.stat["max_seen_packet"], len(data))

            # 对齐 frps udpPacketSize：超长包直接丢（这正是要测的边界）。
            if len(data) > self.max_packet:
                with self.lock:
                    self.stat["dropped_oversize"] += 1
                continue

            with self.lock:
                s = self.sessions.get(client_addr)
                if s is None:
                    s = self._new_session(client_addr)
                    self.sessions[client_addr] = s
                    self.stat["sessions"] = len(self.sessions)
                self.stat["c2t_packets"] += 1
                self.stat["c2t_bytes"] += len(data)
            try:
                s.sendto(data, self.target)
            except OSError:
                pass

    def dump(self) -> None:
        with self.lock:
            self.stat["sessions"] = len(self.sessions)
            print("RELAY_STATS " + json.dumps(self.stat, ensure_ascii=False), flush=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--target", type=str, required=True, help="host:port")
    ap.add_argument("--max-packet", type=int, default=1500)
    ap.add_argument("--duration", type=float, default=0.0, help=">0 则到点自动退出并打印统计")
    args = ap.parse_args()

    host, port = args.target.rsplit(":", 1)
    relay = UdpRelay(args.listen, host, int(port), args.max_packet)

    if args.duration > 0:
        def stopper():
            time.sleep(args.duration)
            relay.running = False
        threading.Thread(target=stopper, daemon=True).start()

    try:
        relay.run()
    except KeyboardInterrupt:
        pass
    relay.dump()


if __name__ == "__main__":
    main()
