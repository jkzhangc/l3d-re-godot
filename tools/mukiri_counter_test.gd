extends Node

## ── 架构定位 ──
## 系统：见切/反击回归测试 ｜ 层：tools（headless harness）
## 职责：夹具实证见切输入窗口/输入间隔/反击扇形/一闪即死/反击冷却。
## 运行：godot --headless --path <proj> res://tools/mukiri_counter_test.tscn （需 EXIT 0）

const PLAYER_SCENE := preload("res://object/player.tscn")
const ENEMY_SCENE := preload("res://object/enemy.tscn")
const SHIZUKA := preload("res://object/character_shizuka.tres")

var _checks: int = 0
var _passed: int = 0
var _player: CharacterBody2D = null


func _check(name: String, cond: bool) -> void:
	_checks += 1
	if cond:
		_passed += 1
		print("  [PASS] " + name)
	else:
		print("  [FAIL] " + name)


func _spawn_enemy(offset: Vector2) -> Node2D:
	var e: Node2D = ENEMY_SCENE.instantiate()
	add_child(e)
	e.global_position = _player.global_position + offset
	return e


func _ready() -> void:
	print("=== MUKIRI_COUNTER_TEST ===")
	# ── 搭台：静香（counter=issen）+ 敌人夹具 ──
	_player = PLAYER_SCENE.instantiate()
	add_child(_player)
	_player.current_character = SHIZUKA
	_player.max_hp = 100.0
	_player.current_hp = 100.0
	_player._facing = 0  # FaceDir.DOWN：前方 = +Y
	await get_tree().process_frame
	await get_tree().process_frame

	# ── 1. 见切输入窗口：按键后 0.3s 内的攻击被无效化 ──
	_player._try_mukiri_input()
	var negated: bool = _player._should_negate_hit(10.0)
	_check("见切窗口内的攻击被无效化", negated)
	_check("见切成功后窗口关闭（不重复触发）", not _player._should_negate_hit(10.0))

	# ── 2. 输入间隔 0.7s：窗口刚关闭就再按键不会重新开窗 ──
	_player._try_mukiri_input()
	_check("0.7s 输入间隔内再按键不开新窗口", not _player._should_negate_hit(10.0))

	# ── 3. 一闪反击：前方扇形内敌人即死 ──
	# （检查 1/2 的无效化已按"见切→反击"规则消耗过一次反击冷却，重置后单独检验反击本体）
	_player._counter_cooldown_until_msec = 0
	var front: Node2D = _spawn_enemy(Vector2(0, 50))
	await get_tree().process_frame
	var front_hp_before: float = float(front.get("current_hp"))
	_player._try_counter()
	var front_dead: bool = front.get("_is_dead") == true or float(front.get("current_hp")) <= 0.0
	_check("一闪反击命中前方敌人（原 HP %.0f）" % front_hp_before, front_dead)
	_check("一闪即死（无视威力直接清空 HP）", front_dead and front_hp_before > 0.0)

	# ── 4. 反击扇形：背后敌人不吃反击 ──
	var behind: Node2D = _spawn_enemy(Vector2(0, -50))
	await get_tree().process_frame
	var behind_hp_before: float = float(behind.get("current_hp"))
	_player._counter_cooldown_until_msec = 0  # 冷却已由上一次反击启动，重置以单独检验扇形
	_player._try_counter()
	_check("背后敌人不受反击（HP %.0f → %.0f）" % [behind_hp_before, float(behind.get("current_hp"))],
		float(behind.get("current_hp")) == behind_hp_before)

	# ── 5. 反击冷却：1s 内连续触发不再命中 ──
	var again: Node2D = _spawn_enemy(Vector2(0, 50))
	await get_tree().process_frame
	var again_hp_before: float = float(again.get("current_hp"))
	_player._try_counter()  # 上一步消耗了冷却
	_check("反击冷却期内不重复命中", float(again.get("current_hp")) == again_hp_before)

	# ── 6. 见切成功时玩家不掉血 ──
	_player._mukiri_last_attempt_msec = -10000  # 重置输入间隔
	_player._try_mukiri_input()
	var hp_before: float = _player.current_hp
	_player.take_damage(25.0, 0.0, Vector2.UP, false, 0.0, 0.0, 0)
	_check("见切期间玩家 HP 不变（%.0f → %.0f）" % [hp_before, _player.current_hp],
		_player.current_hp == hp_before)

	print("=== MUKIRI_COUNTER_TEST: %d/%d checks passed ===" % [_passed, _checks])
	get_tree().quit(0 if _passed == _checks else 1)
