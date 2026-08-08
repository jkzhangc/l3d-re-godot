# 联机系统重写交接记录（2026-08-08）

## 当前决定

用户决定重新编写联机系统，后续实现由用户接手。本文件仅用于保存本轮调查和修改进度，便于回退或重写时参考。

## 本轮已提交的修改

- `591dfd1` — `fix network sync rate and hp hit effect routing`
  - 敌人批量同步频率改为 40Hz（`ENEMY_SYNC_INTERVAL = 0.025`）。
  - 增加玩家 HP/玩家受击特效同步 RPC。
  - 增加敌人 HP/死亡结果暂存与延迟应用。
- `58d7afc` — `fix host player authority and combat hp effects`
  - Host 模拟所有玩家；只有 Client 上的远程玩家使用 puppet 模式。
  - 调整玩家 HP 广播，避免远程玩家 HP 覆盖本地 `Global.player_hp`。
  - 补充敌人攻击、子弹和近战攻击的网络伤害参数。
- `ad123b2` — `resolve weapon effect paths for network hits`
  - `WeaponData` 支持 `PackedScene` 和字符串特效路径，并自动解析 `res://anim/`。
- `6b7fae9` — `add enemy player hit effect`
  - 增加敌人命中玩家的特效同步 RPC 路径。
- `9797447` — `use enemy hit effect for player damage`
  - 敌人攻击玩家时改用 `enemy.hit_effect_anim`，不再误用攻击动画字段。

## 已确认的检查结果

- Godot 4.6.3 `--headless --editor --quit --check-only` 在最后一次检查中通过。
- 仍存在项目原有的编辑器警告/错误输出（证书仓库、GradientLabel 编辑器上下文绝对路径、编辑器设置写入、无效 UID 等），未作为本轮联机修改处理。

## 之前双屏测试中已知现象

- 敌人死亡同步曾出现 Client 端个别敌人停留在循环攻击动画；已通过死亡结果暂存/可靠同步相关改动处理，但未进行新的完整回归测试。
- 弹夹同步基本正常；备弹和其他联机状态仍需重写系统时重新设计。
- 本轮用户最后提出的待验证问题：Host 敌人命中玩家特效、双方玩家武器命中敌人特效、Client 玩家发现、玩家 HP 权威与同步。

## 重写时重点注意

1. 明确单一权威端（建议 Host/服务器）负责玩家和敌人的伤害、HP、死亡判定。
2. 玩家节点的 authority、碰撞体和 hurtbox 初始化必须区分“服务器模拟实体”和“客户端纯视觉实体”。
3. HP 同步应带稳定的玩家标识（如 peer ID），不要依赖可能冲突的节点名或共享全局变量。
4. 伤害事件、命中特效、死亡事件最好分离；特效只作为事件广播，不要依赖 HP 差值推断。
5. 敌人状态同步与事件同步分开：位置/动画可用不可靠高频同步，伤害/死亡/生成使用可靠消息。
6. 每个独立改动单独提交 Git；编辑 GDScript 只使用小范围补丁，避免整文件重写破坏编码或注释。

## 工作区注意

保存本记录时，工作区已有其他未提交改动和未跟踪文件。它们属于用户原有进度，本次没有修改、暂存或提交：

- `MEMORY.md`、`README.md`
- `script/lobby.gd`
- `script/player/PlayerReloadState.gd`
- `.claude/`
- `memory/project-audit-2026-08-08.md`
- `联机系统改进方案-2026-08-08.md`
- 以及工作区显示的删除项

