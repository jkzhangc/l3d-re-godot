extends Node2D
## 像素级蹭墙 / 拐角平滑（corner assist）验证 harness —— headless 运行。
##
## 运行：
##   godot --headless --path <项目> res://tools/corner_assist_test.tscn
##
## 【场景构造】
##   · 横墙 1（y 64~96）：中间留 32px 门洞（x 0~32），左右各一段实体墙。
##     玩家碰撞体 24×27、门洞 32 → 中心只有落在 [door_left+12, door_right-12] 才穿得过去。
##   · 横墙 2（y 160~192）：整段无开口，用于验证"斜向顶墙仍能沿墙滑行"。
##
## 【用例】
##   0 关闭辅助 + 偏离 3px 正向进门 → 应卡住（反证，复现原缺陷）
##   1 开启辅助 + 偏离 3px 正向进门 → 应穿过，且侧移是"多帧小幅"而非一帧瞬移
##   2 开启辅助 + 偏离 6px 斜向进门（向右下）→ 应穿过，且穿门瞬间落在门洞区间内
##   3 开启辅助 + 偏离 3px 斜向进门（向左下）→ 应穿过，且穿门瞬间落在门洞区间内
##   4 开启辅助 + 斜向顶住无开口长墙 → 应沿墙面滑行（x 持续增加）但不穿墙
##
## 注意：判定"是否被修正到门洞区间"必须在**穿门那一瞬间**取 x，而不是终点 x ——
## 角色穿过门后仍会按输入继续横向漂移，终点 x 不能反映修正效果。

const PLAYER_SCENE := preload("res://object/player.tscn")
const ENEMY_SCENE := preload("res://object/enemy.tscn")
const CHARACTER_PATH := "res://object/character_nobita.tres"

const DOOR_LEFT := 0.0
const DOOR_RIGHT := 32.0
const WALL_TOP := 64.0
const WALL_BOTTOM := 96.0
const WALL_THICK := 32.0
const WALL_EXTENT := 64.0

const FLAT_WALL_TOP := 160.0
const FLAT_WALL_LEFT := -64.0
const FLAT_WALL_WIDTH := 800.0

const DOOR_PASS_Y := 130.0     ## 越过此 y 视为穿过门洞墙
const FLAT_PASS_Y := 200.0     ## 越过此 y 视为穿过无开口长墙（不该发生）

var _player: CharacterBody2D
var _enemy: CharacterBody2D
var _body: CharacterBody2D      ## 当前用例驱动的实体
var _half := Vector2(12.0, 13.5)
var _half_x: float = 12.0        ## 当前实体的碰撞体半宽（用于门洞可通过区间）

var _scenarios: Array[Dictionary] = []
var _idx := 0
var _frames := 0
var _x_cleared := 0.0
var _max_step_x := 0.0
var _max_step_y := 0.0
var _lateral_frames := 0
var _results: Array[Dictionary] = []

var _checks := 0
var _failures := 0


func _ready() -> void:
	print("=== 像素级蹭墙 / 拐角平滑验证 ===")
	_build_walls()
	_player = PLAYER_SCENE.instantiate()
	_player.current_character = load(CHARACTER_PATH) as CharacterData
	add_child(_player)
	_read_half_extents()
	_disable_state_machine()
	_enemy = ENEMY_SCENE.instantiate() as CharacterBody2D
	add_child(_enemy)
	_enemy.set_process(false)
	var esm: Node = _enemy.get_node_or_null("StateMachine")
	if esm:
		esm.set_process(false)
		esm.set_physics_process(false)
	_build_scenarios()
	_begin(0)


func _build_walls() -> void:
	# 带门洞的横墙
	_add_wall(Rect2(DOOR_LEFT - WALL_EXTENT, WALL_TOP, WALL_EXTENT, WALL_THICK))
	_add_wall(Rect2(DOOR_RIGHT, WALL_TOP, WALL_EXTENT, WALL_THICK))
	# 无开口的长墙（贴墙滑行用）
	_add_wall(Rect2(FLAT_WALL_LEFT, FLAT_WALL_TOP, FLAT_WALL_WIDTH, WALL_THICK))
	# 动态层（敌人层 = 层4 = bit 8）碰撞体：仅用于验证蹭墙探测会忽略它。
	# 位置远离所有用例路径，不会干扰实际移动。
	_add_wall(Rect2(-80, -20, 48, 40), 8)


