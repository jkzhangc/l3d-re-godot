extends Node
## 导演系统 Autoload — 全局总控
##
## 负责：紧张度评估、敌人生成、物品投放决策、事件编排

# ═══════════════════════════════════════
# 信号
# ═══════════════════════════════════════
signal intensity_changed(value: float)
signal pacing_phase_changed(phase: String)
signal horde_incoming()
signal horde_started()
signal horde_ended()
signal special_spawned(type: String)
signal item_spawn_requested(zone: Vector2)
signal scripted_event_triggered(event: String)

# ═══════════════════════════════════════
# 参数
# ═══════════════════════════════════════
const ENEMY_SCENE_PATH = "res://object/enemy.tscn"
const DEBUG_SPAWN_COUNT = 5

@export var spawn_min_dist: float = 400.0       ## 生成点距玩家最小距离（px）
@export var spawn_map_keywords: Array[String] = []  ## 允许生成的地图名关键字（空=全部允许）
@export var safe_room_keywords: Array[String] = ["安全屋", "safe"]  ## 安全屋地图名关键字
@export var allow_manual_spawn: bool = true
@export var auto_spawn_enabled: bool = true      ## 总开关：是否启用自动生成

# ═══════════════════════════════════════
# 子模块
# ═══════════════════════════════════════
var intensity_tracker: Node = null
var _enemy_scene: PackedScene = null
var _spawn_history: Array = []
var _last_scene: Node = null  ## 检测场景切换，读取 DirectorConfig

# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	var it_script = load("res://script/director/intensity_tracker.gd")
	intensity_tracker = Node.new()
	intensity_tracker.name = "IntensityTracker"
	intensity_tracker.set_script(it_script)
	add_child(intensity_tracker)

	# ── PacingController ──
	var pc_script = load("res://script/director/pacing_controller.gd")
	var pc := Node.new()
	pc.name = "PacingController"
	pc.set_script(pc_script)
	add_child(pc)

	# ── SpawnManager ──
	var sm_script = load("res://script/director/spawn_manager.gd")
	var sm := Node.new()
	sm.name = "SpawnManager"
	sm.set_script(sm_script)
	add_child(sm)
	if sm.has_method("setup"):
		sm.setup(self)

	# ── EventManager ──
	var em_script = load("res://script/director/event_manager.gd")
	var em := Node.new()
	em.name = "EventManager"
	em.set_script(em_script)
	add_child(em)
	if em.has_method("setup"):
		em.setup(self)

	# ── ItemManager ──
	var im_script = load("res://script/director/item_manager.gd")
	var im := Node.new()
	im.name = "ItemManager"
	im.set_script(im_script)
	add_child(im)
	if im.has_method("setup"):
		im.setup(self)

	if pc.has_signal("phase_changed"):
		pc.phase_changed.connect(_on_phase_changed)

	if ResourceLoader.exists(ENEMY_SCENE_PATH):
		_enemy_scene = load(ENEMY_SCENE_PATH) as PackedScene
	else:
		printerr("[Director] enemy scene not found: %s" % ENEMY_SCENE_PATH)

	if intensity_tracker and intensity_tracker.has_method("set_progress"):
		intensity_tracker.set_progress(0.3)

	print("[Director] initialized (Phase 3)")


func _process(delta: float) -> void:
	# Phase 1 联机只验证 Host 权威玩家同步；导演、敌人、物品和战斗必须完全停用。
	if _is_phase1_online_session():
		return
	var player: Node2D = _find_player()
	if not player or not is_instance_valid(player):
		return
	# 跳过濒死/死亡玩家（死亡动画播放中或场景重载中）
	if player.get("_is_dying") == true:
		return

	_check_scene_change()

	if not _is_spawn_map():
		return

	# ── 紧张度 ──
	var prev_intensity: float = get_intensity()
	var new_intensity: float = prev_intensity
	if intensity_tracker and intensity_tracker.has_method("evaluate"):
		new_intensity = intensity_tracker.evaluate(player, delta)
		_update_combat_state(player)
		if abs(new_intensity - prev_intensity) > 0.05:
			intensity_changed.emit(new_intensity)

	# ── 存活敌人计数 ──
	var alive_count: int = _count_alive_enemies()

	# ── 节奏控制 ──
	var pc: Node = get_node_or_null("PacingController")
	if pc and pc.has_method("update"):
		pc.update(delta, new_intensity, alive_count)
	var current_phase: StringName = &"cooldown"
	if pc:
		match pc.current_phase:
			0: current_phase = &"build"
			1: current_phase = &"peak"
			_: current_phase = &"cooldown"

	# ── 事件编排（先于生成调度，剧本事件期间会禁用 SpawnManager）──
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("update"):
		em.update(delta, new_intensity, current_phase, alive_count)

	# ── 敌人生成调度 ──
	var sm: Node = get_node_or_null("SpawnManager")
	if sm and sm.has_method("update"):
		sm.update(delta, new_intensity, alive_count)

	# ── 物品投放 ──
	var im: Node = get_node_or_null("ItemManager")
	if im and im.has_method("update"):
		im.update(delta, current_phase, alive_count)


