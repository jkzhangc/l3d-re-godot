extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node，子模块）
## 联机：仅单机/Host
## 职责：补给投放决策：按玩家血量/弹药紧张程度挑选物品与投放点。
## 依赖：Director、PlayerState

## 根据玩家资源状态决定物品投放候选；联机只在 Host 侧运行并同步结果。
## 物品投放管理器 — 根据玩家状态自动投放补给
##
## 定期检查 HP/弹药，在需要时选择投放位置和物品类型

# ═══════════════════════════════════════
# 参数
# ═══════════════════════════════════════
const RANDOM_PICKUP_SCENE := preload("res://object/random_pickup.tscn")
const WEAPON_PICKUP_SCENE := preload("res://object/weapon_pickup.tscn")
const WEAPON_PICKUP_SCRIPT := preload("res://script/weapon_pickup.gd")
const ITEM_PICKUP_SCENE := preload("res://object/healing_pickup.tscn")

@export var check_interval: float = 10.0          ## 检查间隔（秒）
@export var fail_safe_cooldown: float = 180.0     ## 降级投放冷却（秒）

@export var hp_spray_threshold: float = 0.5      ## HP < 50% 触发急救喷雾投放
@export var hp_pills_threshold: float = 0.3       ## HP < 30% 触发药品投放
@export var ammo_threshold: float = 0.3           ## 弹药 < 30% 触发弹药投放
@export var no_secondary_threshold: float = 0.8   ## 无副武器时投放概率（80%）

@export var spawn_distance_min: float = 200.0     ## 投放位置离玩家最小距离
@export var spawn_distance_max: float = 400.0     ## 投放位置离玩家最大距离

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var enabled: bool = true
var _check_timer: float = 0.0
var _last_fail_safe_msec: int = -999999
var _director: Node = null


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════
func setup(director_node: Node) -> void:
	_director = director_node


# ═══════════════════════════════════════
# 每帧由 director 调用
# ═══════════════════════════════════════
func update(delta: float, phase: StringName, alive_count: int) -> void:
	if not enabled or not _director:
		return

	# 尸潮中不投物品
	if phase == &"peak":
		return

	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = check_interval

	var player: Node2D = _find_player()
	if not player:
		return

	_evaluate_and_spawn(player)


# ═══════════════════════════════════════
# 决策逻辑
# ═══════════════════════════════════════

func _evaluate_and_spawn(player: Node2D) -> void:
	var hp_ratio: float = _get_hp_ratio(player)
	var ammo_ratio: float = _get_ammo_ratio(player)
	var has_secondary: bool = _has_secondary_weapon(player)

	var item: String = ""
	var probability: float = 0.0

	if hp_ratio < hp_pills_threshold and not _has_healing_item(player):
		item = "药品"
		probability = 0.4
	elif hp_ratio < hp_spray_threshold and not _has_healing_item(player):
		item = "急救喷雾"
		probability = 0.6
	elif ammo_ratio < ammo_threshold:
		item = "弹药堆"
		probability = 0.7
	elif not has_secondary:
		item = "副武器"
		probability = no_secondary_threshold

	if item.is_empty():
		return

	if randf() > probability:
		return

	print("[ItemManager] 决策投放: %s (HP=%.0f%% Ammo=%.0f%%)" % [item, hp_ratio * 100, ammo_ratio * 100])

	var pos: Vector2 = _find_spawn_pos(player)
	if pos == Vector2.ZERO:
		print("[ItemManager] 未找到合适的投放位置")
		return

	# 目前投放逻辑：在玩家前方生成提示标记
	# 具体拾取物实例化逻辑等物品系统完善后再接
	print("[ItemManager] 投放位置: (%d, %d)" % [int(pos.x), int(pos.y)])
	_spawn_pickup(item, pos)


