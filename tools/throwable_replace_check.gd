extends Node

## 投掷物「站在掉落物上按 D 换不了」回归（2026-11-04）。
## 用法：godot --headless --path . res://tools/throwable_replace_check.tscn
##
## 病象（用户两次反馈）：已经拿着手雷/燃烧瓶，站到另一个投掷物上按 D 没反应。
## 根因：`healing_pickup` 的替换路径上有一道 `player_in_weapon_state` 闸门 ——
## 而本作玩家绝大多数时间举着武器，于是「替换」几乎永远不触发。
## D 只在**投掷物已举起/瞄准**时被减格键占用，那条判据是 `Players.local_player_is_throwing()`。
##
## 断言：
##  1. 举着武器（player_in_weapon_state=true）时，替换仍算「按 D 有效」→ can_use_function_key() = true；
##  2. 同状态下 `_needs_key_press()` = true（键帽/按住流程才会走）；
##  3. 投掷物已举起（in_throwable_state=true）时仍然让位（D 归减格键）→ false。

const PICKUP_SCENE := preload("res://object/healing_pickup.tscn")
const PLAYER_SCENE := preload("res://object/player.tscn")
const GRENADE := preload("res://object/item_grenade.tres")

var _fail := 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _ready() -> void:
	var director: Node = get_node_or_null("/root/Director")
	if director != null:
		director.set("auto_spawn_enabled", false)
	await get_tree().process_frame

	var player: Node2D = PLAYER_SCENE.instantiate()
	player.global_position = Vector2(100, 100)
	add_child(player)
	await get_tree().process_frame

	var state: PlayerState = Players.get_state_for_entity(player)
	_check("玩家已绑定座位", state != null, true)
	state.throwable = GRENADE
	state.throwable_count = 1

	var pickup: Node2D = PICKUP_SCENE.instantiate()
	pickup.set("item", GRENADE)
	pickup.global_position = Vector2(100, 100)
	add_child(pickup)
	await get_tree().process_frame
	pickup.set("_player_ref", player)
	pickup.set("_player_in_range", true)
	pickup.set("_spawn_msec", 0)   ## 越过「刚掉落的短冷却」

	print("=== 1) 举着武器时，投掷物替换必须可用 ===")
	player.set("player_in_weapon_state", true)
	_check("can_use_function_key()", pickup.call("can_use_function_key"), true)
	_check("_needs_key_press()", pickup.call("_needs_key_press", state), true)

	print("=== 2) 投掷物已举起/瞄准时让位（D 归减格键） ===")
	player.set("in_throwable_state", true)
	_check("can_use_function_key() 让位", pickup.call("can_use_function_key"), false)
	_check("_needs_key_press() 仍为真（只是不占键）", pickup.call("_needs_key_press", state), true)
	player.set("in_throwable_state", false)

	print("=== 3) 源码闸门：替换路径不得再出现 player_in_weapon_state ===")
	var src := _read("res://script/healing_pickup.gd")
	## 只允许出现在注释里；代码行里出现即为回退。
	var code_hits: int = 0
	for line: String in src.split("\n"):
		var t: String = line.strip_edges()
		if t.begins_with("#"):
			continue
		if t.contains("player_in_weapon_state"):
			code_hits += 1
	_check("非注释行出现次数", code_hits, 0)

	pickup.queue_free()
	player.queue_free()
	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""