func _add_wall(rect: Rect2, layer: int = 1) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = rect.size
	cs.shape = shape
	cs.position = rect.position + rect.size * 0.5
	body.add_child(cs)
	add_child(body)


func _read_half_extents() -> void:
	var cs: CollisionShape2D = _player.get_node_or_null("CollisionShape2D")
	if cs and cs.shape is RectangleShape2D:
		_half = (cs.shape as RectangleShape2D).size * 0.5


## 读取某实体的碰撞体半尺寸（玩家与敌人尺寸不同，门洞可通过区间随之不同）。
func _half_of(body: CharacterBody2D) -> Vector2:
	var cs: CollisionShape2D = body.get_node_or_null("CollisionShape2D")
	if cs and cs.shape is RectangleShape2D:
		return (cs.shape as RectangleShape2D).size * 0.5
	return Vector2(12.0, 13.5)


func _disable_state_machine() -> void:
	# 关闭状态机：本测试直接驱动 velocity + move_with_corner_assist，
	# 避免 Idle/Walk/Run 把速度改回 0。
	var sm: Node = _player.get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)


func _build_scenarios() -> void:
	_scenarios = [
		{
			"name": "关闭辅助：偏离 3px 正向进门",
			"assist": false, "dir": Vector2(0, 1), "start": Vector2(9, 44),
			"pass_y": DOOR_PASS_Y, "max_frames": 120, "track_door": true,
		},
		{
			"name": "开启辅助：偏离 3px 正向进门",
			"assist": true, "dir": Vector2(0, 1), "start": Vector2(9, 44),
			"pass_y": DOOR_PASS_Y, "max_frames": 120, "track_door": true,
		},
		{
			"name": "开启辅助：偏离 6px 斜向进门（右下）",
			"assist": true, "dir": Vector2(0.25, 0.97), "start": Vector2(6, 44),
			"pass_y": DOOR_PASS_Y, "max_frames": 120, "track_door": true,
		},
		{
			"name": "开启辅助：偏离 3px 斜向进门（左下）",
			"assist": true, "dir": Vector2(-0.25, 0.97), "start": Vector2(23, 44),
			"pass_y": DOOR_PASS_Y, "max_frames": 120, "track_door": true,
		},
		{
			"name": "开启辅助：斜向顶住无开口长墙",
			"assist": true, "dir": Vector2(0.7, 0.7), "start": Vector2(40, FLAT_WALL_TOP - 46.0),
			"pass_y": FLAT_PASS_Y, "max_frames": 90, "track_door": false,
		},
		# ── 敌人（与玩家共用 CornerAssist，碰撞体 20×28）──
		{
			"name": "敌人 / 关闭辅助：偏离 8px 正向进门",
			"assist": false, "dir": Vector2(0, 1), "start": Vector2(8, 46),
			"pass_y": DOOR_PASS_Y, "max_frames": 150, "track_door": true, "use_enemy": true,
		},
		{
			"name": "敌人 / 开启辅助：偏离 8px 正向进门",
			"assist": true, "dir": Vector2(0, 1), "start": Vector2(8, 46),
			"pass_y": DOOR_PASS_Y, "max_frames": 150, "track_door": true, "use_enemy": true,
		},
	]


func _begin(i: int) -> void:
	_idx = i
	_frames = 0
	_max_step_x = 0.0
	_max_step_y = 0.0
	_lateral_frames = 0
	_x_cleared = NAN
	var sc: Dictionary = _scenarios[i]
	_body = _enemy if bool(sc.get("use_enemy", false)) else _player
	_half_x = _half_of(_body).x
	_body.corner_assist_enabled = sc["assist"]
	_body.velocity = Vector2.ZERO
	_body.global_position = sc["start"]