func _on_phase_changed(phase: StringName) -> void:
	## 节奏阶段切换 → 通知 SpawnManager + 发出信号
	print("[Director] pacing phase → %s" % phase)
	pacing_phase_changed.emit(phase)

	var sm: Node = get_node_or_null("SpawnManager")
	if sm and sm.has_method("on_phase_changed"):
		sm.on_phase_changed(phase)

	if phase == &"peak":
		horde_started.emit()
	elif phase == &"cooldown":
		horde_ended.emit()


func _input(event: InputEvent) -> void:
	if _is_phase1_online_session() or not allow_manual_spawn:
		return
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_F2:
		_debug_spawn()


func _is_phase1_online_session() -> bool:
	# 用节点路径而非 Autoload 标识符，兼容编辑器脚本热重载期间的全局类刷新时序。
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and net.is_online_session()


# ═══════════════════════════════════════
# 剧本事件 API
# ═══════════════════════════════════════

func start_scripted_event(config: Dictionary) -> void:
	## 开始一个剧本事件（由 ScriptedEventTrigger 调用）
	## config 包含: event_name, event_type, event_duration,
	##              spawn_interval, spawn_per_wave, max_active, trigger_node
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("start_scripted_event"):
		em.start_scripted_event(config)
	else:
		printerr("[Director] EventManager 未就绪，无法开始剧本事件")


func is_scripted_event_active() -> bool:
	var em: Node = get_node_or_null("EventManager")
	if em and em.has_method("is_scripted_event_active"):
		return em.is_scripted_event_active()
	return false


# ═══════════════════════════════════════
# 敌人生成
# ═══════════════════════════════════════

func spawn_enemy(pos: Vector2, decor_layer: Node, facing: int = -1) -> Node2D:
	if not _enemy_scene:
		printerr("[Director] enemy scene not loaded")
		return null

	var enemy = _enemy_scene.instantiate()
	enemy.global_position = pos
	# 必须在 add_child 前设 initial_facing（@export），
	# 因为 enemy._ready() 里 _facing = initial_facing，
	# 之后 _refresh_sprite() 每次都用 _facing 重算精灵帧
	if facing >= 0:
		enemy.initial_facing = facing
	else:
		# 未指定朝向时，自动面向玩家
		enemy.initial_facing = _calc_facing_toward_player(pos)
	decor_layer.add_child(enemy)

	_spawn_history.append({
		"time": Time.get_ticks_msec(),
		"pos": pos,
		"type": "common"
	})
	if _spawn_history.size() > 100:
		_spawn_history = _spawn_history.slice(-50)

	print("[Director] spawned enemy at (%d, %d)" % [int(pos.x), int(pos.y)])
	return enemy


func spawn_horde(count: int, decor_layer: Node) -> int:
	var player: Node2D = _find_player()
	if not player:
		return 0

	var spawn_points: Array = _get_valid_spawn_points(player, decor_layer)
	if spawn_points.is_empty():
		printerr("[Director] no valid spawn points")
		return 0

	var spawned: int = 0
	for i: int in range(count):
		var pos: Vector2 = _pick_spawn_position(player, spawn_points, spawned)
		if pos == Vector2.ZERO:
			continue
		pos = _add_spawn_scatter(pos)
		var enemy: Node2D = spawn_enemy(pos, decor_layer, -1)
		if enemy:
			spawned += 1

	return spawned


func _pick_spawn_position(player: Node2D, spawn_points: Array, spawned_count: int) -> Vector2:
	if not spawn_points.is_empty():
		var sp: Node2D = spawn_points[spawned_count % spawn_points.size()] as Node2D
		if sp is SpawnZone:
			return (sp as SpawnZone).get_random_position()
		else:
			return sp.global_position
	return _find_walkable_near_player(player)


