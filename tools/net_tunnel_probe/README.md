# net_tunnel_probe —— ENet over UDP 隧道实测工具

验证「互联网联机」方案里三个**会决定可行性**的假设。用**真实 ENet + 真实 UDP 中继**
在本机把假设跑成数字，结果见 `互联网联机模式策划方案.md` §2.4 与 §12。

## 为什么需要它

方案要求「房主经 UDP 隧道被外网连接」。ENet 走 UDP 经一层隧道代理时，有三件事没人验证过：

| # | 待验证 | 结论（2026-10-09 实测） |
|---|---|---|
| 1 | 多个客户端经**同一个**隧道端口，Host 能否区分 | ✅ 能，3 个客户端被正确识别为 3 个 peer |
| 2 | 大 RPC（完整快照等）经隧道会不会被截断 | ⚠️ ENet 自动分片到 MTU=1392；**隧道单包上限 < 1392 会静默卡死** |
| 3 | 4 人局快照的真实带宽 | ⚠️ 快照是 **60Hz**（非 20Hz），30 敌人时约 1.8 Mbps/客户端 |

## 为什么不用 frps 本体

官方 `frps.exe`（Go 编译、无签名）在用户机器上常被杀软误报并隔离。
`udp_relay.py` 是纯文本 Python，行为对齐 frps 的 UDP 代理（按来源地址分会话转发、
可限单包长度、逐包统计），**测的是同一件事**。

## 用法

```bash
# 对照组：直连（不经中继）
python tools/net_tunnel_probe/runner.py --case baseline

# 多客户端经同一中继
python tools/net_tunnel_probe/runner.py --case multi

# 分片边界：逐级加压，看隧道单包上限在哪一档失效
python tools/net_tunnel_probe/runner.py --case payload --bytes 200,1400,3000,20000 --max-packet 1500
python tools/net_tunnel_probe/runner.py --case payload --bytes 1200,1400,3000 --max-packet 1300

# 带宽：4 人局（3 客户端）30 敌人
python tools/net_tunnel_probe/runner.py --case snapshot --clients 3 --enemies 30 --life 20
```

Godot 路径默认取环境变量 `GODOT_CONSOLE`；未设置则用脚本顶部的 `_DEFAULT_GODOT`
（Windows 下**必须**用 console 版可执行文件，否则抓不到 stdout）。

## 文件

| 文件 | 作用 |
|---|---|
| `runner.py` | 编排器：起中继 + 起 Host/Client 无头 Godot，汇总判定 |
| `udp_relay.py` | 纯 Python UDP 中继（模拟穿透代理，可限单包长度） |
| `probe.gd` / `.tscn` | 连接/握手/多客户端/大 RPC 探针 |
| `snapshot_probe.gd` / `.tscn` | 与 `network_world.gd` 同构的快照带宽探针 |
| `logs/` | 每次运行的 Godot stdout（**勿入库**） |

## 判定口径

- `RESULT <case>: PASS/FAIL` 是每个用例的结论行。
- `RELAY_STATS {...}` 是中继统计：`max_seen_packet`（入站最大单包）、
  `dropped_oversize`（超限丢弃数）、`t2c_bytes`（Host→Client 上行字节）。
- **单包上限低于 1392 时**，`payload` 用例会 FAIL 且 `dropped_oversize > 0` —— 这就是要防的故障。

## 注意

- 探针复用正式 `Net` autoload 的 `host_game()` / `join_game()` 与握手路径，**只测量、不改游戏逻辑**。
- 清理残留进程**只按 PID** —— 切勿 `taskkill /IM`（与编辑器可执行文件同名会被误杀）。
