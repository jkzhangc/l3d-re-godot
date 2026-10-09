#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 frp 配置模板：纯 ASCII + 合法 TOML。

【为什么需要这个校验】frp 用的是 Go 的 TOML 解析器，它在**注释里遇到非 ASCII 字符**时会直接报
    toml: line 1, column 3: toml: invalid character in comment
  —— 一个 U+2500（─）就足以让 frps 起不来。本脚本把它固化成一条可复跑的检查。
"""

import pathlib
import sys
import tomllib

DEPLOY = pathlib.Path(__file__).resolve().parent.parent / "deploy"
FILES = ["frps.toml.example", "frpc.toml.example"]


def check(name: str) -> bool:
    path = DEPLOY / name
    raw = path.read_bytes()
    bad = [(i, b) for i, b in enumerate(raw) if b > 127]
    print(f"{name}: 非ASCII字节={len(bad)}")
    if bad:
        i, _ = bad[0]
        line = raw[:i].count(b"\n") + 1
        print(f"  [失败] 首个非 ASCII 字节在第 {line} 行 —— frp 的 TOML 解析器会拒绝")
        return False
    try:
        data = tomllib.loads(raw.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        print(f"  [失败] TOML 解析错误：{exc}")
        return False
    print(f"  TOML 解析 OK，顶层键={sorted(data.keys())}")

    ok = True
    if name == "frps.toml.example":
        size = data.get("udpPacketSize")
        print(f"  udpPacketSize={size}")
        if not isinstance(size, int) or size < 1400:
            print("  [失败] udpPacketSize 必须 >= 1400（ENet MTU=1392，见方案 §12.2）")
            ok = False
        ports = data.get("allowPorts")
        print(f"  allowPorts={ports}")
        if not ports:
            print("  [失败] allowPorts 为空")
            ok = False
    else:
        size = data.get("udpPacketSize")
        print(f"  udpPacketSize={size}")
        if size != 1500:
            print("  [失败] 客户端 udpPacketSize 必须与服务端一致（1500）")
            ok = False
        proxy = (data.get("proxies") or [{}])[0]
        print(f"  proxy type={proxy.get('type')} localPort={proxy.get('localPort')} "
              f"remotePort={proxy.get('remotePort')}")
        if proxy.get("type") != "udp":
            print("  [失败] 必须是 udp 代理")
            ok = False
    return ok


def main() -> int:
    all_ok = all(check(n) for n in FILES)
    print("RESULT:", "PASS" if all_ok else "FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