func _add_spawn_scatter(pos: Vector2) -> Vector2:
	## 散步 + 避开现有敌人碰撞体（间距 28px）
	for _attempt: int in range(20):
		var scattered: Vector2 = pos + Vector2(randf_range(-36, 36), randf_range(-36, 36))
		if _is_walkable(scattered) and not _is_occupied_by_enemy(scattered) and not _was_recently_used(scattered):
			return scattered
	return pos + Vector2(randf_range(-48, 48), randf_range(-48, 48))


func _is_occupied_by_enemy(global_pos: Vector2) -> bool:
	const MIN_SEP: float = 28.0
	var tree: SceneTree = get_tree()
	if not tree:
		return false
	for e: Node2D in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		if global_pos.distance_to(e.global_position) < MIN_SEP:
			return true
	return false


# ═══════════════════════════════════════
# 查询
# ═══════════════════════════════════════

func get_intensity() -> float:
	if intensity_tracker and intensity_tracker.has_method("get_intensity"):
		return intensity_tracker.get_intensity()
	return 0.0


func set_progress(ratio: float) -> void:
	if intensity_tracker and intensity_tracker.has_method("set_progress"):
		intensity_tracker.set_progress(ratio)


func set_combat(active: bool) -> void:
	if intensity_tracker and intensity_tracker.has_method("set_combat"):
		intensity_tracker.set_combat(active)


# ═══════════════════════════════════════
# 内部 — 玩家/场景查找
# ═══════════════════════════════════════

func _is_spawn_map() -> bool:
	## 检查当前场景是否允许敌人生成
	if not auto_spawn_enabled:
		return false
	var tree: SceneTree = get_tree()
	if not tree or not tree.current_scene:
		return false
	var scene_path: String = tree.current_scene.scene_file_path.to_lower()
	# 白名单：指定了关键字则必须匹配
	if spawn_map_keywords.size() > 0:
		var matched: bool = false
		for kw: String in spawn_map_keywords:
			if kw.to_lower() in scene_path:
				matched = true
				break
		if not matched:
			return false
	# 黑名单：安全屋不生成
	for kw: String in safe_room_keywords:
		if kw.to_lower() in scene_path:
			return false
	return true


func _check_scene_change() -> void:
	var tree: SceneTree = get_tree()
	if not tree:
		return
	var scene: Node = tree.current_scene
	if scene == _last_scene:
		return
	_last_scene = scene
	# 场景切换 → 清空 TileMapLayer 缓存（旧引用已释放）
	_tilemap_cache.clear()
	_tilemap_cache_ready = false
	if not scene:
		return
	var cfg: DirectorConfig = _find_director_config(scene)
	if cfg:
		print("[Director] applying DirectorConfig from: %s" % scene.scene_file_path)
		_apply_config(cfg)
	else:
		print("[Director] no DirectorConfig in scene, using defaults")


func _find_director_config(node: Node) -> DirectorConfig:
	if node is DirectorConfig:
		return node as DirectorConfig
	for child: Node in node.get_children():
		var found: DirectorConfig = _find_director_config(child)
		if found:
			return found
	return null


func _apply_config(cfg: DirectorConfig) -> void:
	auto_spawn_enabled = cfg.spawn_enabled
	spawn_min_dist = cfg.spawn_min_dist
	var pc: Node = get_node_or_null("PacingController")
	if pc:
		_copy_props(cfg, pc, ["build_min", "build_max", "peak_timeout",
			"cooldown_min", "cooldown_max", "peak_intensity_threshold", "cooldown_intensity_threshold"])
	var sm: Node = get_node_or_null("SpawnManager")
	if sm:
		_copy_props(cfg, sm, ["scatter_min", "scatter_max",
			"scatter_interval_min", "scatter_interval_max",
			"horde_total_min", "horde_total_max",
			"horde_batch_size", "horde_batch_interval", "max_active_common"])
	print("[Director] config applied: spawn=%s cooldown=%.0f-%.0fs" % [cfg.spawn_enabled, cfg.cooldown_min, cfg.cooldown_max])


func _copy_props(src: Object, dst: Object, props: Array[String]) -> void:
	for prop: String in props:
		var val = src.get(prop)
		if val != null and prop in dst:
			dst.set(prop, val)


func _find_player() -> Node2D:
	var players: Array[Node2D] = Players.all_entities()
	return players[0] if not players.is_empty() else null


func _find_decor_layer() -> Node:
	var tree: SceneTree = get_tree()
	if not tree:
		return null
	return _find_decor_recursive(tree.root)


func _find_decor_recursive(node: Node) -> Node:
	if not is_instance_valid(node):
		return null
	if "decor" in node.name.to_lower():
		return node
	for child: Node in node.get_children():
		var found: Node = _find_decor_recursive(child)
		if found:
			return found
	return null