## 实际生成地面拾取物（此前只 print 不实例化——这就是"导演投放没生效"的原因）。
## 配置了掉落池（DirectorConfig.drop_pool）→ 生成随机掉落物，从池里按权重抽武器/物品；
## 未配置 → 按决策类别直接投放对应资源（喷雾/药品/弹药/副武器）。
func _spawn_pickup(category: String, pos: Vector2) -> void:
	var scene := _director.get_tree().current_scene if _director.get_tree() else null
	if not scene:
		return
	var parent: Node = scene.find_child("GroundLayer", true, false)
	if not parent:
		parent = scene

	## freed 对象 != null 恒真（经典陷阱），必须 is_instance_valid 判悬空
	var cfg_raw: Variant = _director.get("current_config")
	var cfg: Node = cfg_raw if is_instance_valid(cfg_raw) else null
	var pool: Resource = cfg.get("drop_pool") if cfg != null and cfg.get("drop_pool") != null else null

	var spawned: Node2D = null
	if pool != null:
		spawned = RANDOM_PICKUP_SCENE.instantiate()
		spawned.pool = pool
	else:
		var res: Resource = _resolve_category_resource(category, pos)
		if res == null:
			print("[ItemManager] 类别 %s 无可投放资源" % category)
			return
		if res is WeaponData:
			spawned = WEAPON_PICKUP_SCENE.instantiate()
			# 地面显示参数统一走 WeaponData（2026-09-13：完全按武器数据来）
			WEAPON_PICKUP_SCRIPT.apply_weapon_ground_display(spawned, res)
		else:
			spawned = ITEM_PICKUP_SCENE.instantiate()
			spawned.item = res

	parent.add_child(spawned)
	spawned.global_position = pos
	print("[ItemManager] 已投放 %s @ (%d, %d)" % [category, int(pos.x), int(pos.y)])


## 未配置掉落池时的类别 → 资源映射。
func _resolve_category_resource(category: String, player_pos: Vector2) -> Resource:
	match category:
		"急救喷雾":
			return load("res://object/item_first_aid_spray.tres")
		"药品":
			return load("res://object/item_pills.tres")
		"弹药堆":
			# 找当前主武器对应的弹药资源
			var player: Node2D = _find_player()
			var state: PlayerState = Players.get_state_for_entity(player) if player else null
			if state:
				var wd: WeaponData = state.get_equipped_weapon("primary")
				if wd and not wd.ammo_item_id.is_empty():
					var direct := "res://object/item_%s.tres" % wd.ammo_item_id
					var derived := "res://object/item_%s_ammo.tres" % wd.ammo_item_id.trim_prefix("ammo_")
					if ResourceLoader.exists(derived):
						return load(derived)
					if ResourceLoader.exists(direct):
						return load(direct)
			return null
		"副武器":
			return load("res://object/weapon_pistol.tres")
		_:
			return null


# ═══════════════════════════════════════
# 查询
# ═══════════════════════════════════════

func _get_hp_ratio(player: Node2D) -> float:
	var max_hp: float = player.get("max_hp") if player.get("max_hp") != null else 200.0
	var current_hp: float = player.get("current_hp") if player.get("current_hp") != null else max_hp
	if max_hp <= 0.0:
		return 1.0
	return current_hp / max_hp


func _get_ammo_ratio(player: Node2D) -> float:
	var state: PlayerState = Players.get_state_for_entity(player)
	if not state:
		return 1.0
	var ratios: Array[float] = []
	for slot: String in ["primary", "secondary"]:
		var wd: WeaponData = state.equipment.get(slot) as WeaponData
		if not wd or not wd.is_ranged:
			continue
		var ratio: float = 1.0
		if wd.magazine_capacity > 0:
			var mag_current: int = state.get_magazine_ammo(wd.item_id)
			var reserve: int = state.count_ammo_item(wd.ammo_item_id)
			ratio = float(mag_current + reserve) / float(wd.magazine_capacity * 2)
			ratio = clampf(ratio, 0.0, 1.0)
		ratios.append(ratio)
	if ratios.is_empty():
		return 1.0
	var sum: float = 0.0
	for r: float in ratios:
		sum += r
	return sum / float(ratios.size())


func _has_healing_item(player: Node2D) -> bool:
	var state: PlayerState = Players.get_state_for_entity(player)
	return state != null and state.healing_item != null


func _has_secondary_weapon(player: Node2D) -> bool:
	var state: PlayerState = Players.get_state_for_entity(player)
	return state != null and state.get_equipped_weapon("secondary") != null


# ═══════════════════════════════════════
# 位置查找
# ═══════════════════════════════════════

func _find_spawn_pos(player: Node2D) -> Vector2:
	## 在玩家前方找可行走位置
	for _attempt: int in range(15):
		var angle: float = randf() * TAU
		var dist: float = randf_range(spawn_distance_min, spawn_distance_max)
		var pos: Vector2 = player.global_position + Vector2.RIGHT.rotated(angle) * dist
		pos += Vector2(randf_range(-24, 24), randf_range(-24, 24))
		if _director.has_method("_is_walkable") and _director._is_walkable(pos):
			return pos
	return Vector2.ZERO


func _find_player() -> Node2D:
	var players: Array[Node2D] = Players.all_entities()
	return players[0] if not players.is_empty() else null
