extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node，子模块）
## 联机：仅单机/Host（Client 端 Director._process 早早退，本模块不运行）
## 职责：只统计队伍压力（血量/弹药/敌方贴近度/战斗状态/关卡进度）并输出 0~1 紧张度，不生成实体。
## 依赖：被 Director._process 调用

## 紧张度计算器 — 根据**全体存活玩家**的状态评估当前压力 0.0~1.0
##
## ★ 多玩家聚合口径（2026-09-24 定稿）：「取最吃紧的那位」。
## 每个压力因子各自求**全体玩家中的最大值**（最残血的 / 最缺弹的 / 被围得最紧的那位），
## 而不是取队伍平均值 —— 与 L4D 系列导演的体感一致：**队伍压力由最危险的那位决定**
## （有人红血且被围 → 整局升温、更早进尸潮、更早投补给）。
##
## 旧实现只读 `Director._find_player()`（= 座位 0 的主机）→ 主机满血蹲点时，
## 客户端残血被围也不会升温，导演节奏与真实战况脱节（与"刷怪只围绕主机"是同一族问题）。
## 单机下存活玩家集合只有 1 人 → 与旧行为**逐位等价**。

# ── 权重配置 ──
const HP_WEIGHT: float = 0.30
const AMMO_WEIGHT: float = 0.20
const PROXIMITY_WEIGHT: float = 0.15
const PROGRESS_WEIGHT: float = 0.15
const COMBAT_WEIGHT: float = 0.20

# ── 参数 ──
const SAFE_RADIUS: float = 300.0   ## 敌人接近度安全半径（px）
const SMOOTH_SPEED: float = 2.0    ## 紧张度平滑过渡速度
const PROXIMITY_SAMPLE: int = 5    ## 接近度采样：最近 N 个敌人的平均距离

var _current_intensity: float = 0.0
var _raw_intensity: float = 0.0

## 每帧调用。`players` = 全体存活玩家（Director 传 `spawn_reference_players()`，
## 单机只有一人）。返回平滑后的紧张度。
func evaluate(players: Array, delta: float) -> float:
	## 每个因子**各自**做存活过滤（见 `_living_players`）—— 这样单独调用任一因子
	## 也不会把濒死/已释放的玩家算进去（回归 harness 正是逐因子取证的）。
	var hp_factor: float = _calc_hp_factor(players)
	var ammo_factor: float = _calc_ammo_factor(players)
	var proximity_factor: float = _calc_proximity_factor(players)
	var progress_factor: float = _calc_progress_factor()
	var combat_factor: float = _calc_combat_factor()

	## 难度倍率（2026-09-16）：Global.difficulty_multipliers.director_intensity ——
	## 同样的战况在高难度下把紧张度推得更高（更早进入尸潮）。乘在求和之后、clamp 之前。
	var raw: float = (
		hp_factor * HP_WEIGHT +
		ammo_factor * AMMO_WEIGHT +
		proximity_factor * PROXIMITY_WEIGHT +
		progress_factor * PROGRESS_WEIGHT +
		combat_factor * COMBAT_WEIGHT
	) * Global.difficulty_director_intensity()
	_raw_intensity = clampf(raw, 0.0, 1.0)

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
# 内部 — 玩家集合
# ═══════════════════════════════════════

## 过滤出「有效且存活」的玩家。Director 传入的集合通常已过滤，这里是二次防御：
## 本函数跑在每帧热路径上，一次 freed-object 判空失误就会让紧张度整帧停更。
## 注意顺序必须是**先 `is_instance_valid` 后 `as`** —— 对已释放对象做 `as` 会抛错
## 并静默中止整个函数（freed-cast 家族）。
func _living_players(players: Array) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for value: Variant in players:
		if not is_instance_valid(value):
			continue
		var p: Node2D = value as Node2D
		if p == null:
			continue
		if p.get("_is_dying") == true or p.get("_is_dead") == true:
			continue
		out.append(p)
	return out


# ═══════════════════════════════════════
# HP 因子（权重 30%）— 取最残血者的压力
# 单人压力 = (1 - hp_ratio)^2，低血量时急剧升高
# ═══════════════════════════════════════
func _calc_hp_factor(players: Array) -> float:
	var worst: float = 0.0
	for p: Node2D in _living_players(players):
		var ratio: float = _hp_ratio(p)
		var stress: float = (1.0 - ratio) * (1.0 - ratio)
		if stress > worst:
			worst = stress
	return worst


## 单个玩家的血量比例（0~1）。读不到字段（非玩家对象 / 资源尚未就绪）按满血算 ——
## 宁可不产生压力，也不要把导演推向"无来源的尸潮"。
func _hp_ratio(p: Node2D) -> float:
	var max_value: Variant = p.get("max_hp")
	if max_value == null:
		return 1.0
	var max_hp: float = float(max_value)
	if max_hp <= 0.0:
		return 1.0
	var current_value: Variant = p.get("current_hp")
	var current_hp: float = max_hp if current_value == null else float(current_value)
	return clampf(current_hp / max_hp, 0.0, 1.0)


