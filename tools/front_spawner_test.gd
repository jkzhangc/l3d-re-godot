extends Node2D
## 前方屏外定点刷怪（FrontSpawner）验证 harness —— headless 运行。
##
##   godot --headless --path <项目> res://tools/front_spawner_test.tscn
##
## 【为什么能脱离真实地图跑】
## FrontSpawner 只依赖 Director 的 5 个查询（可行走 / 占用 / 最近用过 / 装饰层 / 生成敌人），
## 以及相机可视范围。这里用 StubDirector 把接口桩掉，并自建一台 Camera2D（zoom=2），
## 就能断言"前方扇区 / 屏外 / 距离带 / 数量闸门 / 移动触发 / 作者点优先"这些性质。
##
## 【关键常量】视口 1280×960、相机缩放 2×（camera_follow.default_zoom）
## → 世界可视范围 640×480，半宽半高 (320, 240)。

const FRONT_SPAWNER := preload("res://script/director/front_spawner.gd")
const SPAWN_POINT := preload("res://script/director/spawn_point.gd")

const VIEW_HALF := Vector2(320, 240)   ## 可视半宽/半高（世界单位）
const FALLBACK_VIEW := Vector2(640, 480)


## ── 桩 Director：只实现 FrontSpawner 用到的接口 ──
class StubDirector extends Node:
	var decor: Node = null
	var spawned: Array = []
	var walkable: bool = true

	func _is_walkable(_pos: Vector2) -> bool:
		return walkable

	func _is_occupied_by_enemy(_pos: Vector2) -> bool:
		return false

	func _was_recently_used(_pos: Vector2) -> bool:
		return false

	func _find_decor_layer() -> Node:
		return decor

	func spawn_enemy(pos: Vector2, _decor_layer: Node, _facing: int = -1) -> Node2D:
		var e := Node2D.new()
		e.global_position = pos
		add_child(e)
		e.add_to_group("enemy")
		spawned.append(pos)
		return e


var _player: CharacterBody2D
var _cam: Camera2D
var _fs: Node
var _stub: StubDirector
var _checks: int = 0
var _failures: int = 0


