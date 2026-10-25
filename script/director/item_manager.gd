extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node，子模块）
## 联机：仅单机/Host（Client 端 Director 早退，本模块不运行）
## 职责：补给决策与落点：按玩家血量/弹药紧张程度挑物品、挑"有设计感"的落点投下去，
##       并在玩家表现极差时触发降级投放（Fail-Safe）。
## 依赖：Director（取点/可行走判定/进度）、PlayerState

## 物品投放管理器 — 根据玩家状态自动投放补给
##
## 【落点设计（2026-10-25 重做）】旧实现是"以玩家为圆心随机角度撒点"，体感问题两个：
##   ① 可能撒到身后的死胡同/隔壁房间（玩家永远看不到）；
##   ② 可能贴在墙角、敌人堆里（捡不到 / 像刷怪）。
## 现在按设计文档 §6.2 分层取点：前进方向 → 屏幕可见带 → 开阔处（路口/房间中央），
## 每一层都过「脚印可走 + 离敌人 ≥128px + 离已有拾取物 ≥48px + 避墙吸附」。
##
## 【降级投放（2026-10-25 落地）】设计文档 §6.4 此后不再是欠账：
## 任一存活玩家 HP 低于 20% 持续 30s，或本冷却周期内出现过倒地 →
## 一次性投「急救喷雾 + 弹药堆 + 投掷品」，冷却 180s。落点不够时不消耗冷却，下个周期重试。

# ═══════════════════════════════════════
# 参数
# ═══════════════════════════════════════
const RANDOM_PICKUP_SCENE := preload("res://object/random_pickup.tscn")
const WEAPON_PICKUP_SCENE := preload("res://object/weapon_pickup.tscn")
const WEAPON_PICKUP_SCRIPT := preload("res://script/weapon_pickup.gd")
const ITEM_PICKUP_SCENE := preload("res://object/healing_pickup.tscn")
const SPOT_RESOLVER := preload("res://script/director/spawn_spot_resolver.gd")

@export var check_interval: float = 10.0          ## 常规决策检查间隔（秒）
@export var fail_safe_cooldown: float = 180.0     ## 降级投放冷却（秒）

@export var hp_spray_threshold: float = 0.5      ## HP < 50% 触发急救喷雾投放
@export var hp_pills_threshold: float = 0.3       ## HP < 30% 触发救急箱投放
@export var ammo_threshold: float = 0.3           ## 弹药 < 30% 触发弹药投放
@export var no_secondary_threshold: float = 0.8   ## 无副武器时投放概率（80%）

@export var spawn_distance_min: float = 200.0     ## 投放位置离玩家最小距离
@export var spawn_distance_max: float = 400.0     ## 投放位置离玩家最大距离
## 「可发现带」上限（px）：2× 缩放下半屏宽约 320px。第一层只在这个距离内取点 ——
## 投得太远玩家根本不知道有补给（L4D 的补给都是摆在必经之路上的）。
@export var drop_visible_max: float = 320.0
## 投放点周围这个半径内有存活敌人就不投（设计文档 §6.2：128px）。
@export var drop_threat_radius: float = 128.0
## 与已有地面拾取物的最小间距（避免两个补给叠在一起捡不起来）。
@export var drop_min_gap: float = 48.0

# ── 降级投放（Fail-Safe）──
## 怜悯血线：任一存活玩家 HP 比例低于它就累计"低血时长"。
## 设 0 = 关闭降级投放（只保留常规投放）。
@export_range(0.0, 0.6, 0.01) var fail_safe_hp_ratio: float = 0.2
## 低于怜悯血线持续多少秒才触发（防"擦伤一下就发货"）。
@export var fail_safe_low_hp_sec: float = 30.0
## 怜悯计时的扫描节拍（秒）。见 `_track_fail_safe` 的说明。
const FAIL_SAFE_SCAN_SEC: float = 0.25

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var enabled: bool = true
var _check_timer: float = 0.0
var _last_fail_safe_msec: int = -999999
var _director: Node = null
var _low_hp_time: Dictionary = {}   ## tid → 连续低血秒数
var _downed_seen: bool = false      ## 本冷却周期内是否出现过倒地
var _scan_acc: float = 0.0          ## 怜悯计时扫描累加（见 _track_fail_safe）
var _last_drop_msec: int = -999999  ## 上次常规投放时间（调试面板用）
var _last_drop_label: String = ""   ## 上次投放内容（调试面板用）
var _last_fail_safe_label: String = ""


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

	## 怜悯计时每帧都跑（廉价：最多 4 个玩家）—— 它必须独立于 10 秒检查节拍，
	## 否则"低血 30 秒"会被检查周期量化成 30~40 秒。
	_track_fail_safe(delta)

	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = check_interval

	var player: Node2D = _find_player()
	if not player:
		return

	## 降级投放优先于常规决策，且**不受 peak 限制**（它就是给濒死玩家的救济）。
	if _maybe_fail_safe(player):
		return

	# 尸潮中不投常规补给（会把玩家往怪堆里引）。
	if phase == &"peak":
		return

	_evaluate_and_spawn(player)