# ═══════════════════════════════════════
# 内部 — 生成点管理
# ═══════════════════════════════════════

func _get_valid_spawn_points(player: Node2D, _decor_layer: Node) -> Array:
	var tree: SceneTree = get_tree()
	if not tree:
		return []

	var all_points: Array = []
	_collect_spawn_nodes(tree.root, all_points)
	print("[Director] found %d spawn nodes" % all_points.size())

	var valid: Array = []
	for sp: Node2D in all_points:
		if not is_instance_valid(sp):
			continue
		if sp is SpawnPoint and not (sp as SpawnPoint).enabled:
			continue
		if sp is SpawnZone and not (sp as SpawnZone).enabled:
			continue
		var dist: float = player.global_position.distance_to(sp.global_position)
		if dist < spawn_min_dist:
			continue
		if _was_recently_used(sp.global_position):
			continue
		# 只检查 SpawnPoint 本身是否合法（SpawnZone 内部随机位置由后续检查）
		if sp is SpawnPoint and not _is_walkable(sp.global_position):
			print("[Director]   skip SpawnPoint at (%d,%d): on collision tile" % [int(sp.global_position.x), int(sp.global_position.y)])
			continue
		valid.append(sp)

	if valid.size() > 1:
		_sort_spawn_points_by_priority(valid)

	print("[Director] valid spawns: %d" % valid.size())
	return valid


func _sort_spawn_points_by_priority(arr: Array) -> void:
	var n: int = arr.size()
	for i: int in range(n):
		for j: int in range(n - i - 1):
			var a: Node2D = arr[j] as Node2D
			var b: Node2D = arr[j + 1] as Node2D
			var pa: float = _get_spawn_priority(a)
			var pb: float = _get_spawn_priority(b)
			if pa < pb:
				arr[j] = b
				arr[j + 1] = a


func _get_spawn_priority(sp: Node2D) -> float:
	if sp is SpawnPoint:
		return (sp as SpawnPoint).priority
	return 1.0




func _calc_facing_toward_player(from_pos: Vector2) -> int:
	## 计算从 from_pos 朝向玩家的方向（0=下,1=左,2=右,3=上）
	var player: Node2D = _find_player()
	if not player:
		return 0
	var to_player: Vector2 = player.global_position - from_pos
	# 与 enemy.gd update_facing_from_direction() 逻辑一致
	if abs(to_player.x) > abs(to_player.y):
		return 2 if to_player.x > 0 else 1  # RIGHT : LEFT
	else:
		return 0 if to_player.y > 0 else 3  # DOWN : UP


func _get_spawn_facing(sp: Node2D) -> int:
	var use_random: bool = false
	var default_facing: int = 0
	if sp is SpawnPoint:
		var pt: SpawnPoint = sp as SpawnPoint
		use_random = pt.random_facing
		default_facing = pt.facing
	elif sp is SpawnZone:
		var zone: SpawnZone = sp as SpawnZone
		use_random = zone.random_facing
		default_facing = zone.facing
	if use_random:
		return randi() % 4
	return default_facing

func _collect_spawn_nodes(node: Node, out: Array) -> void:
	if not is_instance_valid(node):
		return
	if node is SpawnPoint or node is SpawnZone:
		out.append(node)
	for child: Node in node.get_children():
		_collect_spawn_nodes(child, out)


# ═══════════════════════════════════════
# 内部 — 重复检查
# ═══════════════════════════════════════

const RECENT_SPAWN_RADIUS = 48.0
const RECENT_SPAWN_TIME_MSEC = 2000

func _was_recently_used(pos: Vector2) -> bool:
	var now: int = Time.get_ticks_msec()
	for entry: Dictionary in _spawn_history:
		if now - entry["time"] > RECENT_SPAWN_TIME_MSEC:
			continue
		var entry_pos: Vector2 = entry["pos"] as Vector2
		if pos.distance_to(entry_pos) < RECENT_SPAWN_RADIUS:
			return true
	return false


# ═══════════════════════════════════════
# 内部 — 可通行检查（TileData 碰撞）
# ═══════════════════════════════════════

var _tilemap_cache: Array = []
var _tilemap_cache_ready: bool = false

func _ensure_tilemap_cache(from_node: Node2D) -> void:
	if _tilemap_cache_ready:
		return
	var tree: SceneTree = from_node.get_tree()
	if not tree:
		return
	_find_tilemaps(tree.root)
	_tilemap_cache_ready = true
	print("[Director] TileMapLayer cache: %d layers" % _tilemap_cache.size())


