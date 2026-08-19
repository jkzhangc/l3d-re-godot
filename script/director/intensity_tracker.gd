extends Node
## 紧张度计算器 — 根据玩家状态评估当前压力 0.0~1.0

# ── 权重配置 ──
const HP_WEIGHT: float = 0.30
const AMMO_WEIGHT: float = 0.20
const PROXIMITY_WEIGHT: float = 0.15
const PROGRESS_WEIGHT: float = 0.15
const COMBAT_WEIGHT: float = 0.20

# ── 参数 ──
const SAFE_RADIUS: float = 300.0   ## 敌人接近度安全半径（px）
const SMOOTH_SPEED: float = 2.0    ## 紧张度平滑过渡速度

var _current_intensity: float = 0.0
var _raw_intensity: float = 0.0

## 每帧调用，返回平滑后的紧张度
func evaluate(player: Node2D, delta: float) -> float:
	var hp_factor: float = _calc_hp_factor(player)
	var ammo_factor: float = _calc_ammo_factor(player)
	var proximity_factor: float = _calc_proximity_factor(player)
	var progress_factor: float = _calc_progress_factor(player)
	var combat_factor: float = _calc_combat_factor()

	_raw_intensity = clampf(
		hp_factor * HP_WEIGHT +
		ammo_factor * AMMO_WEIGHT +
		proximity_factor * PROXIMITY_WEIGHT +
		progress_factor * PROGRESS_WEIGHT +
		combat_factor * COMBAT_WEIGHT,
		0.0, 1.0
	)

	# 平滑过渡
	_current_intensity = lerpf(_current_intensity, _raw_intensity, delta * SMOOTH_SPEED)
	return _current_intensity


## 获取原始（未平滑）紧张度
func get_raw_intensity() -> float:
	return _raw_intensity


## 获取平滑后的紧张度
func get_intensity() -> float:
	return _current_intensity


# ═══════════════════════════════════════
# HP 因子（权重 30%）
# 低血量时急剧升高：factor = (1 - hp_ratio)^2
# ═══════════════════════════════════════
func _calc_hp_factor(player: Node2D) -> float:
	if not player:
		return 0.0
	var hp_ratio: float = 0.0
	if player.has_method("get_weapon_data"):
		var max_hp: float = player.get("max_hp") if player.get("max_hp") else 200.0
		var current_hp: float = player.get("current_hp") if player.get("current_hp") != null else max_hp
		if max_hp > 0.0:
			hp_ratio = current_hp / max_hp
	return (1.0 - hp_ratio) * (1.0 - hp_ratio)


# ═══════════════════════════════════════
# 弹药因子（权重 20%）
# 取主武器+副武器平均弹药比例，弹药越少越紧张
# ═══════════════════════════════════════
func _calc_ammo_factor(player: Node2D) -> float:
	var state: PlayerState = Players.get_state_for_entity(player)
	if not state:
		return 0.0
	var ammo_ratios: Array[float] = []
	var count: int = 0

	for slot: String in ["primary", "secondary"]:
		var wd: WeaponData = state.equipment.get(slot) as WeaponData
		if not wd:
			continue
		var ratio: float = 1.0
		if wd.is_ranged and wd.magazine_capacity > 0:
			# 弹药比例 = (弹夹 + 备弹) / (弹夹容量 * 2)
			var mag_current: int = state.get_magazine_ammo(wd.item_id)
			var reserve: int = state.count_ammo_item(wd.ammo_item_id)
			ratio = float(mag_current + reserve) / float(wd.magazine_capacity * 2)
			ratio = clampf(ratio, 0.0, 1.0)
		ammo_ratios.append(ratio)
		count += 1

	if count == 0:
		return 0.0  # 没有远程武器，不产生弹药压力
	var avg: float = 0.0
	for r: float in ammo_ratios:
		avg += r
	avg /= float(count)
	return 1.0 - avg


# ═══════════════════════════════════════
# 敌人接近度因子（权重 15%）
# 最近 5 个敌人的平均距离 / SAFE_RADIUS
# ═══════════════════════════════════════
func _calc_proximity_factor(player: Node2D) -> float:
	if not player:
		return 0.0
	var tree: SceneTree = player.get_tree()
	if not tree:
		return 0.0

	var enemies: Array = tree.get_nodes_in_group("enemy")
	if enemies.is_empty():
		return 0.0

	# 收集存活敌人的距离
	var distances: Array[float] = []
	for e: Node2D in enemies:
		if not is_instance_valid(e):
			continue
		if e.has_method("get_weapon_data"):
			continue  # 跳过玩家
		# 跳过死亡/濒死敌人
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		var dist: float = player.global_position.distance_to(e.global_position)
		distances.append(dist)

	if distances.is_empty():
		return 0.0

	# 排序取最近 5 个
	distances.sort()
	var sample_count: int = mini(5, distances.size())
	var sum: float = 0.0
	for i: int in range(sample_count):
		sum += distances[i]
	var avg_dist: float = sum / float(sample_count)

	return clampf(1.0 - avg_dist / SAFE_RADIUS, 0.0, 1.0)


# ═══════════════════════════════════════
# 关卡进度因子（权重 15%）
# 越接近关卡终点越紧张
# ═══════════════════════════════════════
var _progress_override: float = -1.0  ## 外部可设（-1=自动计算）

func _calc_progress_factor(_player: Node2D) -> float:
	if _progress_override >= 0.0:
		return _progress_override
	# 当前版本简单返回 0.3 作为基础值
	# Phase 3 引入 EventTrigger 后可计算真实进度
	return 0.3


## 由外部设置关卡进度（如 EventTrigger）
func set_progress(ratio: float) -> void:
	_progress_override = clampf(ratio, 0.0, 1.0)


# ═══════════════════════════════════════
# 战斗状态因子（权重 20%）
# 战斗中 = 0.8，脱战 = 0.2
# ═══════════════════════════════════════
var in_combat: bool = false

func _calc_combat_factor() -> float:
	return 0.8 if in_combat else 0.2


## 由外部设置战斗状态
func set_combat(active: bool) -> void:
	in_combat = active
