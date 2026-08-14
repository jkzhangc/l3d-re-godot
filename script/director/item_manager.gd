extends Node
## 物品投放管理器 — 根据玩家状态自动投放补给
##
## 定期检查 HP/弹药，在需要时选择投放位置和物品类型

# ═══════════════════════════════════════
# 参数
# ═══════════════════════════════════════
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
	var ammo_ratio: float = _get_ammo_ratio()
	var has_secondary: bool = _has_secondary_weapon()

	var item: String = ""
	var probability: float = 0.0

	if hp_ratio < hp_pills_threshold and not _has_healing_item():
		item = "药品"
		probability = 0.4
	elif hp_ratio < hp_spray_threshold and not _has_healing_item():
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


# ═══════════════════════════════════════
# 查询
# ═══════════════════════════════════════

func _get_hp_ratio(player: Node2D) -> float:
	var max_hp: float = player.get("max_hp") if player.get("max_hp") != null else 200.0
	var current_hp: float = player.get("current_hp") if player.get("current_hp") != null else max_hp
	if max_hp <= 0.0:
		return 1.0
	return current_hp / max_hp


func _get_ammo_ratio() -> float:
	var ratios: Array[float] = []
	for slot: String in ["primary", "secondary"]:
		var wd: WeaponData = Global.equipment.get(slot) as WeaponData
		if not wd or not wd.is_ranged:
			continue
		var ratio: float = 1.0
		if wd.magazine_capacity > 0:
			var mag_current: int = Global.weapon_magazines.get(wd.item_id, 0)
			var reserve: int = Global.count_ammo_item(wd.ammo_item_id)
			ratio = float(mag_current + reserve) / float(wd.magazine_capacity * 2)
			ratio = clampf(ratio, 0.0, 1.0)
		ratios.append(ratio)
	if ratios.is_empty():
		return 1.0
	var sum: float = 0.0
	for r: float in ratios:
		sum += r
	return sum / float(ratios.size())


func _has_healing_item() -> bool:
	return Global.healing_item != null


func _has_secondary_weapon() -> bool:
	var wd: WeaponData = Global.equipment.get("secondary") as WeaponData
	return wd != null


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
	var tree: SceneTree = get_tree()
	if not tree:
		return null
	return _find_player_recursive(tree.root)


func _find_player_recursive(node: Node) -> Node2D:
	if node is CharacterBody2D and node.has_method("get_weapon_data"):
		return node as Node2D
	for child: Node in node.get_children():
		var found: Node2D = _find_player_recursive(child)
		if found:
			return found
	return null