func _find_tilemaps(node: Node) -> void:
	if node is TileMapLayer:
		_tilemap_cache.append(node as TileMapLayer)
	for child: Node in node.get_children():
		_find_tilemaps(child)


func _is_walkable(global_pos: Vector2) -> bool:
	var player: Node2D = _find_player()
	if not player or not is_instance_valid(player):
		return true
	_ensure_tilemap_cache(player)
	if _tilemap_cache.is_empty():
		return true

	for tm: TileMapLayer in _tilemap_cache:
		if not is_instance_valid(tm):
			continue
		var local_pos: Vector2 = tm.to_local(global_pos)
		var coords: Vector2i = tm.local_to_map(local_pos)
		var tile_data: TileData = tm.get_cell_tile_data(coords)
		if tile_data and tile_data.get_collision_polygons_count(0) > 0:
			return false
	return true


# ═══════════════════════════════════════
# 内部 — 敌人统计
# ═══════════════════════════════════════

func _count_alive_enemies() -> int:
	var tree: SceneTree = get_tree()
	if not tree:
		return 0
	var count: int = 0
	for e: Node2D in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		count += 1
	return count


# 内部 — 战斗状态
# ═══════════════════════════════════════

func _update_combat_state(player: Node2D) -> void:
	var tree: SceneTree = get_tree()
	if not tree:
		return
	var enemies: Array = tree.get_nodes_in_group("enemy")
	var in_combat: bool = false
	for e: Node2D in enemies:
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		if player.global_position.distance_to(e.global_position) < 500.0:
			in_combat = true
			break
	set_combat(in_combat)


# ═══════════════════════════════════════
# 内部 — F2 调试生成
# ═══════════════════════════════════════

func _debug_spawn() -> void:
	var decor_layer: Node = _find_decor_layer()
	if not decor_layer:
		printerr("[Director] DecorLayer not found")
		return

	var player: Node2D = _find_player()
	if not player:
		printerr("[Director] player not found")
		return

	var spawn_points: Array = _get_valid_spawn_points(player, decor_layer)
	var spawned: int = 0

	if spawn_points.is_empty():
		print("[Director] no SpawnPoints, spawning around player...")
		for i: int in range(DEBUG_SPAWN_COUNT):
			var pos: Vector2 = _find_walkable_near_player(player)
			if pos == Vector2.ZERO:
				continue
			if _was_recently_used(pos):
				continue
			var enemy: Node2D = spawn_enemy(pos, decor_layer, -1)  # -1=自动面向玩家
			if enemy:
				spawned += 1
	else:
		for i: int in range(DEBUG_SPAWN_COUNT):
			if spawn_points.is_empty():
				break
			var idx: int = randi() % spawn_points.size()
			var sp: Node2D = spawn_points[idx] as Node2D
			spawn_points.remove_at(idx)

			var pos: Vector2
			if sp is SpawnZone:
				# SpawnZone: 区域内随机，确保可行走
				for _attempt: int in range(10):
					pos = (sp as SpawnZone).get_random_position()
					if _is_walkable(pos) and not _is_occupied_by_enemy(pos) and not _was_recently_used(pos):
						break
				if pos == Vector2.ZERO:
					pos = (sp as SpawnZone).get_random_position()
			else:
				# SpawnPoint: 加小幅度散步，并确保最终位置可行走
				for _attempt: int in range(10):
					pos = sp.global_position + Vector2(randf_range(-12, 12), randf_range(-12, 12))
					if _is_walkable(pos) and not _is_occupied_by_enemy(pos) and not _was_recently_used(pos):
						break

			var enemy: Node2D = spawn_enemy(pos, decor_layer, _get_spawn_facing(sp))
			if enemy:
				spawned += 1

	print("[Director] F2 debug spawn: %d/%d enemies" % [spawned, DEBUG_SPAWN_COUNT])


func _find_walkable_near_player(player: Node2D) -> Vector2:
	## 在玩家外围找一个可行走的位置
	for _attempt: int in range(20):
		var angle: float = randf() * TAU
		var dist: float = randf_range(spawn_min_dist, spawn_min_dist + 100.0)
		var pos: Vector2 = player.global_position + Vector2.RIGHT.rotated(angle) * dist
		pos += Vector2(randf_range(-16, 16), randf_range(-16, 16))
		if _is_walkable(pos):
			return pos
	# 回退：直接返回 400px 外随机位置
	var angle: float = randf() * TAU
	return player.global_position + Vector2.RIGHT.rotated(angle) * spawn_min_dist
