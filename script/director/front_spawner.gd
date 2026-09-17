extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node，Director 的子模块）
## 联机：仅单机 / Host（Client 不生成实体，只接收 NetworkWorld 快照）
## 职责：把普通敌人「补在玩家前方、屏幕之外」——按玩家朝向/移动方向取前方扇区，
##       在相机可视矩形外按距离带取点；前方带内已经有足够敌人就停手。
## 依赖：Director（spawn_enemy / _is_walkable / _is_occupied_by_enemy / _was_recently_used）、
##       相机（可视范围）、SpawnPoint / SpawnZone（关卡作者标注的刷新点，优先使用）

## 前方屏外刷怪（Front off-screen spawner）
##
## 【要解决的问题】
## 旧逻辑在两处"乱撒"：
##   ① 作者刷新点都不在附近时，Director 回退到 `_find_walkable_near_player()` ——
##      在玩家周围 400~720px 的**任意方向**随机取点，于是敌人可能出现在玩家正前方可视范围内，
##      也可能散在背后、侧面，分布零散；
##   ② 散兵只按 15~30s 的固定计时触发，玩家一旦快速推进，前方就"空窗"——看着很怪。
##
## 【本模块的做法】照 L4D 式（也是原作 L3D 的"配置/回収"思路）：
##   · **只刷在玩家前方**：以玩家移动方向（静止时用朝向）为中心的前方扇区（默认 ±60°）；
##   · **只刷在屏幕外**：必须落在相机可视矩形之外，且至少离开 `offscreen_margin` 像素，
##      因此玩家看不到"凭空出现"；
##   · **固定数量**：前方带内维持 `target_ahead` 只；带内数量够了就完全不刷
##      （这就是"如果刷的范围地方已经有一定数量丧尸，那就不刷了"）；
##   · **玩家移动时持续补**：按"玩家累计前进 `advance_step` 像素 + 最短间隔"触发，
##      而不是固定 15~30s，走得快就补得快；
##   · **优先用关卡作者的刷新点**（SpawnPoint / SpawnZone）——只要它落在"前方 + 屏外"，
##      就优先用它，保持关卡设计意图；没有合适点时才按距离带 × 角度自动找可行走格。
##
## 【原作参考（E:/15.L3D，2026-09-10 逆向 LDB 公共事件）】
##   敌１〜敵６ = 6 个固定敌人槽位（各带 X/Y/体力 变量与"敵N－ゾンビ出現"等开关）；
##   #489-494 増援判定 = 判断某槽位是否空缺 → #505 ★☆敵の配置設定☆★ 把敌人放到玩家附近；
##   #506 ★☆敵の回収設定☆★ = 把离玩家太远的敌人收回；#495-500 再配置時リセット = 放置时重置其状态。
##   即"固定数量的槽位 + 玩家周围回收/重放"。本模块取同一思路的 Godot 实现。

@export_group("开关")
## 总开关。关闭后本模块完全不介入，回到旧的"按计时散撒"行为。
@export var enabled: bool = true
## 喘息（cooldown）阶段是否暂停补位。（2026-09-17 用户反馈：尸潮结束喘息期完全断供，
## 路上一直没丧尸）→ 默认改 false：喘息期按平常节奏（batch 1 / 2s / 附近闸）零星维持。
@export var pause_in_cooldown: bool = false

@export_group("数量")
## 前方带内维持的目标数量（**平常**阶段：build / cooldown）。带内已有这么多就不再刷。
## 2026-09-16 用户反馈「平常刷怪量已经跟尸潮差不多」→ 默认从 6 收到 3：
## 把"人多"这件事留给尸潮（peak），平常保持零星。
@export var target_ahead: int = 3
## 每次补位最多补几只（平常阶段；不会一次把 target_ahead 补满）。
@export var batch: int = 1
## 【尸潮（peak）阶段】前方带内维持的目标数量 ——
## 也就是用户要的"刷的附近达到指定数量（如 20）就停止刷怪"的**硬上限**。
@export var target_ahead_peak: int = 20
## 【尸潮（peak）阶段】每次补位最多补几只。
@export var batch_peak: int = 3
## 【尸潮（peak）阶段】两批之间的最短间隔（秒）。尸潮必须比平常刷得**快得多**。
@export var interval_min_peak: float = 1.2
## 场上存活总数上限（与 SpawnManager.max_active_common 同源，由 DirectorConfig 统一注入）。
@export var max_active_common: int = 15