# ═══════════════════════════════════════
# 弹药因子（权重 20%）— 取最缺弹者的压力
# 单人压力 = 1 - 主/副武器弹药比例均值
# ═══════════════════════════════════════
func _calc_ammo_factor(players: Array) -> float:
	var worst: float = 0.0
	for p: Node2D in _living_players(players):
		var stress: float = _ammo_stress(p)
		if stress > worst:
			worst = stress
	return worst


## 单个玩家的弹药压力 = 1 - (主/副武器弹药比例的均值)。
## 没有远程武器（全近战）→ 0，不产生弹药压力。
func _ammo_stress(p: Node2D) -> float:
	var state: PlayerState = Players.get_state_for_entity(p)
	if state == null:
		return 0.0
	var avg: float = 0.0
	var count: int = 0

	for slot: String in ["primary", "secondary"]:
		var wd_value: Variant = state.equipment.get(slot)
		var wd: WeaponData = (wd_value as WeaponData) if is_instance_valid(wd_value) else null
		if wd == null:
			continue
		var ratio: float = 1.0
		if wd.is_ranged and wd.magazine_capacity > 0:
			# 弹药比例 = (弹夹 + 备弹) / (弹夹容量 * 2)
			var mag_current: int = state.get_magazine_ammo(wd.item_id)
			var reserve: int = state.count_ammo_item(wd.ammo_item_id)
			ratio = float(mag_current + reserve) / float(wd.magazine_capacity * 2)
			ratio = clampf(ratio, 0.0, 1.0)
		avg += ratio
		count += 1

	if count == 0:
		return 0.0  # 没有远程武器，不产生弹药压力
	return 1.0 - avg / float(count)


# ═══════════════════════════════════════
# 敌人接近度因子（权重 15%）— 取被围得最紧者的压力
# 单人压力 = 1 - (最近 5 敌平均距离 / SAFE_RADIUS)
# ═══════════════════════════════════════
func _calc_proximity_factor(players: Array) -> float:
	var list: Array[Node2D] = _living_players(players)
	if list.is_empty():
		return 0.0
	var positions: Array[Vector2] = _live_enemy_positions()
	if positions.is_empty():
		return 0.0
	var worst: float = 0.0
	for p: Node2D in list:
		var stress: float = _proximity_stress(p.global_position, positions)
		if stress > worst:
			worst = stress
	return worst


## 存活敌人的位置 —— 一次收集、供全体玩家复用（避免每个玩家各扫一遍 enemy 组）。
func _live_enemy_positions() -> Array[Vector2]:
	var out: Array[Vector2] = []
	var tree: SceneTree = get_tree()
	if tree == null:
		return out
	var enemies: Array = tree.get_nodes_in_group("enemy")
	for e: Node2D in enemies:
		if not is_instance_valid(e):
			continue
		if e.has_method("get_weapon_data"):
			continue  # 玩家也在 enemy 组里（历史约定）→ 跳过
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		out.append(e.global_position)
	return out


## 单点的逼近压力 = 1 - (最近 PROXIMITY_SAMPLE 个敌人的平均距离 / SAFE_RADIUS)
func _proximity_stress(from: Vector2, positions: Array[Vector2]) -> float:
	var distances: Array[float] = []
	distances.resize(positions.size())
	for i: int in range(positions.size()):
		distances[i] = from.distance_to(positions[i])
	distances.sort()
	var sample_count: int = mini(PROXIMITY_SAMPLE, distances.size())
	var sum: float = 0.0
	for i: int in range(sample_count):
		sum += distances[i]
	var avg_dist: float = sum / float(sample_count)
	return clampf(1.0 - avg_dist / SAFE_RADIUS, 0.0, 1.0)


# ═══════════════════════════════════════
# 关卡进度因子（权重 15%）— 全局量，与玩家数无关
# 越接近关卡终点越紧张
# ═══════════════════════════════════════
var _progress_override: float = -1.0  ## 外部可设（-1=自动计算）

func _calc_progress_factor() -> float:
	if _progress_override >= 0.0:
		return _progress_override
	# 当前版本简单返回 0.3 作为基础值
	# Phase 3 引入 EventTrigger 后可计算真实进度
	return 0.3


## 由外部设置关卡进度（如 EventTrigger）
func set_progress(ratio: float) -> void:
	_progress_override = clampf(ratio, 0.0, 1.0)


# ═══════════════════════════════════════
# 战斗状态因子（权重 20%）— 全局量，与玩家数无关
# 战斗中 = 0.8，脱战 = 0.2
# ═══════════════════════════════════════
var in_combat: bool = false

func _calc_combat_factor() -> float:
	return 0.8 if in_combat else 0.2


## 由外部设置战斗状态
func set_combat(active: bool) -> void:
	in_combat = active
