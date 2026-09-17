class_name ArrivalPoint extends Node2D

## ── 架构定位 ──
## 系统：关卡流程 ｜ 层：玩法（Node2D）
## 联机：不涉及
## 职责：目标场景中的入口锚点，按 ID 与 TeleportPoint.target_arrival_id 配对决定落点。
## 依赖：ArrivalResolver

## 地图入口点 — 传送到本场景时按 ID 放置玩家的位置。

@export var point_id: String = "" ## 与 TeleportPoint.target_arrival_id 对应的入口 ID