@export_group("位置")
## 前方扇区半角（度）。90 = 只刷正前方；60 = 正前方 ±60°。
@export var front_half_angle: float = 60.0
## 距离带下限（像素）。要同时满足"屏幕外"，所以实际下限取两者较大值。
@export var min_dist: float = 360.0
## 距离带上限（像素）。太大 = 敌人要跑很久才到，太小 = 一眼就看见。
## 2026-09-15 校准：摄像机 2× 放大 → 实际可视 640×480（半宽 320），屏外下限≈384px；
## 上限 560 ≈ 出屏后半个多屏宽。旧值 900 会让怪刷在 1~2 个屏宽外，
## 普通丧尸 starts_in_chase=false（视野 200px 才激活）→ 玩家推进时一路空场。
@export var max_dist: float = 560.0
## 至少离开相机可视矩形这么多像素才算"屏幕外"。
@export var offscreen_margin: float = 64.0
## 未指定相机时的可视半宽/半高兜底（本工程视口 1280×960、相机缩放 2× → 640×480）。
@export var fallback_view_size: Vector2 = Vector2(640.0, 480.0)

@export_group("节奏")
## 玩家累计前进这么多像素，才允许补下一批（防止原地不动狂刷）。
@export var advance_step: float = 160.0
## 两批之间的最短间隔（秒）。（2026-09-17 用户：普通刷怪要快，量少=batch 1 不变）
@export var interval_min: float = 2.0
## 原地不动时是否也补位。false（默认）= 站着不动不会刷怪，避免"脸上刷怪"。
@export var spawn_when_idle: bool = false
## 附近闸（2026-09-17 用户需求）：附近（半径内）存活敌人 ≥ 该数量且玩家静止 → 暂停刷怪，
## 玩家开始移动立即恢复。0 = 关闭。普通补位 / spawn_ahead_batch / 尸潮事件批统一走这组参数。
@export var nearby_gate_count: int = 10
## 附近闸的判定半径（px，以玩家为圆心）。
@export var nearby_gate_radius: float = 600.0
## 视为"移动中"的最小速度（像素/秒）。
@export var moving_speed_eps: float = 20.0

@export_group("距离带备用点数")
## 自动找点时在距离带上取几环（越大越慢、越精细）。
@export var ring_count: int = 4
## 自动找点时在前方扇区内取几个角度。
@export var angle_steps: int = 7

# ── 内部状态 ──
var _director: Node = null
var _advance_accum: float = 0.0     ## 距上一批的净位移（触发后归零）
var _timer: float = 0.0             ## 距上次补位的秒数
var _last_batch_pos: Vector2 = Vector2.INF  ## 上一批补位时玩家的位置
var _last_dir: Vector2 = Vector2.DOWN  ## 玩家静止时的朝向兜底
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

## 最近一次「本帧没有补位」的原因（供现场抓取器与诊断使用）。
## 现场问题往往是"前方断供了，但不知道被哪道闸门拦住" —— 有这一行就能直接读出结论。
var last_reject: String = "初始"


func setup(director_node: Node) -> void:
	_director = director_node
	_rng.randomize()


# ═══════════════════════════════════════
# 对外主循环
# ═══════════════════════════════════════