# ═══════════════════════════════════════
# 常规决策
# ═══════════════════════════════════════

func _evaluate_and_spawn(player: Node2D) -> void:
	var hp_ratio: float = _get_hp_ratio(player)
	var ammo_ratio: float = _get_ammo_ratio(player)
	var has_secondary: bool = _has_secondary_weapon(player)

	var item: String = ""
	var probability: float = 0.0

	if hp_ratio < hp_pills_threshold and not _has_healing_item(player):
		item = "救急箱"
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
		print("[ItemManager] 未找到合适的投放位置（本周期跳过）")
		return

	_spawn_pickup(item, pos)
	_last_drop_msec = Time.get_ticks_msec()
	_last_drop_label = "%s @(%d,%d)" % [item, int(pos.x), int(pos.y)]


# ═══════════════════════════════════════
# 降级投放（Fail-Safe，设计文档 §6.4）
# ═══════════════════════════════════════

## 每帧累计"低血时长"并记录倒地（倒地一次就够）。
##
## 【为什么按 0.25s 采样而不是每帧】`Players.all_entities()` 每次调用都会新建数组 +
## `_prune_invalid()`（Director 为此专门做了每帧缓存）。怜悯计时不需要 60Hz 精度，
## 攒够 0.25s 扫一次即可：分配频率降 15 倍，计时误差 ≤0.25s。
func _track_fail_safe(delta: float) -> void:
	if fail_safe_hp_ratio <= 0.0:
		return
	_scan_acc += delta
	if _scan_acc < FAIL_SAFE_SCAN_SEC:
		return
	var step: float = _scan_acc
	_scan_acc = 0.0
	var state: Node = get_node_or_null("/root/Players")
	if state == null:
		return
	var entities: Array = state.call("all_entities", false)
	for value: Variant in entities:
		## ⚠ 先判有效再转型：数组里可能含已释放对象（freed-cast 家族）
		if not is_instance_valid(value):
			continue
		var p: Node2D = value as Node2D
		if p == null:
			continue
		var tid: int = p.get_instance_id()
		if p.get("_is_dying") == true or p.get("_is_dead") == true:
			_downed_seen = true
			_low_hp_time.erase(tid)
			continue
		if _get_hp_ratio(p) <= fail_safe_hp_ratio:
			_low_hp_time[tid] = float(_low_hp_time.get(tid, 0.0)) + step
		else:
			_low_hp_time.erase(tid)


## 返回 true = 本轮已执行降级投放（调用方跳过常规决策）。
func _maybe_fail_safe(player: Node2D) -> bool:
	if fail_safe_hp_ratio <= 0.0:
		return false
	var now: int = Time.get_ticks_msec()
	if now - _last_fail_safe_msec < int(fail_safe_cooldown * 1000.0):
		return false

	var reason: String = ""
	for tid: Variant in _low_hp_time.keys():
		if float(_low_hp_time[tid]) >= fail_safe_low_hp_sec:
			reason = "HP < %.0f%% 持续 %.0fs" % [fail_safe_hp_ratio * 100.0, fail_safe_low_hp_sec]
			break
	if reason.is_empty() and _downed_seen:
		reason = "本周期内出现过倒地"
	if reason.is_empty():
		return false

	## 三件套要三个不同落点（同一个点会互相叠住）。少于 2 个就放弃并**不消耗冷却** ——
	## 宁可下一周期再试，也不要把"救援补给"投到墙里。
	var spots: Array[Vector2] = _find_spots(player, 3)
	if spots.size() < 2:
		print("[ItemManager] 降级投放：落点不足（%d），下个周期重试" % spots.size())
		return false

	var categories: Array[String] = ["急救喷雾", "弹药堆", "投掷品"]
	for i: int in range(categories.size()):
		var pos: Vector2 = spots[mini(i, spots.size() - 1)]
		_spawn_pickup(categories[i], pos, false)   ## false = 忽略掉落池，按类别精确投放
	_last_fail_safe_msec = now
	_low_hp_time.clear()
	_downed_seen = false
	_last_fail_safe_label = reason
	print("[ItemManager] ★降级投放（%s）：急救喷雾 + 弹药堆 + 投掷品" % reason)
	if _director != null and _director.has_method("debug_event"):
		_director.call("debug_event", "★降级投放（%s）" % reason)
	return true


# ═══════════════════════════════════════
# 生成
# ═══════════════════════════════════════

