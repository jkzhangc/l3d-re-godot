class_name SpawnZone extends Node2D
## 敌人生成区域 — 敌人从此矩形区域内的随机位置出现

enum SpawnType { COMMON = 0, SPECIAL = 1, BOTH = 2 }

@export var zone_size: Vector2 = Vector2(128, 128)  ## 区域尺寸
@export var zone_type: int = SpawnType.COMMON
@export var max_spawns: int = 5                     ## 同时最多生成数
@export var facing: int = 0                          ## 生成朝向（0=下,1=左,2=右,3=上），random_facing=false 时生效
@export var random_facing: bool = false              ## true=随机朝向
@export var enabled: bool = true


## 返回此区域内的一个随机位置（全局坐标）
func get_random_position() -> Vector2:
	var hw: float = zone_size.x / 2.0
	var hh: float = zone_size.y / 2.0
	return global_position + Vector2(
		randf_range(-hw, hw),
		randf_range(-hh, hh)
	)