func update(delta: float, player: Node2D, alive_count: int, phase: StringName = &"build") -> int:
	## 每帧由 Director 调用。返回本帧实际刷出的数量（0 表示没有动静）。
	if not enabled or _director == null or player == null or not is_instance_valid(player):
		last_reject = "未启用 / 无玩家"
		return 0
	if pause_in_cooldown and phase == &"cooldown":
		last_reject = "喘息(cooldown)阶段暂停"
		return 0
	if alive_count >= max_active_common:
		## 注意：这里的 alive_count 是**全场**存活数，包含已经被玩家甩在身后、
		## 仍在慢慢追的老敌人。没有回收机制时它会只增不减 → 前方被这道闸门永久掐断。
		last_reject = "全场存活已达上限 %d/%d" % [alive_count, max_active_common]
		return 0

	## 尸潮（peak）阶段普通补位暂停（2026-09-17 用户：尸潮期间普通刷怪不要刷）——
	## 尸潮数量改由 EventManager 尸潮事件批供怪（慢节奏大批 8 只/5s）；
	## 快速小批补位会和尸潮抢戏（用户观察「打死几只就突然两只过来」）。
	## 防守战期间 Director 挂起，本 tick 不运行，不受影响。
	if phase == &"peak":
		last_reject = "尸潮阶段由尸潮事件批供怪，普通补位暂停"
		return 0

	_timer += delta
	## 自上一批以来玩家真正走出的距离。用"净位移"而不是"逐帧位移累加"：
	## 角色顶在墙上时会有 1~2px 的来回抖动，累加式会把它攒够 advance_step → 原地刷怪。
	if _last_batch_pos == Vector2.INF:
		_last_batch_pos = player.global_position
	_advance_accum = player.global_position.distance_to(_last_batch_pos)

	var dir: Vector2 = _front_dir(player)
	if dir != Vector2.ZERO:
		_last_dir = dir

	var speed: float = 0.0
	var v: Variant = player.get("velocity")
	if v is Vector2:
		speed = (v as Vector2).length()
	var idle: bool = speed < moving_speed_eps
	if idle and not spawn_when_idle:
		last_reject = "玩家静止（spawn_when_idle=false）"
		return 0  # 站着不动不补位（避免原地刷怪）

	## 附近闸：附近敌人达标且玩家静止 → 暂停；一动就放行（2026-09-17 用户需求）
	if nearby_gate_count > 0 and idle:
		var near: int = _count_nearby(player)
		if near >= nearby_gate_count:
			last_reject = "附近已有 %d ≥ %d 只且玩家静止（附近闸）" % [near, nearby_gate_count]
			return 0

	## 按阶段取「附近维持目标 / 每批补几只 / 最短间隔」：
	## 平常（build/cooldown）零星补位；尸潮（peak）又密又猛，且**到量即停**（用户 2026-09-16）。
	var is_peak: bool = phase == &"peak"
	var target: int = target_ahead_peak if is_peak else target_ahead
	var batch_now: int = batch_peak if is_peak else batch
	var interval_now: float = interval_min_peak if is_peak else interval_min

	var ahead: int = count_ahead(player)
	if ahead >= target:
		last_reject = "附近已满 %d/%d（%s）" % [ahead, target, "尸潮" if is_peak else "平常"]
		return 0  # 附近已经够了 —— "这个范围里有一定数量就不刷"

	## 移动中：按"累计前进距离"触发（走得快就补得快）；静止且允许补位时只受最短间隔约束。
	if not idle and _advance_accum < advance_step:
		last_reject = "前进距离不足 %.0f/%.0f" % [_advance_accum, advance_step]
		return 0
	if _timer < interval_now:
		last_reject = "距上批仅 %.1fs < %.1fs" % [_timer, interval_now]
		return 0

	var want: int = mini(batch_now, target - ahead)
	want = mini(want, max_active_common - alive_count)
	var spawned: int = 0
	var picks_failed: int = 0
	for _i: int in range(want):
		var pos: Vector2 = pick_ahead_position(player)
		if pos == Vector2.ZERO:
			picks_failed += 1
			break
		var enemy: Node2D = _director.spawn_enemy(pos, _director._find_decor_layer(), -1)
		if enemy:
			spawned += 1
	if spawned > 0:
		_last_batch_pos = player.global_position
		_advance_accum = 0.0
		_timer = 0.0
		last_reject = "已补位 %d 只" % spawned
		print("[FrontSpawner] 前方补位 %d 只（带内 %d→%d / 目标 %d %s / 全场 %d）" % [
			spawned, ahead, ahead + spawned, target, "尸潮" if is_peak else "平常", alive_count])
	elif picks_failed > 0:
		## 闸门都过了，但"前方扇区 × 屏幕外 × 距离带"里找不到合格点 ——
		## 一般是地形太狭窄，或者这段扇形采样刚好都不可行走。
		last_reject = "前方找不到合格落点（尝试 %d 次）" % picks_failed
	return spawned


# ═══════════════════════════════════════
# 位置选择
# ═══════════════════════════════════════

