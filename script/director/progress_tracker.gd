extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node，子模块，由 Director 创建）
## 联机：仅单机/Host（Client 的 `Director._process` 早退，本模块不运行）
## 职责：估计「本章已经走过多少比例」（0~1），供 ① 紧张度的进度因子 ② Boss 发牌的路程闸 使用。
## 依赖：被 Director 每帧调用；读取当前场景里的出口节点（SafeDoor / TeleportPoint / ArrivalPoint）
##
## 【为什么需要它】此前 `Director._ready()` 把进度写死 0.3（`intensity_tracker.set_progress(0.3)`），
## 于是「越接近终点越紧张」这条设计完全失效，且紧张度上限被压到 ≈0.895 ——
## `peak_intensity_threshold=0.7` 只能靠交战自然达到。
## 更关键的是：L4D 的 Boss 出场时机建立在 **flow（已走过的路程比例）** 上
## （mission.txt 的 `coop_boss_spawning.spawn_pos_min / spawn_pos_max`），
## 没有真实的 flow 就没法做「Tank 不许在开局 1/3 出现」这条规则。
##
## 【取数口径】
##   ① **距出口收敛**（首选）：`1 - 队伍质心到出口的距离 / 进图时到出口的距离`。
##      —— 天然在门口收敛到 1.0，不受路线蜿蜒/长度估算影响；
##         对 L 形地图也成立（绕路必然缩短到出口的直线距离）。
##   ② **行进里程**（无出口节点时兜底）：累计净位移 / 参考总路程。
##      参考总路程 = 本模块的 `route_length_override`（地图配置）→ 默认 7000px。
##   ③ **手动覆盖**：`set_forced()`（`Director.set_progress()` / 剧本事件强推）。
##
## 【为什么里程不作为主口径】里程对「原地绕圈」没有免疫力 —— 在一个小房间里来回跑
## 也能把里程刷满，进而提前打开 Tank 闸门。L4D 的 flow 是沿导流路径的**前进**量，
## 不是"脚动了多少"。所以有出口节点时只认距离收敛。
##
## 【单调性】进度只增不减（`max(旧值, 新值)`）：回退几步找东西不该让导演"重新热身"。

## 无出口节点、且配置没给 `progress_length_px` 时的参考总路程（px）。
## 取 7000 ≈ 本作一张普通图的行军长度量级（3200px 发一张 Boss 牌，一张图 3~5 分钟跑完）。
const DEFAULT_ROUTE_LEN: float = 7000.0
## 起步距离闸：出口离起点太近（< 400px）时几何口径不可用（分母太小会瞬间到 1.0）。
const MIN_START_DIST: float = 400.0

var enabled: bool = true
## > 0 时替代自动估算（来自 DirectorConfig.progress_length_px）。
var route_length_override: float = 0.0

var _progress: float = 0.0
var _trail: float = 0.0
var _origin: Vector2 = Vector2.ZERO
var _origin_set: bool = false
var _exit: Vector2 = Vector2.ZERO
var _has_exit: bool = false
var _start_dist: float = 0.0
var _route_len: float = DEFAULT_ROUTE_LEN
var _forced: float = -1.0
var _exit_resolved: bool = false
var _scene: Node = null


## 换图（含同图重传）时调用：清空本图度量，出口节点留到第一次 update 再解析
## （解析需要起点位置，此时玩家可能还没就位）。
func reset_for_scene(scene: Node) -> void:
	_progress = 0.0
	_trail = 0.0
	_origin_set = false
	_exit = Vector2.ZERO
	_has_exit = false
	_start_dist = 0.0
	_forced = -1.0
	_exit_resolved = false
	_scene = scene
	_route_len = route_length_override if route_length_override > 0.0 else DEFAULT_ROUTE_LEN


## 每帧调用。`advance` = 本帧队伍前进量（px，Director 已采样）；`players` = 全体存活玩家。
func update(players: Array, advance: float) -> void:
	if not enabled:
		return
	if advance > 0.0:
		_trail += advance

	if not _origin_set:
		var c0: Variant = _centroid(players)
		if c0 == null:
			return
		_origin = c0
		_origin_set = true
	if not _exit_resolved:
		_resolve_exit()

	if _forced >= 0.0:
		_progress = clampf(_forced, 0.0, 1.0)
		return

	var raw: float = 0.0
	## ① 距出口收敛（首选）
	if _has_exit and _start_dist >= MIN_START_DIST:
		var center: Variant = _centroid(players)
		if center != null:
			var geo: float = 1.0 - (center as Vector2).distance_to(_exit) / _start_dist
			raw = clampf(geo, 0.0, 1.0)
	## ② 里程兜底（没有出口 / 出口太近）
	if raw <= 0.0:
		raw = clampf(_trail / maxf(_route_len, 400.0), 0.0, 1.0)

	_progress = maxf(_progress, raw)


## 当前进度（0~1，单调不减）。
func get_progress() -> float:
	return _progress


