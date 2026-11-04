extends Node

## 狂暴→普通形态切换后「走路没有动画、直接平移」回归（2026-11-04）。
## 用法：godot --headless --path . res://tools/rage_walk_anim_check.tscn
##
## 病象（用户实测）：尸潮结束、僵尸从クリムゾンヘッド变回普通形态后，**有一部分**丧尸
## 移动时不再踏步，整张贴图平移。
##
## 分两层查：
##  A. 贴图管线 —— 手动驱动 `update_moving(true)` + timer 回调，帧区必须轮转；
##  B. 真实状态机 —— 造一个假玩家让敌人进 Chase，跑一遍「狂暴 → 恢复」，
##     `_moving` 必须一直为 true 且帧区仍在轮转（状态层把 _moving 弄丢 = 平移）。
## 卡在哪个断言，就说明问题在哪一层。

const ENEMY_SCENE := preload("res://object/enemy.tscn")
const RAGE_TEX := preload("res://art/Characters/学生クリムゾンヘッド1.png")
const SAMPLES: int = 8

var _fail := 0


## 假玩家：`_is_player_body()` 只要求 CharacterBody2D + get_weapon_data() + HP>0。
class FakePlayer extends CharacterBody2D:
	var current_hp: float = 100.0
	var _is_dying: bool = false

	func get_weapon_data() -> Variant:
		return null

	## 让敌人攻击能正常收招（否则敌人会一直卡在 Attack，测不到后续状态）。
	func take_damage(_damage: float, _knockback: float, _dir: Vector2, _crit: bool = false,
			_knock_dur: float = 0.0, _hitstun: float = 0.0, _source_id: int = 0,
			_element: int = 0, _explosive: bool = false, _shooter: Node = null,
			_source_is_player_origin: bool = true) -> void:
		pass


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


## 直接驱动贴图管线（绕开状态机，Idle 会周期性 update_moving(false)）。
func _pipeline_frames(enemy: Node2D) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for _i: int in range(SAMPLES):
		enemy.update_moving(true)
		enemy.call("_on_animation_timer_timeout")
		out.append(enemy.sprite.region_rect)
	return out


## 真实运行（状态机在跑）时的采样：只读，不干预。
func _live_frames(enemy: Node2D) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var sm: Node = enemy.get_node("StateMachine")
	for _i: int in range(SAMPLES):
		await get_tree().create_timer(0.05).timeout
		out.append(enemy.sprite.region_rect)
		print("    · state=%s move=%s idx=%d step=%d rect=%s" % [
			str(sm.call("current_state_name")), str(enemy.get("_moving")),
			int(enemy.get("walk_char_index")), int(enemy.get("_anim_step")),
			str(enemy.sprite.region_rect.position)])
	return out


func _distinct(frames: Array[Rect2]) -> int:
	var seen: Dictionary = {}
	for r: Rect2 in frames:
		seen[r] = true
	return seen.size()


func _ready() -> void:
	var director: Node = get_node_or_null("/root/Director")
	if director != null:
		director.set("auto_spawn_enabled", false)
	await get_tree().process_frame

	var player := FakePlayer.new()
	player.global_position = Vector2(320, 0)
	add_child(player)

	var enemy: Node2D = ENEMY_SCENE.instantiate()
	enemy.variant_rage_texture = RAGE_TEX
	enemy.variant_rage_move_speed = 300.0
	enemy.global_position = Vector2.ZERO
	add_child(enemy)
	await get_tree().process_frame

	## 直接进 Chase（不走发现流程：无视野、无地图也能测移动态）。
	enemy.set("_player_ref", player)
	enemy.get_node("StateMachine").call("_on_transition_requested", "Chase")
	await get_tree().process_frame
	_check("已进入 Chase", String(enemy.get_node("StateMachine").call("current_state_name")), "Chase")
	_check("Chase 中 _moving = true", bool(enemy.get("_moving")), true)

	print("=== A) 贴图管线：狂暴 ↔ 普通都要轮帧 ===")
	enemy.set_rage(true)
	var rage_pipe: Array[Rect2] = _pipeline_frames(enemy)
	_check("狂暴管线帧种类 >= 2", _distinct(rage_pipe) >= 2, true)
	enemy.set_rage(false)
	var normal_pipe: Array[Rect2] = _pipeline_frames(enemy)
	_check("普通管线帧种类 >= 2", _distinct(normal_pipe) >= 2, true)

	print("=== B) 真实状态机：狂暴 → 恢复后仍要踏步 ===")
	enemy.set_rage(true)
	await get_tree().create_timer(0.2).timeout
	_check("狂暴期 _moving 仍为 true", bool(enemy.get("_moving")), true)
	var rage_live: Array[Rect2] = await _live_frames(enemy)
	_check("狂暴期在踏步", _distinct(rage_live) >= 2, true)

	enemy.set_rage(false)
	await get_tree().process_frame
	_check("恢复后 _moving 仍为 true", bool(enemy.get("_moving")), true)
	_check("恢复后 timer 未停", enemy.animation_timer.is_stopped(), false)
	var normal_live: Array[Rect2] = await _live_frames(enemy)
	_check("恢复后在踏步", _distinct(normal_live) >= 2, true)
	print("  · 恢复后帧: %s" % str(normal_live))

	print("=== C) 攻击中解除狂暴 → 攻击结束后必须恢复踏步 ===")
	## 尸潮峰值结束的那一刻，场上大量僵尸正处在 Attack（停表 + 固定帧）。
	var sm: Node = enemy.get_node("StateMachine")
	enemy.set_rage(true)
	sm.call("_on_transition_requested", "Attack")
	await get_tree().process_frame
	await get_tree().process_frame
	_check("攻击中 timer 已停", enemy.animation_timer.is_stopped(), true)
	enemy.set_rage(false)                       ## 峰值在这一刻结束
	## 把假玩家挪走：否则攻击收招后立刻又进下一轮 Attack，测不到"回到移动"。
	player.global_position = Vector2(4000, 4000)
	await get_tree().create_timer(1.2).timeout
	sm.call("_on_transition_requested", "Chase")
	await get_tree().process_frame
	await get_tree().process_frame
	print("  · 攻击结束后 state=%s" % str(sm.call("current_state_name")))
	_check("攻击后 timer 已恢复", enemy.animation_timer.is_stopped(), false)
	_check("攻击后 _moving = true", bool(enemy.get("_moving")), true)
	var after_attack: Array[Rect2] = await _live_frames(enemy)
	_check("攻击后仍在踏步", _distinct(after_attack) >= 2, true)

	print("=== D) 停表自愈：移动中被停表，下一帧必须自动拉起 ===")
	## 关掉状态机，避免它覆盖 _moving / 改状态，单独验自愈逻辑本身。
	sm.set_process(false)
	sm.set_physics_process(false)
	enemy.update_moving(true)
	enemy.animation_timer.stop()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("普通移动态：自愈后 timer 已重启", enemy.animation_timer.is_stopped(), false)

	print("=== E) 动作表期间不得自愈（攻击/突进的停表是刻意的） ===")
	enemy.push_action_texture(RAGE_TEX)
	enemy.animation_timer.stop()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("动作表期间保持停表", enemy.animation_timer.is_stopped(), true)
	enemy.restore_walk_texture()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("恢复行走表后 timer 回到运行", enemy.animation_timer.is_stopped(), false)

	enemy.queue_free()
	player.queue_free()
	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)