func pick_ahead_position(player: Node2D) -> Vector2:
	## 在前方扇区 + 屏幕外 + 距离带 内找一个可行走位置。找不到返回 ZERO。
	## 优先使用关卡作者摆的刷新点（SpawnPoint / SpawnZone），保持关卡设计意图。
	var author_pos: Vector2 = _pick_author_point(player)
	if author_pos != Vector2.ZERO:
		return author_pos

	var view_half: Vector2 = _view_half_extents()
	var cam_center: Vector2 = _camera_center(player)
	var dir: Vector2 = _last_dir
	var cos_limit: float = cos(deg_to_rad(front_half_angle))

	## 有效下限 = max(距离带下限, 沿该方向"刚好出屏"的距离)。
	## 否则采样点里有一半必然被屏外条件否掉，白白浪费迭代（水平方向尤其明显：
	## 可视半宽 320 + 余量 64 = 384 > min_dist 360）。
	var eff_min: float = maxf(min_dist, _offscreen_distance(dir, view_half))
	for ring: int in range(ring_count):
		# 由近到远：近处的点刚好在屏外，敌人更快能咬到玩家
		var t: float = (float(ring) + 1.0) / float(ring_count)
		var dist: float = lerpf(eff_min, max_dist, t)
		for a: int in range(angle_steps):
			var offset_angle: float = 0.0
			if angle_steps > 1:
				offset_angle = lerpf(-front_half_angle, front_half_angle, float(a) / float(angle_steps - 1))
			var cand_dir: Vector2 = dir.rotated(deg_to_rad(offset_angle))
			var pos: Vector2 = player.global_position + cand_dir * dist
			pos += Vector2(_rng.randf_range(-12.0, 12.0), _rng.randf_range(-12.0, 12.0))
			if not _is_offscreen(pos, cam_center, view_half):
				continue
			if cand_dir.dot(dir) < cos_limit:
				continue
			if not _director._is_walkable(pos):
				continue
			if _director._is_occupied_by_enemy(pos) or _director._was_recently_used(pos):
				continue
			return pos
	return Vector2.ZERO


func _pick_author_point(player: Node2D) -> Vector2:
	## 在作者刷新点里挑一个同时满足"前方 + 屏外 + 距离带"的；没有就返回 ZERO 交给自动取点。
	var tree: SceneTree = get_tree()
	if tree == null:
		return Vector2.ZERO
	var all: Array = []
	_collect_spawn_nodes(tree.root, all)
	if all.is_empty():
		return Vector2.ZERO

	var view_half: Vector2 = _view_half_extents()
	var cam_center: Vector2 = _camera_center(player)
	var usable: Array = []
	for node: Node2D in all:
		if not is_instance_valid(node):
			continue
		if not _author_point_enabled(node):
			continue
		var base: Vector2 = _zone_center(node)
		if not is_in_band(player, base):
			continue
		if not _is_offscreen(base, cam_center, view_half):
			continue
		usable.append(node)
	if usable.is_empty():
		return Vector2.ZERO

	# 随机挑一个，并尝试若干次在区域内部取点（SpawnZone 是矩形区域）
	usable.shuffle()
	for _attempt: int in range(8):
		var node: Node2D = usable[_rng.randi_range(0, usable.size() - 1)]
		var pos: Vector2 = _author_point_position(node)
		if not is_in_band(player, pos):
			continue
		if not _is_offscreen(pos, cam_center, view_half):
			continue
		if not _director._is_walkable(pos):
			continue
		if _director._is_occupied_by_enemy(pos) or _director._was_recently_used(pos):
			continue
		return pos
	return Vector2.ZERO


func _author_point_enabled(node: Node2D) -> bool:
	if node is SpawnPoint:
		return (node as SpawnPoint).enabled
	if node is SpawnZone:
		return (node as SpawnZone).enabled
	return false


func _zone_center(node: Node2D) -> Vector2:
	return node.global_position


func _author_point_position(node: Node2D) -> Vector2:
	if node is SpawnZone:
		return (node as SpawnZone).get_random_position()
	return node.global_position


func _collect_spawn_nodes(node: Node, out: Array) -> void:
	## 与 Director._collect_spawn_nodes 同源（这里独立实现，避免子模块反向依赖父节点的私有方法细节）。
	if node is SpawnPoint or node is SpawnZone:
		out.append(node)
	for child: Node in node.get_children():
		_collect_spawn_nodes(child, out)


# ═══════════════════════════════════════
# 判定
# ═══════════════════════════════════════

func is_offscreen(player: Node2D, pos: Vector2) -> bool:
	## 对外暴露的"是否在屏幕之外"判定 —— 供其它生成路径（作者 SpawnZone 的区域补齐）
	## 复用同一套屏幕判定，避免"区域补齐"把敌人刷到玩家正看着的地方。
	return _is_offscreen(pos, _camera_center(player), _view_half_extents())