func _physics_process(_delta: float) -> void:
	if _body == null or _idx >= _scenarios.size():
		return

	var sc: Dictionary = _scenarios[_idx]
	_frames += 1

	_body.velocity = (sc["dir"] as Vector2).normalized() * 250.0
	var before: Vector2 = _body.global_position
	_body.move_with_corner_assist()
	var step: Vector2 = _body.global_position - before

	_max_step_x = maxf(_max_step_x, absf(step.x))
	_max_step_y = maxf(_max_step_y, absf(step.y))
	# 用例 1 的输入是纯向下，任何横向位移都只可能来自蹭墙修正
	if absf(step.x) > 0.05:
		_lateral_frames += 1

	# 记录"刚穿过门洞墙"那一刻的 x（此刻还没开始门后的横向漂移）
	if bool(sc["track_door"]) and is_nan(_x_cleared) \
			and _body.global_position.y >= WALL_BOTTOM + _half_of(_body).y:
		_x_cleared = _body.global_position.x

	var end_y: float = _body.global_position.y
	if end_y >= float(sc["pass_y"]) or _frames >= int(sc["max_frames"]):
		_results.append({
			"name": sc["name"],
			"start": sc["start"],
			"end": _body.global_position,
			"half_x": _half_x,
			"speed_limit": _body.corner_assist_speed / 60.0,
			"x_cleared": _x_cleared,
			"passed": end_y >= float(sc["pass_y"]),
			"frames": _frames,
			"max_x": _max_step_x,
			"max_y": _max_step_y,
			"lateral_frames": _lateral_frames,
		})
		if _idx + 1 < _scenarios.size():
			_begin(_idx + 1)
		else:
			_finish()


