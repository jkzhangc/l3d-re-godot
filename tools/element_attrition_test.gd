extends Node

## ── 架构定位 ──
## 系统：属性/削り回归测试 ｜ 层：tools（headless harness）
## 职责：夹具实证属性结算（炎=燃烧 DoT、雷=感电硬直、氷=冻结+1.5 倍、抗性拦截）
##       与削り（酸命中削减弹夹、Heat 封锁见切）。
## 运行：godot --headless --path <proj> res://tools/element_attrition_test.tscn （需 EXIT 0）

const PLAYER_SCENE := preload("res://object/player.tscn")
const ENEMY_SCENE := preload("res://object/enemy.tscn")
const NOBITA_PATH := "res://object/character_nobita.tres"

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


func _spawn_enemy(pos: Vector2) -> Node2D:
	var e: Node2D = ENEMY_SCENE.instantiate()
	add_child(e)
	e.global_position = pos
	return e


func _ready() -> void:
	print("=== ELEMENT_ATTRITION_TEST ===")
	# ── 搭台：玩家（注册座位，主槽默认手枪）+ 敌人夹具 ──
	_player = PLAYER_SCENE.instantiate()
	add_child(_player)
	await get_tree().process_frame
	var state: PlayerState = PlayerState.new()
	var cd: CharacterData = (load(NOBITA_PATH) as CharacterData).duplicate()
	state.init_from_character(cd, NOBITA_PATH)
	var seat: int = Players.add_seat(state)
	Players.register_entity(_player, seat)
	await get_tree().process_frame

	# ── 1. 炎：命中点燃 + 燃烧 DoT（燃烧中仍会攻击，非即效性）──
	var e1: Node2D = _spawn_enemy(Vector2(400, 0))
	await get_tree().process_frame
	var hp0: float = float(e1.get("current_hp"))
	e1.take_damage(10.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0, 1)  # FIRE
	_check("炎属性命中点燃（_burning_time>0）", float(e1.get("_burning_time")) > 0.0)
	e1._update_element_status(1.0)
	e1._update_element_status(1.0)
	var hp1: float = float(e1.get("current_hp"))
	_check("燃烧 DoT 持续掉血（%.0f → %.0f）" % [hp0, hp1], hp1 < hp0 - 10.0)

	# ── 2. 雷：感电（攻击不能，长硬直）──
	var e2: Node2D = _spawn_enemy(Vector2(400, 60))
	await get_tree().process_frame
	e2.take_damage(10.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0, 2)  # LIGHTNING
	_check("雷属性命中感电（_electro_time>0）", float(e2.get("_electro_time")) > 0.0)
	_check("感电附加 3s 硬直（攻击不能）", float(e2.get("_hitstun_duration")) >= 3.0)

	# ── 3. 氷：冻结 + 冻结中受 1.5 倍 ──
	var e3: Node2D = _spawn_enemy(Vector2(400, 120))
	await get_tree().process_frame
	e3.take_damage(10.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0, 3)  # ICE
	_check("氷属性命中冻结（_frozen_time>0）", float(e3.get("_frozen_time")) > 0.0)
	var hp_f: float = float(e3.get("current_hp"))
	e3.take_damage(10.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0, 0)  # 无属性补刀
	var dropped: float = hp_f - float(e3.get("current_hp"))
	_check("冻结中受 1.5 倍伤害（实际掉 %.1f，期望 15.0）" % dropped, absf(dropped - 15.0) < 0.51)

	# ── 4. 抗性：炎抗性敌人不被点燃 ──
	var e4: Node2D = _spawn_enemy(Vector2(400, 180))
	e4.set("resist_fire", true)
	await get_tree().process_frame
	e4.take_damage(10.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0, 1)  # FIRE
	_check("炎抗性拦截燃烧", float(e4.get("_burning_time")) == 0.0)

	# ── 5. 削り：酸命中 → 主武器弹夹 -2 ──
	var wd: WeaponData = state.get_active_weapon()
	var mag_before: int = state.get_magazine_ammo(wd.item_id)
	_player.take_damage(5.0, 0.0, Vector2.UP, false, 0.0, 0.0, 0, 4, false)  # ACID
	var mag_after: int = state.get_magazine_ammo(wd.item_id)
	_check("酸命中触发削り（弹夹 %d → %d，-2）" % [mag_before, mag_after], mag_after == mag_before - 2)

	# ── 6. Heat：禁止见切（窗口内攻击仍生效）──
	_player.take_damage(5.0, 0.0, Vector2.UP, false, 0.0, 0.0, 0, 0, true)  # causes_heat
	_check("Heat 攻击命中进入 Heat 状态", _player.is_heat_active())
	_player._mukiri_last_attempt_msec = -10000
	_player._try_mukiri_input()
	var php: float = float(_player.get("current_hp"))
	_player.take_damage(5.0, 0.0, Vector2.UP, false, 0.0, 0.0, 0, 0, false)
	var php_after: float = float(_player.get("current_hp"))
	_check("Heat 中见切失效（HP %.0f → %.0f，伤害生效）" % [php, php_after], php_after < php)

	print("=== ELEMENT_ATTRITION_TEST: %d/%d checks passed ===" % [_passed, _checks])
	get_tree().quit(0 if _passed == _checks else 1)
