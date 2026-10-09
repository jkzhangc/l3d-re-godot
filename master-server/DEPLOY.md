# 部署清单：Master Server（8.138.99.96）

> 目标：把 `master-server/` 跑在阿里云轻量服务器上，监听 `0.0.0.0:10000`，
> 并放行 UDP 端口给后续 frps 用。
> 全程约 10 分钟。命令都在**服务器上**执行（除第 1 步在你本机）。

---

## 0. 前置：确认系统与网络

服务器用**系统镜像 Ubuntu 22.04 / 24.04**（不是 OpenClaw 应用镜像）。

```bash
# 在服务器上：
lsb_release -a          # 看是不是 Ubuntu
node --version 2>/dev/null || echo "还没装 node"
```

---

## 1. 【本机】打包项目里的 master-server

在 **Windows 本机**、项目根目录执行：

```powershell
cd "d:\!bird's-eye-view-arpg-test-\l3d-re-godot"
# 打包时排除 node_modules（服务器上重新装，跨平台更干净）
tar -czf master-server.tar.gz --exclude=node_modules master-server
```

产物：`master-server.tar.gz`（约几十 KB）。

---

## 2. 【服务器】安装 Node.js 18+

```bash
# 用 NodeSource 装 Node 20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version     # 应显示 v20.x
```

---

## 3. 【服务器】上传并启动

把 `master-server.tar.gz` 用你习惯的方式传上去（scp / 宝塔面板 / WinSCP 均可）。

```bash
# 假设传到了 /root/master-server.tar.gz
sudo mkdir -p /opt/l3d && cd /opt/l3d
sudo tar -xzf /root/master-server.tar.gz -C /opt/l3d
cd /opt/l3d/master-server

sudo npm install --omit=dev

# 先手动跑一次，确认能起（Ctrl+C 退出）
PORT=10000 node server.js
# 期望看到：[master-server] listening on 0.0.0.0:10000
```

**另一个终端**在本机验证：

```powershell
Invoke-RestMethod "http://8.138.99.96:10000/health"
# 期望：{"status":"ok"}
```

> ⚠ 如果这里不通，**先看第 4 步的防火墙**，再排查服务。

---

## 4. 【控制台】放行 TCP 10000（必须）

阿里云轻量应用服务器默认只放行 **TCP 22/80/443**。

**控制台 → 轻量应用服务器 → 点实例 → 防火墙 → 添加规则：**

| 应用类型 | 协议 | 端口范围 | 来源 | 备注 |
|---|---|---|---|---|
| 自定义 | TCP | `10000` | `0.0.0.0/0` | Master Server |
| 全部UDP | UDP | 全部（或 `7000`, `27015`） | `0.0.0.0/0` | frps + 游戏（M2 用，可先加） |

> 只放行 TCP 10000 就够 M1 的发现层。UDP 那两条是给后续 frps 用的，现在加好省得再回来。

---

## 5. 【服务器】装成 systemd 服务（开机自启 + 崩溃重启）

```bash
sudo tee /etc/systemd/system/l3d-master.service > /dev/null <<'EOF'
[Unit]
Description=L3D Master Server (room directory)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/l3d/master-server
Environment=PORT=10000
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now l3d-master
sudo systemctl status l3d-master --no-pager
```

常用命令：

```bash
sudo systemctl restart l3d-master      # 重启
sudo journalctl -u l3d-master -f       # 看实时日志
```

---

## 6. 验收

```powershell
# 本机执行
Invoke-RestMethod "http://8.138.99.96:10000/health"
Invoke-RestMethod "http://8.138.99.96:10000/api/stats"
# 期望：{"success":true,"rooms":N,"players":M}
```

再跑一次仓库自带的联网集成用例：

```powershell
cd "d:\!bird's-eye-view-arpg-test-\l3d-re-godot"
& "D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe" `
  --headless --path . res://tools/lobby_client_test.tscn `
  -- --lobby-url=http://8.138.99.96:10000
# 期望：AUTO_LOBBY_CLIENT_COMPLETE
```

---

## 7. 后续：备案完成后切 HTTPS（重要）

现在客户端能用 `http://8.138.99.96:10000`（**仅 PC 端**，安卓禁明文 HTTP）。

域名备案通过后：

1. 用 Nginx/Caddy 反代 `10000` 并配 Let's Encrypt 证书（Caddy 两行配置即可自动签证书）。
2. 把客户端 `config.json` 的 `master_server_url` 改成 `https://你的域名`。
3. 把 `script/lobby_client.gd` 的 `INSECURE_HOSTS_ALLOWED` 里的 `8.138.99.96` **删掉**
   （保留 127.0.0.1 / localhost 给本地开发）。
4. 控制台防火墙可只保留 80/443，关掉明文 10000 的对外暴露。

---

## 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| 本机 `/health` 超时 | 防火墙没放行 TCP 10000 | 回到第 4 步 |
| `listening` 有了但仍连不上 | 服务没监听 0.0.0.0 | 确认命令里没有写 `localhost` |
| systemd 起不来 | 端口被占 / node 路径不对 | `journalctl -u l3d-master -n 50` |
| 客户端报"大厅地址不安全" | URL 不在白名单 | 检查 `config.json` 是否与白名单一致 |
