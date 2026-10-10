---
name: l3d-master-deploy
description: Deploy or verify the L3D master-server on Aliyun 8.138.99.96 — upload, hash check, systemd restart, live endpoint and tunnel checks. Use when asked to deploy, redeploy, restart, or verify the room directory or tunnel relay. Do not use for client or Godot export tasks.
---

# L3D Master Server 部署 / 验收

把本仓库 `master-server/` 部署到阿里云主机，并做端到端验收。改动通常只涉及少数文件；**只传改动的文件**，不必重打整包（除非依赖树变了，那时才 `npm install`）。

## 固定事实（勿臆造）

| 项 | 值 |
|---|---|
| 主机 | `root@8.138.99.96` |
| SSH 私钥 | `$env:USERPROFILE\.ssh\l3d_server`（免密已配，`BatchMode` 可用） |
| 部署目录 | `/opt/l3d/master-server` |
| systemd 服务 | `l3d-master`（`systemctl restart l3d-master`） |
| Master Server | TCP `10000` |
| 隧道中继控制口 | TCP `10001` |
| 隧道 UDP 端口池 | UDP `27015-27030`（16 个） |
| 健康检查 | `GET /health` → `{"status":"ok"}`（**不是** `/api/health`） |
| 统计 | `GET /api/stats` → `{"success":true,"rooms":N,"players":M}` |

## SSH 调用约定（Windows PowerShell）

沙箱禁止写真实 `known_hosts`，每条 ssh/scp **必须**带 `UserKnownHostsFile` 指向可写位置，并加 `StrictHostKeyChecking=accept-new`，否则报 `Host key verification failed`：

```powershell
$SSH = "C:\Windows\System32\OpenSSH\ssh.exe"
$SCP = "C:\Windows\System32\OpenSSH\scp.exe"
$KEY = "$env:USERPROFILE\.ssh\l3d_server"
$KH  = "$env:TEMP\l3d_known_hosts"
# 统一参数：-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KH
```

> PowerShell 会把 ssh 写到 stderr 的 `Warning: Permanently added ...` 显示成红字，**无害**，看 `$LASTEXITCODE` 或后续输出即可。
> 命令里**不要用 `cmd /c`**（被沙箱拦截）；优先用 PowerShell 原生。

## 部署流程

### 1. 确认服务器连通与现状

```powershell
& $SSH -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KH root@8.138.99.96 `
  "systemctl is-active l3d-master; ss -lntup | grep -E '10000|10001'"
```

### 2. 确认改了什么（决定传哪些文件 / 是否需 npm install）

```powershell
git diff --stat <上次部署的commit> HEAD -- master-server/
```

- 只改 `.js`/源码 → 传对应文件，**不需要** `npm install`
- 改了 `package.json` / `package-lock.json` → 必须在服务器上 `npm install --omit=dev`

### 3. 记录本地哈希（供第 6 步对照）

```powershell
(Get-FileHash "master-server\src\tunnel_relay.js" -Algorithm SHA256).Hash
```

### 4. 上传到临时名（不直接覆盖，先落到 `/root/xxx.new`）

```powershell
& $SCP -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KH `
  "d:\!bird's-eye-view-arpg-test-\l3d-re-godot\master-server\src\tunnel_relay.js" `
  root@8.138.99.96:/root/tunnel_relay.js.new
```

### 5. 备份旧文件 → 替换 → 语法校验

```powershell
& $SSH -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KH root@8.138.99.96 `
  "set -e; cd /opt/l3d/master-server/src; cp -a tunnel_relay.js tunnel_relay.js.bak.\$(date +%Y%m%d_%H%M%S); cp -f /root/tunnel_relay.js.new tunnel_relay.js; node --check tunnel_relay.js && echo SYNTAX_OK; sha256sum tunnel_relay.js | cut -d' ' -f1"
```

### 6. 校验哈希与本地一致（**不一致就别重启**）

第 5 步输出的 sha256 必须等于第 3 步的本地哈希。

### 7. 重启并看日志

```powershell
& $SSH -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KH root@8.138.99.96 `
  "systemctl restart l3d-master; sleep 2; systemctl is-active l3d-master; ss -lntup | grep -E '10000|10001'; journalctl -u l3d-master -n 8 --no-pager; curl -s -m 5 http://127.0.0.1:10000/health; echo; curl -s -m 5 http://127.0.0.1:10000/api/stats"
```

期望日志含 `[master-server] listening on 0.0.0.0:10000` 与 `[tunnel-relay] TCP :10001, UDP pool 27015-27030 (16 free)`。

### 8. 公网隧道端到端验收

从**本机**（走真实公网）跑脚本，验证 TCP 注册 + UDP 往返：

```powershell
node .trae/skills/l3d-master-deploy/scripts/tunnel_e2e_check.mjs 8.138.99.96 10001
```

期望最后一行 `✅ 公网链路完整`。若失败，见下方排错。

### 9. 清理临时文件

```powershell
& $SSH -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KH root@8.138.99.96 "rm -f /root/*.new"
```

## 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `Host key verification failed` | 没带 `UserKnownHostsFile` | 用上面的 SSH 调用约定 |
| `Permission denied (publickey)` | 公钥未在服务器 `authorized_keys` | 让用户在服务器补公钥；**不要**改用密码 |
| `sshd.service not found` | Ubuntu 服务名是 `ssh` | `systemctl restart ssh` |
| 10001 未监听 | 线上是旧 `server.js`（中继未随进程启动） | 确认 `server.js` 已含 `startTunnelRelay` 且传了它 |
| UDP 往返失败 | 防火墙未放行 | 阿里云控制台放行 TCP `10001` + UDP `27015/27030` |
| hash 不一致 | 上传/替换不完整 | 重做第 4~6 步，别重启 |
| 服务起不来 | 语法错 / 端口占用 | `journalctl -u l3d-master -n 50 --no-pager` |

## 回滚

服务器上留有带时间戳的 `.bak`：

```bash
cd /opt/l3d/master-server/src
ls -l tunnel_relay.js.bak.*          # 选一个
cp -f tunnel_relay.js.bak.<时间戳> tunnel_relay.js
systemctl restart l3d-master
```

## 边界（不要做）

- 不要用密码登录（已配置密钥免密）；**不要**用阿里云控制台「重置实例密码」，它会把 `PasswordAuthentication` 强改回 `yes`
- 不要在服务器上跑 `npm test`（测试是本地跑）
- 不要改端口/服务名；契约见 `互联网联机模式策划方案.md` §3.8 与 `master-server/DEPLOY.md`