func is_in_band(player: Node2D, pos: Vector2) -> bool:
	## 是否落在「前方扇区 + 距离带」里（**不含**屏外判定，供计数与作者点筛选共用）。
	if player == null or not is_instance_valid(player):
		return false
	var delta: Vector2 = pos - player.global_position
	var dist: float = delta.length()
	if dist < min_dist or dist > max_dist:
		return false
	var dir: Vector2 = _last_dir
	if dir == Vector2.ZERO or dist < 0.001:
		return true
	return (delta / dist).dot(dir) >= cos(deg_to_rad(front_half_angle))


func count_ahead(player: Node2D) -> int:
	## 前方带内的存活敌人数 —— "这个范围里已经有多少丧尸"。
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0
	var count: int = 0
	for e: Node2D in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(e):
			continue
		if e.get("_is_dying") == true or e.get("_is_dead") == true:
			continue
		if is_in_band(player, e.global_position):
			count += 1
	return count


func _offscreen_distance(dir: Vector2, view_half: Vector2) -> float:
	## 沿 dir 方向走出可视矩形（含余量）所需的最小距离：取两个轴上"更早出界"的那个。
	var dx: float = absf(dir.x)
	var dy: float = absf(dir.y)
	var need_x: float = INF
	var need_y: float = INF
	if dx > 0.0001:
		need_x = (view_half.x + offscreen_margin) / dx
	if dy > 0.0001:
		need_y = (view_half.y + offscreen_margin) / dy
	var need: float = minf(need_x, need_y)
	if need == INF:
		return min_dist
	return need


func _is_offscreen(pos: Vector2, cam_center: Vector2, view_half: Vector2) -> bool:
	## 屏幕外 = 至少一个轴上超出可视半宽/半高 + 外扩。
	## ⚠ 必须是**至少一个轴**：仅用"圆外判定"会把屏幕四个角方向的可视区域算成屏外。
	var dx: float = absf(pos.x - cam_center.x)
	var dy: float = absf(pos.y - cam_center.y)
	return dx > view_half.x + offscreen_margin or dy > view_half.y + offscreen_margin


func _front_dir(player: Node2D) -> Vector2:
	## 前方方向：优先玩家实际移动方向（速度），静止时用朝向。
	var v: Variant = player.get("velocity")
	if v is Vector2 and (v as Vector2).length() > moving_speed_eps:
		return (v as Vector2).normalized()
	var f: Variant = player.get("facing")
	if f != null:
		match int(f):
			1: return Vector2.LEFT
			2: return Vector2.RIGHT
			3: return Vector2.UP
			_: return Vector2.DOWN
	return _last_dir


func _camera_center(player: Node2D) -> Vector2:
	var cam: Camera2D = _active_camera()
	if cam and is_instance_valid(cam):
		return cam.global_position
	return player.global_position


func _active_camera() -> Camera2D:
	var vp: Viewport = get_viewport()
	if vp == null:
		return null
	return vp.get_camera_2d()


func _view_half_extents() -> Vector2:
	## 相机可视范围的一半（世界单位）：视口尺寸 ÷ 相机缩放 ÷ 2。
	var half: Vector2 = fallback_view_size * 0.5
	var vp: Viewport = get_viewport()
	var cam: Camera2D = _active_camera()
	if vp == null or cam == null:
		return half
	var zoom: Vector2 = cam.zoom
	if zoom.x <= 0.001 or zoom.y <= 0.001:
		return half
	var size: Vector2 = vp.get_visible_rect().size
	return Vector2(size.x * 0.5 / zoom.x, size.y * 0.5 / zoom.y)


# ═══════════════════════════════════════
# 调试
# ═══════════════════════════════════════

func debug_state(player: Node2D) -> String:
	## 供现场抓取器 / 调试打印使用的一行摘要。
	var view_half: Vector2 = _view_half_extents()
	return "前方刷怪: 启用=%s 带内=%d/%d 距离=%.0f~%.0f 扇区=±%.0f° 屏外余量=%.0f 可视=%.0f×%.0f 前进累计=%.0f/%.0f 上次未刷=%s" % [
		str(enabled), count_ahead(player) if player else -1, target_ahead,
		min_dist, max_dist, front_half_angle, offscreen_margin,
		view_half.x * 2.0, view_half.y * 2.0, _advance_accum, advance_step, last_reject]


## 附近闸计数：玩家半径内存活的普通敌人（含特感）数量。
func _count_nearby(player: Node2D) -> int:
	var n: int = 0
	var r2: float = nearby_gate_radius * nearby_gate_radius
	for e: Node2D in player.get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(e) and e.global_position.distance_squared_to(player.global_position) <= r2:
			n += 1
	return n
