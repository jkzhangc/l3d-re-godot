class_name SpawnPoint extends Node2D

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node2D）
## 联机：仅单机/Host
## 职责：地图上的敌人出生点标记，可区分普通/特殊/通用并指定初始朝向。
## 依赖：Director._get_valid_spawn_points

## 敌人生成点 — 放置在关卡场景中标记敌人生成位置

enum SpawnType { COMMON = 0, SPECIAL = 1, BOTH = 2 }

@export var point_type: int = SpawnType.COMMON
@export var facing: int = 0          ## 生成后初始朝向（0=下,1=左,2=右,3=上）
@export var priority: float = 1.0    ## 权重（1.0=标准，>1 优先使用，<1 降低使用）
@export var random_facing: bool = false  ## true=随机朝向, false=使用上面的 facing
@export var enabled: bool = true     ## 是否启用（剧本事件可动态开关）
