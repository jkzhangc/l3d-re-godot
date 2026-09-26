class_name SpawnSpotResolver extends RefCounted

## ── 架构定位 ──
## 系统：关卡流程 / 联机实体就位 ｜ 层：工具类（RefCounted）
## 联机：不涉及（Host 与 Client 各自本地调用；搜索确定性 → 两端结果一致）
## 职责：把「可能压在墙里」的落点修正到最近的可站立位置。
## 依赖：TileMapLayer（图块碰撞，同步读 TileData）、PhysicsDirectSpaceState2D（场景内碰撞体）
## 被调用：NetworkWorld._spawn_position（多人补位）、_apply_arrival_to_preplaced_player（传送抵达）

## 【为什么需要它】2026-09-25 用户实测：3 人联机传送进学校内部三楼，第 3 个人卡在墙里。
## 根因：多人补位落点 = `锚点 + 56px × 序号` 的**纯几何偏移**，完全不看地图碰撞 ——
## 锚点贴着墙时第 2/3 个偏移点必然落进墙内；而学校内部的墙是**图块碰撞**（不是实体节点），
## 玩家被砌进去后连推都推不出来。用户口径："有物理层的不要加"。
##
## 【两道检查必须都要】
##   ① 图块碰撞：直接读 TileData 的碰撞多边形。**同步、不依赖物理空间是否已 flush** ——
##      传送发生在场景刚加载完的那一帧，此时新图块的碰撞体可能还没进物理空间，
##      只靠 intersect_shape 会漏判（这正是"传送落点"与"运行时落点"的区别）。
##   ② 物理探测：捕捉**节点式**碰撞体（铁门 / 防守战机器 / 场景里摆的家具），
##      它们不是图块，①查不到。
## 两者都通过才算"能站人"。

## 探测半径（px）：玩家碰撞盒 24×27 → 半宽 12、半高 13.5，取 14 保证整盒不压墙。
const PROBE_RADIUS: float = 14.0
## 环形搜索：步长 × 环数，每环 ANGLE_STEPS 个角度（最多 6×12=72 次探测，成本可忽略）。
const RING_STEP: float = 24.0
const RING_COUNT: int = 6
const ANGLE_STEPS: int = 12
## 会挡住玩家的物理层：1（图块"角色层" physics_layer_0）+ 4（玩家 body）+ 8（敌人 body）。
## 与 player.tscn 的 collision_mask=15 同口径（bit2 当前无人使用）。
const BLOCKING_MASK: int = 1 | 4 | 8


## 该点是否可以站人。`world_node` 必须已入树（取它的 World2D）。
## `probe_radius` 供不同体积的使用者覆盖（玩家盒 24×27 → 14；敌人盒 20×28 → 14 同样够用）。
static func is_free(world_node: Node2D, pos: Vector2, probe_radius: float = PROBE_RADIUS) -> bool:
	return _acceptable(world_node, pos, probe_radius, Callable())


## 找 `base` 附近最近的可站位置；**一个都没有时返回 null** ——
## 调用方据此决定回退策略（玩家落点=保留原地，敌人刷怪=退回屏幕外刷法）。
## `extra_ok` 是附加判据（例如 `Director._is_walkable`：地图范围闸 + 作者禁刷层）。
static func find_near(world_node: Node2D, base: Vector2, probe_radius: float = PROBE_RADIUS,
		extra_ok: Callable = Callable()) -> Variant:
	if _acceptable(world_node, base, probe_radius, extra_ok):
		return base
	for ring: int in range(1, RING_COUNT + 1):
		var radius: float = RING_STEP * float(ring)
		for i: int in range(ANGLE_STEPS):
			var ang: float = TAU * float(i) / float(ANGLE_STEPS)
			var cand: Vector2 = base + Vector2(cos(ang), sin(ang)) * radius
			if _acceptable(world_node, cand, probe_radius, extra_ok):
				return cand
	return null


## 修正落点：原落点是空的就原样返回；否则由近及远环形找最近的可站点（确定性，无随机）。
static func resolve(world_node: Node2D, base: Vector2) -> Vector2:
	var found: Variant = find_near(world_node, base)
	if found is Vector2:
		var fixed: Vector2 = found as Vector2
		if fixed != base:
			print("[SpawnSpot] 落点避墙修正 %s → %s（原落点有物理层碰撞）" % [
				base.round(), fixed.round()])
		return fixed
	## 四周全不可用（极端狭窄处）：保留原落点，不要乱丢到更远的地方。
	push_warning("[SpawnSpot] 落点四周无空位，保留原落点 %s" % base)
	return base