func _finish() -> void:
	for r in _results:
		var e: Vector2 = r["end"]
		var xc: float = r["x_cleared"]
		print("--- %s：终点 (%.1f, %.1f)，穿门瞬间 x=%s，%d 帧，单帧位移上限 x=%.2f y=%.2f"
			% [r["name"], e.x, e.y, ("--" if is_nan(xc) else "%.1f" % xc),
				r["frames"], r["max_x"], r["max_y"]])

	_test_world_mask_isolation()

	var min_x: float = DOOR_LEFT + _half.x          ## 玩家可通过区间
	var max_x: float = DOOR_RIGHT - _half.x
	var speed_limit: float = float(_results[1]["speed_limit"])
	var slack: float = 0.8                           ## 容差（物理步进与浮点）

	var off: Dictionary = _results[0]
	var on: Dictionary = _results[1]
	var diag_r: Dictionary = _results[2]
	var diag_l: Dictionary = _results[3]
	var flat: Dictionary = _results[4]
	var e_off: Dictionary = _results[5]
	var e_on: Dictionary = _results[6]

	# 用例 0：反证 —— 关闭辅助必须卡住
	_check(not bool(off["passed"]), "关闭辅助：偏离 3px 时卡在门框（终点 y=%.1f）" % (off["end"] as Vector2).y)
	_check(absf((off["end"] as Vector2).x - (off["start"] as Vector2).x) < 0.5,
		"关闭辅助：没有横向位移（无瞬移、无漂移）")

	# 用例 1：开启辅助必须穿过，且是「多帧小幅」的平滑侧移
	_check(bool(on["passed"]), "开启辅助：偏离 3px 仍能穿过 32px 门洞（y=%.1f）" % (on["end"] as Vector2).y)
	_check(_in_door(on), "侧移后中心落在可通过区间 [%.1f, %.1f] 内（穿门瞬间 x=%.1f）"
		% [min_x, max_x, on["x_cleared"]])
	_check(float(on["x_cleared"]) > (on["start"] as Vector2).x + 1.0,
		"侧移方向指向门洞（Δx=%.1f）" % (float(on["x_cleared"]) - (on["start"] as Vector2).x))
	_check(float(on["max_x"]) <= speed_limit + slack,
		"侧移被限速：单帧最大横向位移 %.2f ≤ %.2f px（无瞬移）" % [on["max_x"], speed_limit + slack])
	_check(int(on["lateral_frames"]) >= 2,
		"侧移分散在多帧完成（横向位移帧数 %d ≥ 2，即平滑蹭过去）" % on["lateral_frames"])

	# 用例 2 / 3：斜向进门，正反两侧的修正都应生效。
	# 带横向分量的输入在门内会持续漂移，所以这里断言「修正方向正确」而不是卡死区间；
	# 区间精度由用例 1（纯纵向输入、无横向漂移）保证。
	_check(bool(diag_r["passed"]), "斜向（右下）靠近同一门洞 → 穿过（y=%.1f）" % (diag_r["end"] as Vector2).y)
	_check(float(diag_r["x_cleared"]) > (diag_r["start"] as Vector2).x + 1.0,
		"斜向右下：被向右修正进门（穿门瞬间 x=%.1f）" % diag_r["x_cleared"])
	_check(bool(diag_l["passed"]), "斜向（左下）靠近同一门洞 → 穿过（y=%.1f）" % (diag_l["end"] as Vector2).y)
	_check(float(diag_l["x_cleared"]) < (diag_l["start"] as Vector2).x - 1.0,
		"斜向左下：被向左修正进门（穿门瞬间 x=%.1f）" % diag_l["x_cleared"])

	# 用例 4：顶住无开口长墙 —— 应沿墙滑行，但不穿墙
	var flat_end: Vector2 = flat["end"]
	var flat_start: Vector2 = flat["start"]
	_check(not bool(flat["passed"]), "顶住无开口长墙：无法穿过（终点 y=%.1f）" % flat_end.y)
	_check(flat_end.x > flat_start.x + 20.0,
		"顶住无开口长墙：仍沿墙面滑行出去（Δx=%.1f）" % (flat_end.x - flat_start.x))
	_check(flat_end.y <= FLAT_WALL_TOP - 4.0,
		"顶住无开口长墙：没有嵌进墙体（y=%.1f ≤ %.1f）" % [flat_end.y, FLAT_WALL_TOP - 4.0])

	# 用例 5 / 6：敌人（与玩家共用 CornerAssist）。敌人碰撞体 20×28 → 可通过区间更宽。
	var e_min: float = DOOR_LEFT + float(e_on["half_x"])
	var e_max: float = DOOR_RIGHT - float(e_on["half_x"])
	_check(not bool(e_off["passed"]),
		"敌人 / 关闭辅助：偏离 8px 卡在门框（终点 y=%.1f）" % (e_off["end"] as Vector2).y)
	_check(bool(e_on["passed"]),
		"敌人 / 开启辅助：偏离 8px 仍能穿过 32px 门洞（y=%.1f）" % (e_on["end"] as Vector2).y)
	_check(float(e_on["x_cleared"]) >= e_min - 0.5 and float(e_on["x_cleared"]) <= e_max + 0.5,
		"敌人：穿门瞬间中心落在可通过区间 [%.1f, %.1f] 内（x=%.1f）" % [e_min, e_max, e_on["x_cleared"]])
	_check(float(e_on["x_cleared"]) > (e_on["start"] as Vector2).x + 1.0,
		"敌人：侧移方向指向门洞（Δx=%.1f）" % (float(e_on["x_cleared"]) - (e_on["start"] as Vector2).x))
	_check(float(e_on["max_x"]) <= float(e_on["speed_limit"]) + slack,
		"敌人侧移被限速：单帧最大横向位移 %.2f ≤ %.2f px" % [e_on["max_x"], float(e_on["speed_limit"]) + slack])

	# 全用例守卫：单帧总位移不得超过「移动 250px/s + 侧移限速」的预算，
	# 否则说明出现了整块瞬移（早期实现就是一次性把修正量全加上去）。
	var worst: float = 0.0
	var worst_name: String = ""
	var worst_budget: float = 0.0
	for r in _results:
		var m: float = maxf(float(r["max_x"]), float(r["max_y"]))
		if m > worst:
			worst = m
			worst_name = r["name"]
			worst_budget = 250.0 / 60.0 + float(r["speed_limit"]) + slack
	_check(worst <= worst_budget,
		"所有用例单帧位移都在预算内（最大 %.2f ≤ %.2f，来自「%s」）" % [worst, worst_budget, worst_name])

	print("=== CORNER_ASSIST_TEST: %d/%d checks passed ===" % [_checks - _failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)


func _in_door(r: Dictionary) -> bool:
	var x: float = r["x_cleared"]
	if is_nan(x):
		return false
	return x >= DOOR_LEFT + _half.x - 0.5 and x <= DOOR_RIGHT - _half.x + 0.5


## 蹭墙探测必须只针对静态墙面。玩家的 collision_mask 含「敌人」层（bit 8），而导演会持续
## 在玩家身边刷怪；若不收窄掩码，路过的丧尸会把探测判为阻挡，蹭墙就会"时不时失效"。
func _test_world_mask_isolation() -> void:
	var gt := Transform2D(0.0, Vector2.ZERO)
	var motion := Vector2(-30, 0)   ## 朝动态体方向推进
	_check(CornerAssist._hits(_player, gt, motion, _player.collision_mask),
		"满掩码（%d）时「敌人层」碰撞体被判为阻挡" % _player.collision_mask)
	_check(not CornerAssist._hits(_player, gt, motion, 1),
		"仅图块层时「敌人层」碰撞体被排除（蹭墙不被丧尸干扰）")
	_check(_player.corner_assist_world_mask == 1,
		"玩家默认只把图块层算作静态墙面（world_mask=%d）" % _player.corner_assist_world_mask)


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)