## 强制进度（0~1）。传负数恢复自动估计。
func set_forced(ratio: float) -> void:
	_forced = clampf(ratio, 0.0, 1.0) if ratio >= 0.0 else -1.0
	if _forced >= 0.0:
		_progress = _forced


func is_forced() -> bool:
	return _forced >= 0.0


## 调试面板用的快照。
func get_debug() -> Dictionary:
	return {
		"progress": _progress,
		"trail": _trail,
		"route_len": _route_len,
		"has_exit": _has_exit,
		"start_dist": _start_dist,
		"forced": _forced,
		"exit": _exit,
	}


# ═══════════════════════════════════════
# 内部
# ═══════════════════════════════════════

## 队伍质心；没有有效玩家时返回 null（用 Variant 而不是 Vector2.ZERO ——
## (0,0) 是合法坐标，拿它当"无值"会把起点钉在地图原点）。
func _centroid(players: Array) -> Variant:
	var sum: Vector2 = Vector2.ZERO
	var n: int = 0
	for value: Variant in players:
		if not is_instance_valid(value):
			continue
		var p: Node2D = value as Node2D
		if p == null:
			continue
		if p.get("_is_dying") == true or p.get("_is_dead") == true:
			continue
		sum += p.global_position
		n += 1
	if n == 0:
		return null
	return sum / float(n)


## 解析本图出口：场景里所有 SafeDoor / TeleportPoint / ArrivalPoint 中，离起点最远的那个。
## 不按节点名判（作者可能改名），按脚本文件名 —— 与 `_collect_spawn_nodes` 的做法一致。
func _resolve_exit() -> void:
	_exit_resolved = true
	var scene: Node = _scene
	if scene == null or not is_instance_valid(scene):
		var tree: SceneTree = get_tree()
		scene = tree.current_scene if tree != null else null
	if scene == null:
		return
	var best_pos: Vector2 = Vector2.ZERO
	var best_dist: float = -1.0
	var stack: Array[Node] = [scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if not (n is Node2D):
			continue
		if not _is_exit_node(n):
			continue
		var d: float = (n as Node2D).global_position.distance_to(_origin)
		if d > best_dist:
			best_dist = d
			best_pos = (n as Node2D).global_position
	if best_dist < 0.0:
		## 没有出口节点（街道等"走到某处触发"的图）→ 用地面图块的包围盒估路线长度。
		_estimate_route_from_tilemap(scene)
		return
	_exit = best_pos
	_has_exit = true
	_start_dist = best_dist
	if route_length_override <= 0.0:
		## 路线一般比直线长；1.6 是经验系数（直线 × 1.6 覆盖常见 L 形/回折走廊）
		_route_len = clampf(best_dist * 1.6, 800.0, 60000.0)
	print("[Progress] 出口 %s（距起点 %.0fpx，参考路程 %.0fpx）" % [
		_exit.round(), _start_dist, _route_len])


## 无出口节点时的参考路程：地面层包围盒对角线 × 1.2。
## 比"写死 7000px"可靠 —— 街道/走廊图的实际尺度差好几倍，硬编码会让进度在
## 短图上永远到不了阈值（Tank 闸门永不打开）、长图上又过早满格。
func _estimate_route_from_tilemap(scene: Node) -> void:
	if route_length_override > 0.0:
		return
	var tm: TileMapLayer = _find_ground_layer(scene)
	if tm == null:
		return
	## TileMapLayer.get_used_rect() 返回 **Rect2i**（格子坐标），size 是 Vector2i ——
	## 直接与 Vector2 比较会 Parse Error（"Invalid operands Vector2i and Vector2"）。
	var used: Rect2i = tm.get_used_rect()
	if used.size == Vector2i.ZERO:
		return
	var cell: Vector2 = Vector2(32, 32)
	if tm.tile_set != null:
		cell = Vector2(tm.tile_set.tile_size)
	var span: Vector2 = Vector2(used.size) * cell
	_route_len = clampf(span.length() * 1.2, 1200.0, 60000.0)
	print("[Progress] 无出口节点 → 按地面层包围盒估参考路程 %.0fpx（%s）" % [_route_len, span.round()])


## 找地面层：优先名字含 Ground 的 TileMapLayer，否则取第一个有图块的层。
func _find_ground_layer(scene: Node) -> TileMapLayer:
	var first: TileMapLayer = null
	var stack: Array[Node] = [scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		var tm: TileMapLayer = n as TileMapLayer
		if tm == null:
			continue
		if "ground" in tm.name.to_lower():
			return tm
		if first == null and tm.get_used_rect().size != Vector2i.ZERO:
			first = tm
	return first


func _is_exit_node(n: Node) -> bool:
	var script: Script = n.get_script() as Script
	if script == null:
		return false
	var path: String = script.resource_path
	## ⚠ 不要算上 arrival_point.gd —— 它是**入口**锚点（TeleportPoint.target_arrival_id 的落点），
	## 算进来会把"起点"当选出口，进度恒 0。
	return path.ends_with("safe_door.gd") or path.ends_with("teleport_point.gd")
