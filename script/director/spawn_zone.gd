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

@export_group("定点特感（独立于导演特感池）")
## ★2026-11-02 用户需求：作者指定「这个区域刷这只特感」。
## 与导演的常规特感通道**完全独立** —— 不参与 special_pool 抽选，不吃
## special_max_alive / 紧张度门槛 / 尸潮阶段，只按本区域自己的间隔、概率、次数走。
## 典型用法：河里的区域定时刷一只两栖的ハンターγ（记得关掉 special_require_walkable）。
@export var special_enabled: bool = false
## 要生成的特感资源（tres/specials/*.tres）。留空 = 不生成。
@export var special_data: SpecialEnemyData = null
## 两次尝试之间的最短秒数（玩家进入触发距离后才开始走表）。
@export var special_interval_min: float = 20.0
## 两次尝试之间的最长秒数。
@export var special_interval_max: float = 40.0
## 每次计时到点时的生成概率（0~1）。失败只重置计时，不消耗次数。
@export_range(0.0, 1.0, 0.01) var special_chance: float = 1.0
## 本区域**累计最多**生成几只；0 = 不限。默认 1 = 「生成一只后永不再生成」。
@export var special_max_count: int = 1
## 本区域半径内同时最多存活几只（0 = 不限）。达到上限时暂停计时。
@export var special_max_alive: int = 1
## 玩家进入这个距离后才开始走表；0 = 常驻计时。
## 默认 900 而不是 0：否则开场在远处就会把「仅一只」的名额刷掉，玩家走到河边时怪早没了。
@export var special_activate_distance: float = 900.0
## 生成点离最近玩家至少多少像素（防止贴脸刷）。
@export var special_min_player_dist: float = 200.0
## 是否要求生成点在屏幕外（推荐 true，避免在玩家眼前凭空出现）。
@export var special_require_offscreen: bool = true
## 是否要求落点可行走。**河里/水面生成必须关掉**（水域图块通常带碰撞，
## 普通丧尸走不进去，但两栖特感靠 water_walk_enabled 自己处理）。
@export var special_require_walkable: bool = true
## 是否要求落点在水面图块上（两栖特感专用）。开启时自动忽略可行走判定。
@export var special_require_water: bool = false
## 生成朝向：-1 = 自动朝向最近玩家（推荐）；0=下 1=左 2=右 3=上。
@export var special_facing: int = -1

@export_group("状态")
@export var allow_idle_wander: bool = true             ## 未发现玩家时是否允许随机漫游

var _ambient_timer: float = 0.0
## ── 定点特感运行期状态（不导出）──
var _special_timer: float = 0.0
var _special_timer_started: bool = false
var _special_spawned: int = 0                          ## 本区域累计生成数

func _ready() -> void:
	if not Engine.is_editor_hint():
		queue_redraw()

func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var half: Vector2 = zone_size * 0.5
	var rect: Rect2 = Rect2(-half, zone_size)
	## 定点特感区域用紫色区分（作者一眼能看出这圈是"刷指定特感"而不是普通补位区）。
	var edge: Color = Color(0.78, 0.45, 1.0, 0.9) if special_enabled else Color(0.2, 0.8, 1.0, 0.9)
	draw_rect(rect, Color(edge.r, edge.g, edge.b, 0.18), false, 2.0)
	draw_rect(rect, edge, true, 1.0)
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


# ── 定点特感（2026-11-02）──
## 计时只在「玩家已进入 special_activate_distance 且未达同屏上限」时由 Director 推动，
## 因此这里只做纯粹的表；是否允许生成由 can_spawn_special 判定。

func get_special_interval() -> float:
	var lo: float = maxf(minf(special_interval_min, special_interval_max), 0.0)
	var hi: float = maxf(special_interval_min, special_interval_max)
	return randf_range(lo, hi)


func reset_special_timer() -> void:
	_special_timer = get_special_interval()
	_special_timer_started = true


## 走一次特感计时。首次调用只初始化计时（保证「间隔」从本区域生效时开始算），
## 之后每帧扣 delta；到点返回 true 并由调用方重置（reset_special_timer）。
func poll_special_timer(delta: float) -> bool:
	if not _special_timer_started:
		reset_special_timer()
		return false
	_special_timer -= delta
	if _special_timer <= 0.0:
		reset_special_timer()
		return true
	return false


## 本区域是否还允许生成：开关/资源齐全 + 未达累计上限。
func can_spawn_special() -> bool:
	return special_enabled and special_data != null and not is_special_exhausted()


## 累计生成次数是否已达上限（special_max_count <= 0 表示不限）。
func is_special_exhausted() -> bool:
	return special_max_count > 0 and _special_spawned >= special_max_count


## 生成成功后记一次数（只由 Director 在 spawn_special_enemy 返回非空时调用）。
func note_special_spawned() -> void:
	_special_spawned += 1


func get_special_spawned() -> int:
	return _special_spawned


## 调试/用例用：当前定点特感状态快照。
func get_special_debug() -> Dictionary:
	return {
		"enabled": special_enabled,
		"id": String(special_data.id) if special_data != null else "",
		"spawned": _special_spawned,
		"max_count": special_max_count,
		"exhausted": is_special_exhausted(),
		"timer": _special_timer,
	}
