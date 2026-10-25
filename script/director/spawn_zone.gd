@tool
class_name SpawnZone
extends Node2D

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node2D, @tool）
## 联机：仅单机/Host
## 职责：矩形生成区域：区域内随机取位、按上限限制数量，并可驱动环境随机构刷计时。
## 依赖：Director、SpawnManager

## 敌人生成区域 — 敌人从此矩形区域内随机出现，并受区域上限限制。

enum SpawnType { COMMON = 0, SPECIAL = 1, BOTH = 2 }

@export_group("区域基础")
@export var zone_size: Vector2 = Vector2(64, 64)      ## 区域大小（像素），默认 64×64，编辑器中会直接显示矩形边框
@export var zone_type: int = SpawnType.COMMON          ## 区域类型：普通 / 特感 / 两者兼容
@export var enabled: bool = true                       ## 是否启用此区域的刷怪逻辑

@export_group("刷怪上限")
@export var max_spawns: int = 5                        ## 该区域最多同时存在多少只普通丧尸
@export var ambient_budget: int = 6                    ## 该区域保底数量：低于此值时会补齐

@export_group("区域补齐")
@export var ambient_min_player_dist: float = 180.0     ## 只在离玩家至少该距离之外补齐，避免玩家脸上直接刷怪
@export var ambient_spawn_interval_min: float = 8.0   ## 区域补齐最短间隔
@export var ambient_spawn_interval_max: float = 16.0  ## 区域补齐最长间隔
@export var ambient_wander_speed: float = 28.0        ## 空闲巡逻时的移动速度

@export_group("生成朝向")
@export var facing: int = 0                            ## 生成后初始朝向（0=下,1=左,2=右,3=上），random_facing=false 时生效
@export var random_facing: bool = false                ## 是否随机朝向

@export_group("状态")
@export var allow_idle_wander: bool = true             ## 未发现玩家时是否允许随机漫游

var _ambient_timer: float = 0.0

func _ready() -> void:
	if not Engine.is_editor_hint():
		queue_redraw()

func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var half: Vector2 = zone_size * 0.5
	var rect: Rect2 = Rect2(-half, zone_size)
	draw_rect(rect, Color(0.2, 0.8, 1.0, 0.18), false, 2.0)
	draw_rect(rect, Color(0.2, 0.8, 1.0, 0.9), true, 1.0)
	var center: Vector2 = Vector2.ZERO
	draw_line(center + Vector2(-8, 0), center + Vector2(8, 0), Color(1.0, 1.0, 1.0, 0.9), 1.0)
	draw_line(center + Vector2(0, -8), center + Vector2(0, 8), Color(1.0, 1.0, 1.0, 0.9), 1.0)

## 返回此区域内的一个随机位置（全局坐标）
func get_random_position() -> Vector2:
	var hw: float = zone_size.x / 2.0
	var hh: float = zone_size.y / 2.0
	return global_position + Vector2(
		randf_range(-hw, hw),
		randf_range(-hh, hh)
	)


## ★分散取点（2026-10-24 用户需求「不要都堆在一块，起码整个区域平均分布」）：
## 在区域里随机采 `samples` 个点，用 `point_ok` 过滤（可行走、未占用等），
## 再取"离最近一只已有敌人最远"的那个候选（最大最小距离采样，近似蓝噪声分布）。
## `avoid` = 区域内已有敌人的位置；为空时退化为普通随机点。
## 找不到合格点返回 Vector2.ZERO —— 调用方应跳过而不是硬塞。
func pick_spread_position(point_ok: Callable = Callable(), avoid: Array = [],
		samples: int = 20) -> Vector2:
	var half: Vector2 = zone_size * 0.5
	var best: Vector2 = Vector2.ZERO
	var best_score: float = -INF
	for _i: int in range(maxi(samples, 4)):
		var p: Vector2 = global_position + Vector2(
			randf_range(-half.x, half.x), randf_range(-half.y, half.y))
		if point_ok.is_valid() and not bool(point_ok.call(p)):
			continue
		var nearest: float = INF
		for a: Variant in avoid:
			if a is Vector2:
				nearest = minf(nearest, p.distance_to(a))
		## 抖动 0~60px：否则每一批都会贴在同一个"最空点"上，反而形成固定堆。
		var score: float = (9999.0 if nearest == INF else nearest) + randf() * 60.0
		if score > best_score:
			best_score = score
			best = p
	return best

func get_ambient_interval() -> float:
	return randf_range(ambient_spawn_interval_min, ambient_spawn_interval_max)

func get_zone_radius() -> float:
	return maxf(zone_size.x, zone_size.y) * 0.75

func reset_ambient_timer() -> void:
	_ambient_timer = get_ambient_interval()

func poll_ambient_timer(delta: float) -> bool:
	_ambient_timer -= delta
	if _ambient_timer <= 0.0:
		_ambient_timer = get_ambient_interval()
		return true
	return false
