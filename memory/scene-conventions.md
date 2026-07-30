---
name: scene-conventions
description: Standard scene node hierarchy for levels, layer ordering, and node placement rules
metadata:
  type: project
---

## 关卡场景标准

参考场景：`res://scene/maps/突袭-第一关-开头安全屋-户外.tscn`（**开局安全屋**，非终点安全屋）

### 节点层级顺序（从上到下 = 渲染从底到顶）

```
Test (Node2D)
├── HUD (CanvasLayer)
├── GameInit (Node)
├── GroundLayer (TileMapLayer)       ← 地面图块，最底层
├── DecorLayer (TileMapLayer)        ← 墙壁/装饰/障碍物，y_sort_enabled=true
│   ├── PlayerSpawn (Node2D)         ← 玩家出生点
│   │   └── Player (...)             ← 玩家节点实例
│   └── [Enemy...]                   ← 敌人节点（运行时生成/放置）
├── UpperLayer (TileMapLayer)        ← 上层装饰（树冠/屋檐等），y_sort_enabled=true，盖过角色
├── Menu (...)
└── Camera2D
```

### 关键规则

1. **GroundLayer**：地面图块，不参与 y_sort。TileSet 引用 `街道A5.tres`
2. **DecorLayer**：墙壁/障碍物/装饰，**y_sort_enabled=true**。TileSet 引用 `街道B.tres`。玩家和敌人必须是此节点的子节点（y_sort 配合实现正确的前后遮挡）
3. **UpperLayer**：上层装饰（如树冠、屋顶前沿），**y_sort_enabled=true**，渲染在角色之上。**不参与 A\* 寻路**（EnemyChaseState 已跳过名为 "upper" 的层）
4. **玩家出生点**：`DecorLayer/PlayerSpawn`，position 在场景中设置
5. 后续关卡均以此为模板

### 寻路层识别规则

EnemyChaseState 按 TileMapLayer 节点名识别：
- 名含 `"upper"` → 跳过（不参与寻路）
- 名含 `"wall"` → 始终阻挡
- 名含 `"decor"` → 检查 TileData 碰撞体，有碰撞才阻挡
- 名含 `"ground"` 或 `"floor"` → 可行走