## 实际生成地面拾取物。
## `use_pool` = 配置了 `DirectorConfig.drop_pool` 时是否按池随机（降级投放传 false 精确投放）。
func _spawn_pickup(category: String, pos: Vector2, use_pool: bool = true) -> void:
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
	if use_pool and pool != null:
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
	if _director != null and _director.has_method("debug_event"):
		_director.call("debug_event", "投放 %s @(%d,%d)" % [category, int(pos.x), int(pos.y)])


## 未配置掉落池时的类别 → 资源映射。
func _resolve_category_resource(category: String, player_pos: Vector2) -> Resource:
	match category:
		"急救喷雾":
			return load("res://object/item_first_aid_spray.tres")
		## 2026-10-23：原「药品」指向 item_pills.tres，该物品已按用户要求删除
		## （原作说明书里没有，且 item_type=CONSUMABLE 不占治疗槽，投了也用不上）。
		## 低血量应急投放改为「救急箱」——item_type=HEALING，能直接进治疗槽生效。
		"救急箱":
			return load("res://object/item_aid_box.tres")
		"弹药堆":
			## 2026-10-25：原来只读主武器槽 → 只带手枪（副武器）的玩家拿不到弹药投放。
			## 现在主/副槽依次找，最后兜底手枪弹（总比不投强）。降级投放依赖这条。
			var player: Node2D = _find_player()
			var state: PlayerState = Players.get_state_for_entity(player) if player else null
			var ammo_ids: Array[String] = []
			if state:
				for slot: String in ["primary", "secondary"]:
					var wd: WeaponData = state.get_equipped_weapon(slot)
					if wd != null and not wd.ammo_item_id.is_empty() \
							and not ammo_ids.has(wd.ammo_item_id):
						ammo_ids.append(wd.ammo_item_id)
			for ammo_id: String in ammo_ids:
				var direct := "res://object/item_%s.tres" % ammo_id
				var derived := "res://object/item_%s_ammo.tres" % ammo_id.trim_prefix("ammo_")
				if ResourceLoader.exists(derived):
					return load(derived)
				if ResourceLoader.exists(direct):
					return load(direct)
			if ResourceLoader.exists("res://object/item_pistol_ammo.tres"):
				return load("res://object/item_pistol_ammo.tres")
			return null
		"副武器":
			return load("res://object/weapon_pistol.tres")
		"投掷品":
			## 降级投放专用（L4D 的"补给箱里一定有投掷物"）。手雷最通用；缺失时退燃烧瓶。
			if ResourceLoader.exists("res://object/item_grenade.tres"):
				return load("res://object/item_grenade.tres")
			if ResourceLoader.exists("res://object/item_molotov.tres"):
				return load("res://object/item_molotov.tres")
			return null
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
# 落点（2026-10-25 重做）
# ═══════════════════════════════════════

## 找一个"有设计感"的投放点：玩家会经过、看得见、站得进去、不在怪堆里。
func _find_spawn_pos(player: Node2D) -> Vector2:
	var spots: Array[Vector2] = _find_spots(player, 1)
	return spots[0] if not spots.is_empty() else Vector2.ZERO