# ═══════════════════════════════════════
# 内部判定
# ═══════════════════════════════════════

## 综合判据：无法判定时保守放行（与 `Director._is_walkable` 的无玩家兜底同口径）；
## 否则必须同时通过 ①图块碰撞 ②物理探测 ③调用方附加判据。
static func _acceptable(world_node: Node2D, pos: Vector2, probe_radius: float,
		extra_ok: Callable) -> bool:
	if world_node == null or not is_instance_valid(world_node) or not world_node.is_inside_tree():
		return true
	if _tile_blocked(world_node, pos):
		return false
	if not _body_free(world_node, pos, probe_radius):
		return false
	if extra_ok.is_valid() and not bool(extra_ok.call(pos)):
		return false
	return true

## 图块碰撞检查：任一 TileMapLayer 在该格有 physics layer 0 的碰撞多边形 → 挡住。
## physics layer 0 ↔ tileset 的 `physics_layer_0/collision_layer = 1`（角色层），
## 与 Director._is_walkable 同一判据；这里**不查** NoSpawn 层（作者标注的是"禁刷怪"，
## 不代表玩家不能站）。
static func _tile_blocked(world_node: Node2D, pos: Vector2) -> bool:
	var tree: SceneTree = world_node.get_tree()
	if tree == null:
		return false
	## 扫描根取「本节点所在的顶层场景节点」，而不是 SceneTree.current_scene ——
	## 传送可能发生在 current_scene 还没指向新场景的那一帧（换图刚完成时），
	## 那时按 current_scene 扫会扫到旧图上，图块检查静默失效。
	var scan_root: Node = _topmost_scene_node(world_node, tree)
	var layers: Array[TileMapLayer] = []
	_collect_tilemaps(scan_root, layers)
	for tm: TileMapLayer in layers:
		if not is_instance_valid(tm) or tm.tile_set == null:
			continue
		## 无 physics layer 的纯视觉图块集：读碰撞会刷 "Index p_layer_id out of bounds"。
		if tm.tile_set.get_physics_layers_count() == 0:
			continue
		var coords: Vector2i = tm.local_to_map(tm.to_local(pos))
		var data: TileData = tm.get_cell_tile_data(coords)
		if data == null:
			continue
		## 用户口径「有物理层的不要加」→ 任一物理层有碰撞多边形就算不可站：
		##   · physics layer 0 = 图块的**角色层**（`physics_layer_0/collision_layer = 1`）——
		##     墙壁与桌椅等家具都挂在这一层，正是"卡住玩家"的直接原因；
		##   · 其余层（如子弹阻挡层 32）一并避开：宁可多挪一格，也不要落在"看着是墙里"的格子。
		for layer_id: int in range(tm.tile_set.get_physics_layers_count()):
			if data.get_collision_polygons_count(layer_id) > 0:
				return true
	return false


## 收集场景内全部 TileMapLayer（含 NoSpawn 层 —— 判据只看碰撞，不看禁刷标注）。
static func _collect_tilemaps(node: Node, out: Array[TileMapLayer]) -> void:
	if node is TileMapLayer:
		out.append(node as TileMapLayer)
	for child: Node in node.get_children():
		_collect_tilemaps(child, out)


## 本节点所在的顶层场景节点（SceneTree.root 的下一层）。
static func _topmost_scene_node(world_node: Node2D, tree: SceneTree) -> Node:
	var top: Node = world_node
	while top.get_parent() != null and top.get_parent() != tree.root:
		top = top.get_parent()
	return top


## 物理探测：以 probe_radius 圆在 pos 取形，命中 BLOCKING_MASK 上任何碰撞体 → 不空。
## 排除世界节点自身（传送时"玩家已在原点附近"不该把自己算成障碍）。
static func _body_free(world_node: Node2D, pos: Vector2, probe_radius: float) -> bool:
	var shape := CircleShape2D.new()
	shape.radius = probe_radius
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = Transform2D(0.0, pos)
	query.collision_mask = BLOCKING_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	if world_node is CollisionObject2D:
		var rid := (world_node as CollisionObject2D).get_rid()
		if rid.is_valid():
			query.exclude = [rid]
	return world_node.get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()