func _ready() -> void:
	print("=== 前方屏外定点刷怪验证（FrontSpawner）===")
	_build_scene()
	_test_front_sector_and_band()
	_test_offscreen_only()
	_test_count_gate()
	_test_idle_gate()
	_test_move_trigger()
	_test_author_point_priority()
	print("=== FRONT_SPAWNER_TEST: %d/%d checks passed ===" % [_checks - _failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)


func _build_scene() -> void:
	# 相机（zoom=2 → 世界可视 640×480）
	_cam = Camera2D.new()
	_cam.zoom = Vector2(2, 2)
	add_child(_cam)
	_cam.make_current()

	# 玩家（无状态机，速度由测试代码手动设）
	_player = CharacterBody2D.new()
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(24, 27)
	cs.shape = shape
	_player.add_child(cs)
	add_child(_player)
	_player.global_position = Vector2(1000, 1000)
	_cam.global_position = Vector2(1000, 1000)

	_stub = StubDirector.new()
	_stub.name = "StubDirector"
	var decor := Node2D.new()
	decor.name = "DecorLayer"
	add_child(decor)
	_stub.decor = decor
	add_child(_stub)

	_fs = Node.new()
	_fs.name = "FrontSpawner"
	_fs.set_script(FRONT_SPAWNER)
	add_child(_fs)
	_fs.setup(_stub)
	_fs.set("min_dist", 360.0)
	_fs.set("max_dist", 900.0)
	_fs.set("front_half_angle", 60.0)
	_fs.set("offscreen_margin", 64.0)
	_fs.set("target_ahead", 6)
	_fs.set("batch", 2)
	_fs.set("advance_step", 160.0)
	_fs.set("interval_min", 0.0)
	_fs.set("spawn_when_idle", false)
	_fs.set("fallback_view_size", FALLBACK_VIEW)


func _clear_enemies() -> void:
	for e: Node in get_tree().get_nodes_in_group("enemy"):
		e.free()


func _front_positions(dir: Vector2, times: int) -> Array:
	## 先让模块按给定方向更新一次（写入内部 _last_dir），再连续取 times 个位置。
	_player.velocity = dir * 200.0
	_fs.update(0.016, _player, 0, &"build")
	var out: Array = []
	for _i in range(times):
		out.append(_fs.pick_ahead_position(_player))
	return out


# ═══════════════════════════════════════
# 用例
# ═══════════════════════════════════════

func _test_front_sector_and_band() -> void:
	## 只在前方 + 只在距离带内。
	_clear_enemies()
	var dir := Vector2.RIGHT
	var half_angle: float = _fs.get("front_half_angle")
	var min_d: float = _fs.get("min_dist")
	var max_d: float = _fs.get("max_dist")
	var worst_angle := 0.0
	var min_seen := 1e9
	var max_seen := 0.0
	var got := 0
	for pos: Vector2 in _front_positions(dir, 60):
		if pos == Vector2.ZERO:
			continue
		got += 1
		var d: Vector2 = pos - _player.global_position
		var dist: float = d.length()
		min_seen = minf(min_seen, dist)
		max_seen = maxf(max_seen, dist)
		worst_angle = maxf(worst_angle, absf(rad_to_deg(d.normalized().angle_to(dir))))
	_check(got >= 55, "能稳定取到位置（%d/60 次成功）" % got)
	_check(worst_angle <= half_angle + 0.5,
		"所有位置都在前方 ±%.0f° 扇区内（最大偏角 %.1f°）" % [half_angle, worst_angle])
	_check(min_seen >= min_d - 20.0 and max_seen <= max_d + 20.0,
		"所有位置都落在距离带 %.0f~%.0f 内（实测 %.1f~%.1f）" % [min_d, max_d, min_seen, max_seen])


func _test_offscreen_only() -> void:
	## "看不见"：所有取点至少有一轴超出可视边缘 + offscreen_margin。
	_clear_enemies()
	var margin: float = _fs.get("offscreen_margin")
	var min_clear := 1e9
	var inside := 0
	var dirs: Array[Vector2] = [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN,
		Vector2(1, 1).normalized(), Vector2(-1, 1).normalized()]
	for dir: Vector2 in dirs:
		_cam.global_position = _player.global_position
		for pos: Vector2 in _front_positions(dir, 20):
			if pos == Vector2.ZERO:
				continue
			var d: Vector2 = pos - _cam.global_position
			var over: float = maxf(absf(d.x) - VIEW_HALF.x, absf(d.y) - VIEW_HALF.y)
			if over < margin:
				inside += 1
			min_clear = minf(min_clear, over)
	_check(inside == 0, "没有任何位置落在可视范围附近（违规 %d 个）" % inside)
	_check(min_clear >= margin - 0.5,
		"所有位置至少超出可视边缘 %.0fpx（实测最小超出 %.1fpx）" % [margin, min_clear])


func _test_count_gate() -> void:
	## 前方带内已有 target_ahead 只 → 一只都不刷。
	_clear_enemies()
	var dir := Vector2.RIGHT
	_player.velocity = dir * 200.0
	_fs.update(0.016, _player, 0, &"build")
	var target: int = _fs.get("target_ahead")
	for i in range(target + 3):
		_stub.spawn_enemy(_player.global_position + dir * (700.0 + float(i) * 24.0), _stub.decor, -1)
	_check(_fs.count_ahead(_player) >= target,
		"带内计数把前方敌人算进来（%d ≥ %d）" % [_fs.count_ahead(_player), target])

	var before: int = _stub.spawned.size()
	_player.global_position += dir * 400.0
	_cam.global_position = _player.global_position
	var made: int = _fs.update(0.5, _player, 0, &"build")
	_check(made == 0 and _stub.spawned.size() == before,
		"带内数量达标 → 不刷（本次 %d 只，带内 %d/%d）" % [made, _fs.count_ahead(_player), target])

	_clear_enemies()
	_player.global_position += dir * 400.0
	_cam.global_position = _player.global_position
	var made2: int = _fs.update(0.5, _player, 0, &"build")
	_check(made2 > 0, "带内清空后恢复补位（本次 %d 只）" % made2)


func _test_idle_gate() -> void:
	## 原地不动（spawn_when_idle=false）→ 不刷。
	_clear_enemies()
	_player.velocity = Vector2.ZERO
	var before: int = _stub.spawned.size()
	var total := 0
	for _i in range(20):
		total += _fs.update(0.5, _player, 0, &"build")   # 累计 10 秒
	_check(total == 0 and _stub.spawned.size() == before,
		"静止 10 秒不刷怪（本次 %d 只）" % total)

	_fs.set("spawn_when_idle", true)
	var made := 0
	for _i in range(6):
		made += _fs.update(0.5, _player, 0, &"build")
	_check(made > 0, "打开 spawn_when_idle 后静止也会补位（%d 只）" % made)
	_fs.set("spawn_when_idle", false)


func _test_move_trigger() -> void:
	## 玩家前进累计到 advance_step 就补一批 —— 修"走得快时前方空窗"。
	_clear_enemies()
	var dir := Vector2.RIGHT
	var step: float = _fs.get("advance_step")
	var made := 0
	var advanced := 0.0
	_player.velocity = dir * 960.0
	for _i in range(200):
		_player.global_position += dir * 16.0
		advanced += 16.0
		_cam.global_position = _player.global_position
		made += _fs.update(0.016, _player, 0, &"build")
	_check(made > 0, "玩家移动时持续补位（前进 %.0fpx 共补 %d 只）" % [advanced, made])
	var expect_batches: int = int(advanced / step) - 1
	_check(made >= mini(expect_batches, 5),
		"补位次数与前进距离挂钩（前进 %.0fpx / step %.0f → 预期 ≥ %d 批，实得 %d）" % [
			advanced, step, mini(expect_batches, 5), made])


func _test_author_point_priority() -> void:
	## 关卡作者的刷新点在"前方 + 屏外"时优先使用；在背后时忽略。
	_clear_enemies()
	var dir := Vector2.RIGHT
	_player.velocity = dir * 200.0
	_fs.update(0.016, _player, 0, &"build")

	var sp: Node2D = SPAWN_POINT.new()
	sp.set("enabled", true)
	add_child(sp)
	sp.global_position = _player.global_position + dir * 700.0
	var pos: Vector2 = _fs.pick_ahead_position(_player)
	_check(pos.distance_to(sp.global_position) < 0.01,
		"前方屏外的作者刷新点被优先使用（取到 (%.0f,%.0f)，刷新点 (%.0f,%.0f)）" % [
			pos.x, pos.y, sp.global_position.x, sp.global_position.y])

	sp.global_position = _player.global_position - dir * 700.0
	var pos2: Vector2 = _fs.pick_ahead_position(_player)
	_check(pos2.distance_to(sp.global_position) > 1.0,
		"背后的作者刷新点被忽略（取到 (%.0f,%.0f)）" % [pos2.x, pos2.y])
	sp.free()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)