## 取 `count` 个互不重叠的落点（降级投放要三件套分开放）。
## 分层策略（越靠前越理想，失败才降级）：
##   ① 前进方向 ±35°、可发现带（200~drop_visible_max）、**开阔处**；
##   ② 前进方向 ±65°、200~spawn_distance_max、不要求开阔；
##   ③ 全向（含身后）、160~spawn_distance_max —— 至少"放了能用"。
func _find_spots(player: Node2D, count: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if player == null or not is_instance_valid(player):
		return out
	var fwd: Vector2 = _forward_dir(player)
	var tiers: Array[Dictionary] = [
		{"spread": deg_to_rad(35.0), "min": spawn_distance_min,
			"max": maxf(minf(spawn_distance_max, drop_visible_max), spawn_distance_min + 40.0),
			"open": true},
		{"spread": deg_to_rad(65.0), "min": spawn_distance_min,
			"max": maxf(spawn_distance_max, spawn_distance_min + 40.0), "open": false},
		{"spread": PI, "min": spawn_distance_min * 0.8,
			"max": maxf(spawn_distance_max, spawn_distance_min + 40.0), "open": false},
	]
	for tier: Dictionary in tiers:
		var attempts: int = 24 if bool(tier["open"]) else 16
		for _i: int in range(attempts):
			var ang: float = randf_range(-float(tier["spread"]), float(tier["spread"]))
			var dist: float = randf_range(float(tier["min"]), float(tier["max"]))
			var candidate: Vector2 = player.global_position + fwd.rotated(ang) * dist
			var snapped: Vector2 = _snap_to_free(player, candidate)
			if snapped == Vector2.ZERO:
				continue
			if not _spot_clear(snapped, bool(tier["open"])):
				continue
			if _too_close_to_out(out, snapped):
				continue
			out.append(snapped)
			if out.size() >= count:
				return out
	return out


## 前进方向优先级：队伍实际行进方向 → 关卡出口方向 → 角色朝向。
func _forward_dir(player: Node2D) -> Vector2:
	if _director != null and _director.has_method("team_forward_dir") \
			and _director.has_method("spawn_reference_players"):
		var dir: Vector2 = _director.call("team_forward_dir",
			_director.call("spawn_reference_players"))
		if dir.length() > 0.1:
			return dir.normalized()
	## 静止时朝出口走 —— 补给摆在"要去的方向"上才有被发现的可能
	var pt: Variant = _director.get("progress_tracker") if _director != null else null
	if pt != null and is_instance_valid(pt):
		var dbg: Dictionary = pt.call("get_debug")
		if bool(dbg.get("has_exit", false)):
			var to_exit: Vector2 = (dbg["exit"] as Vector2) - player.global_position
			if to_exit.length() > 1.0:
				return to_exit.normalized()
	if player.has_method("get_facing_vector"):
		var fv: Vector2 = player.call("get_facing_vector")
		if fv.length() > 0.1:
			return fv.normalized()
	return Vector2.RIGHT


## 落点吸附：避墙 + 避 body（玩家自己除外）。失败返回 ZERO。
func _snap_to_free(player: Node2D, pos: Vector2) -> Vector2:
	if not _walkable(pos):
		return Vector2.ZERO
	var extra: Callable = Callable()
	if _director != null and _director.has_method("_is_footprint_walkable"):
		extra = Callable(_director, "_is_footprint_walkable")
	var found: Variant = SPOT_RESOLVER.find_near(player, pos, 14.0, extra, false, false)
	if found is Vector2:
		return found as Vector2
	return Vector2.ZERO


## 落点是否"干净"：附近没有敌人、没有别的拾取物；（open=true 还要）四周开阔。
func _spot_clear(pos: Vector2, need_open: bool) -> bool:
	if not _walkable(pos):
		return false
	if _enemy_within(pos, drop_threat_radius):
		return false
	if _pickup_within(pos, drop_min_gap):
		return false
	if need_open:
		## 8 向 24px 都能站 = 不在墙角/门框里（"路口或房间中央"的廉价近似）
		for i: int in range(8):
			var off: Vector2 = Vector2.RIGHT.rotated(TAU * float(i) / 8.0) * 24.0
			if not _walkable(pos + off):
				return false
	return true


func _walkable(pos: Vector2) -> bool:
	if _director == null:
		return false
	if _director.has_method("_is_walkable"):
		return bool(_director.call("_is_walkable", pos))
	return true


func _enemy_within(pos: Vector2, radius: float) -> bool:
	var tree: SceneTree = _director.get_tree() if _director != null else null
	if tree == null:
		return false
	for e: Node in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.has_method("get_weapon_data"):
			continue          ## 玩家也在 enemy 组里（历史约定）
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		var n2d: Node2D = e as Node2D
		if n2d != null and n2d.global_position.distance_to(pos) <= radius:
			return true
	return false


func _pickup_within(pos: Vector2, radius: float) -> bool:
	var tree: SceneTree = _director.get_tree() if _director != null else null
	if tree == null:
		return false
	for p: Node in tree.get_nodes_in_group("ground_pickup"):
		if not is_instance_valid(p):
			continue
		var n2d: Node2D = p as Node2D
		if n2d != null and n2d.global_position.distance_to(pos) <= radius:
			return true
	return false


func _too_close_to_out(list: Array[Vector2], pos: Vector2) -> bool:
	for p: Vector2 in list:
		if p.distance_to(pos) <= maxf(drop_min_gap, 32.0):
			return true
	return false


# ═══════════════════════════════════════
# 调试
# ═══════════════════════════════════════

## 供导演调试面板读取。
func get_debug() -> Dictionary:
	var low_hp_max: float = 0.0
	for tid: Variant in _low_hp_time.keys():
		low_hp_max = maxf(low_hp_max, float(_low_hp_time[tid]))
	var now: int = Time.get_ticks_msec()
	return {
		"check_left": maxf(_check_timer, 0.0),
		"last_drop": _last_drop_label,
		"last_drop_age": (now - _last_drop_msec) / 1000.0,
		"fail_safe_ready_in": maxf(0.0, fail_safe_cooldown - (now - _last_fail_safe_msec) / 1000.0),
		"fail_safe_low_hp": low_hp_max,
		"fail_safe_downed": _downed_seen,
		"fail_safe_last": _last_fail_safe_label,
	}


func _find_player() -> Node2D:
	var players: Array[Node2D] = Players.all_entities()
	return players[0] if not players.is_empty() else null
