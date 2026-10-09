# 部署清单：frps（房主可达性 / 内网穿透）

> 目标：让**没有公网 IP 的房主**也能被外网玩家连上。
> 服务器：`8.138.99.96`（与 Master Server 同机）。
> 依据：`互联网联机模式策划方案.md` §2（可达性）、§2.4（硬门槛）、§12.2（实测）。

---

## 为什么需要它

```
互联网联机 = ①房主可达性（本文件） + ②房间发现（已部署的 Master Server）
```

游戏用 ENet/UDP。家宽房主没有公网 IP，外网连不进去 → 需要 frps 在公网服务器上
做一层 UDP 转发。**这是 M2「可发布」的必要条件**；M1 也可以先靠它验证。

---

## 三条硬门槛（先读，选错白折腾）

见方案 §2.4。frp 自建天然满足前两条，第三条要自己配：

| # | 门槛 | 本配置如何满足 |
|---|---|---|
| 1 | **UDP 单包上限 ≥ 1400** | `udpPacketSize = 1500`（默认值，**别改小**） |
| 2 | 支持 plain UDP | `type = "udp"` |
| 3 | 多会话并发（一个端口服务多个客户端） | frps 的 UDP 代理按来源地址自动分会话，默认满足 |

> ⚠ 第 1 条是实测踩出来的坑：ENet 的 MTU 是 **1392**，隧道上限一旦低于它，
> **握手能过、之后整个可靠通道静默停摆**（方案 §12.2）。客户端只显示"连不上"。

---

## 1. 【服务器】下载并安装 frps

```bash
cd /opt/l3d
# 拉取官方 release（写本文时最新为 v0.71.0；有新版本可自行替换版本号）
curl -fL -o frp.tar.gz \
  https://github.com/fatedier/frp/releases/download/v0.71.0/frp_0.71.0_linux_amd64.tar.gz
tar -xzf frp.tar.gz
mv frp_0.71.0_linux_amd64 frp
cd frp
./frps --version    # 确认能跑
```

> ⚠ **杀软/EDR 提示**：frps/frpc 是合法开源穿透工具，但常被安全软件误报（无签名 Go 二进制 +
> 常被滥用）。若服务器上有防护告警，把它加白名单。**本机（Windows）之前也杀过 frps.exe —— 
> 那是误报，但为免干扰我们当时改用了 Python 中继做实测。**

---

## 2. 【服务器】写配置

把仓库里 `master-server/deploy/frps.toml.example` 的内容拷成 `/opt/l3d/frp/frps.toml`，
**必改两处**：

- `auth.token` → 换成一串长随机字符串（这是唯一的准入凭证）
- `webServer.password` → 换个强密码（或干脆把 webServer 段删掉）

生成随机 token：

```bash
openssl rand -hex 32
```

`allowPorts` 默认给了 `27015–27030`（16 个端口）。M1 阶段够用；房主多了再放大范围。

---

## 3. 【控制台】放行 UDP 端口（关键）

阿里云轻量服务器**默认只放行 TCP**。控制台 → 轻量服务器 → 实例 → **防火墙** → 添加规则：

| 应用类型 | 协议 | 端口范围 | 来源 | 备注 |
|---|---|---|---|---|
| 自定义 | TCP | `7000` | `0.0.0.0/0` | frpc 接入（frps control） |
| 自定义 | UDP | `27015/27030` | `0.0.0.0/0` | 游戏 UDP 转发（对应 allowPorts） |

> **注意端口范围写法**：阿里云用 `起始/结束`（斜线），例如 `27015/27030`。
> 单个端口就直接填 `7000`。
>
> ⚠ 别忘了 Master Server 的 TCP 10000 也要在（之前已加）。

---

## 4. 【服务器】装成 systemd 服务

```bash
sudo tee /etc/systemd/system/l3d-frps.service > /dev/null <<'EOF'
[Unit]
Description=L3D frps (UDP relay for host reachability)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/l3d/frp
ExecStart=/opt/l3d/frp/frps -c /opt/l3d/frp/frps.toml
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now l3d-frps
sudo systemctl status l3d-frps --no-pager
```

看日志：

```bash
sudo journalctl -u l3d-frps -f
# 期望看到：frps started successfully / 监听 7000
```

---

## 5. 【房主电脑】装 frpc 并连上

房主侧用 `master-server/deploy/frpc.toml.example`，拷成 `frpc.toml` 后改三处：
`serverAddr` / `auth.token` / `remotePort`。

Windows 上下载对应 release，然后：

```powershell
.\frpc.exe -c .\frpc.toml
```

期望日志：`start proxy success`。

> ⚠ Windows 上可能被杀软拦住（误报）。加白名单后运行。

---

## 6. 验收：外网真的能连进房主的房间吗

**房主电脑**：
1. 起 frpc（上一步）。
2. 游戏里「多人大厅 → 互联网 → 创建房间」，本机端口填 `27015`。

**另一台电脑（外网）**：
3. 打开大厅 → 互联网页 → 应能看到房主的房间。
4. 点「加入」。能进 → ✅ 房主可达性打通。

> ⚠ 当前**注册到大厅的 address 还是房主本机占位值**（方案 §2.3 的 A1 形态）。
> frps 自动填 `tunnel.json` 是 M2 的活。M1 验证时，可先手动确认
> 「大厅里的地址 = 8.138.99.96 + 你选的 remotePort」。

---

## 7. 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| frpc 连不上 7000 | 防火墙没放 TCP 7000 | 回第 3 步 |
| frpc 报 `authorization failed` | token 不一致 | 两边逐字符核对 |
| frpc 报 `port already used` | remotePort 被别人占了 | 换 allowPorts 范围内另一个 |
| 大厅能看到房间但连不进 | UDP 端口没放行 / remotePort 不在 allowPorts 内 | 回第 3 步；核对端口 |
| **能连上但进图后卡死不动** | **udpPacketSize < 1400** | 两边都改成 1500（方案 §12.2） |
| 玩一会儿掉线 | 免费档限速 / 家宽上行不足 | 见方案 §12.3 的带宽实测与降频预案 |

---

## 8. 安全提醒

- `auth.token` 是唯一凭证，**别用示例值**，别提交进版本库。
- `allowPorts` 收紧到实际需要的范围，别开 `0-65535`。
- frps 面板（7500）保持绑 `127.0.0.1`；要公网访问就必须强密码 + 防火墙限来源 IP。
- 这套配置**不是账号级安全**，只保证"房间不被第三方篡改/滥用"。真账号体系留到后续。
