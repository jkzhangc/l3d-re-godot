---
name: project-status
description: Current project implementation status and what's been built so far
metadata:
  type: project
---

## 当前状态 (2026-07-30)

核心战斗循环已基本完整。A* 寻路系统今日全面重写完成。

### 本次更新 (2026-07-30) — A* 寻路重写 + 关卡标准

**寻路系统重写**（`script/enemy/EnemyChaseState.gd`）：
- **四方向 A\*** + 曼哈顿启发式，路径全部轴对齐
- **DecorLayer 碰撞感知**：`_tile_has_collision()` 只挡有碰撞体的图块，纯装饰=透明
- **UpperLayer 跳过**：上层装饰（树冠等）不参与寻路
- **碰撞体推墙**：按敌人碰撞体半尺寸 + 4px 推开路径点
- **以撒风格移动**：`move_and_collide` 全速滑墙 ×6 + 卡住恢复 ×3
- **同类碰撞**：敌人正常物理碰撞，滑墙自然推开

**关卡场景标准**（`memory/scene-conventions.md`）：
- 标准模板：`res://scene/maps/突袭-第一关-开头安全屋-户外.tscn`（开局安全屋）
- 节点顺序：HUD → GameInit → GroundLayer → **DecorLayer**(y_sort) → **UpperLayer**(y_sort) → Menu → Camera2D
- 玩家/敌人必须是 DecorLayer 子节点
- UpperLayer 是上层装饰，渲染盖过角色，不参与寻路

### 下一步计划

用户正在画第一章地图。完成后：

1. **刷怪系统** — 丧尸波次生成，不同行走图变体
2. **投掷品（键5）** — 燃烧瓶、管状炸弹、胆汁罐
3. **倒地/救援** — 联机系统之前最后做

### 关键文件

| 文件 | 用途 |
|------|------|
| `script/enemy/EnemyChaseState.gd` | A* 寻路 + 滑墙移动 |
| `script/enemy.gd` | 敌人主脚本 |
| `memory/scene-conventions.md` | 关卡场景节点标准 |
