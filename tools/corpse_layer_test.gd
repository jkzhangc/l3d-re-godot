extends Node2D
## 尸体层级回归 —— headless 验证。
##
## 【为什么存在】用户规则：丧尸尸体必须永远画在**所有活体单位之下**。
## 实现方式是死亡时 reparent 到 GroundLayer —— 它在树序上早于 DecorLayer，而玩家与敌人
## 全部挂在 DecorLayer（y_sort）里，于是尸体自然落在「地面图块之上、所有单位之下」。
##
## 这条规则第一次只写在了 _become_corpse() 那条**兜底**路径里，而真正生效的三条路径
## （普通死亡态 / 爆头死亡态 / Client 联机表现）全都漏了 —— 尸体留在 DecorLayer 按 y 排序，
## 站到玩家南侧时就盖住玩家（用户报「丧尸死亡后行走图有时候在玩家上方」）。
##
## 本测试把「所有死亡路径的产物都必须落进 GroundLayer」钉成回归项。
##
## 用法："$GD" --headless --path <项目> res://tools/corpse_layer_test.tscn

const MAP := preload("res://scene/maps/突袭-第一关-街道.tscn")
const ENEMY_SCENE := preload("res://object/enemy.tscn")

var _checks: int = 0
var _fails: int = 0
var _scene: Node = null
var _decor: Node2D = null
var _ground: Node2D = null


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("[PASS] %s" % label)
	else:
		_fails += 1
		print("[FAIL] %s" % label)


func _ready() -> void:
	_scene = MAP.instantiate()
	add_child(_scene)
	for i in range(60):
		await get_tree().physics_frame

	_ground = _scene.find_child("GroundLayer", true, false) as Node2D
	_decor = _scene.find_child("DecorLayer", true, false) as Node2D
	_check(_ground != null and _decor != null, "地图里能定位 GroundLayer / DecorLayer")
	if _ground == null or _decor == null:
		_finish()
		return

	# 绘制顺序依据：同 z 的兄弟节点按树序先画 → GroundLayer 必须排在 DecorLayer 之前
	_check(_ground.get_index() < _decor.get_index(),
		"GroundLayer 树序早于 DecorLayer（%d < %d）" % [_ground.get_index(), _decor.get_index()])

	await _check_path("普通死亡", false, 6)
	await _check_path("爆头死亡", true, 45)
	await _check_client_death()
	_finish()

func _finish() -> void:
	print("=== CORPSE_LAYER_TEST: %d/%d checks passed ===" % [_checks - _fails, _checks])
	get_tree().quit(0 if _fails == 0 else 1)


## Host 侧两条状态机死亡路径：_die() → 对应死亡状态 → _register_corpse()
func _check_path(label: String, is_headshot: bool, settle_frames: int) -> void:
	var e: Node2D = _spawn_enemy()
	e._die(is_headshot)
	# 记录死亡瞬间坐标：reparent 前后必须保持不变
	var at_death: Vector2 = e.global_position
	for i in range(settle_frames):
		await get_tree().physics_frame

	_check(e.get_parent() == _ground,
		"%s：尸体落在 GroundLayer（实际父节点 = %s）" % [label, _parent_name(e)])
	_check(e.z_index == 0, "%s：z_index = 0（实际 %d）" % [label, e.z_index])
	var moved: float = (e.global_position - at_death).length()
	_check(moved < 0.01, "%s：reparent 不产生位移（%.4f px）" % [label, moved])
	_check_below_units(e, label)
	e.queue_free()
	await get_tree().physics_frame


## Client 侧表现死亡：apply_network_death() 不走 _register_corpse()，必须单独接贴地
func _check_client_death() -> void:
	var e: Node2D = _spawn_enemy()
	e.configure_network_entity(9999, true)
	e.apply_network_death(false)
	for i in range(6):
		await get_tree().physics_frame

	_check(e.get_parent() == _ground,
		"Client 表现死亡：尸体落在 GroundLayer（实际父节点 = %s）" % _parent_name(e))
	_check(e.z_index == 0, "Client 表现死亡：z_index = 0（实际 %d）" % e.z_index)
	_check_below_units(e, "Client 表现死亡")
	e.queue_free()
	await get_tree().physics_frame


## 规则本体：尸体的「有效 z」必须低于所有活体单位（z_as_relative 时 = 父链 z 累加）。
## 单位（player.tscn / enemy.tscn / teammate_standin.tscn）都是 z_index = 1，
## 尸体被摆到 GroundLayer 且 z=0 → 有效 z 为 0，天然低于单位。
func _check_below_units(corpse: CanvasItem, label: String) -> void:
	var refs: Array[Dictionary] = [
		{"name": "玩家", "node": _scene.find_child("Player", true, false) as CanvasItem},
		{"name": "活着的敌人", "node": _spawn_enemy() as CanvasItem},
	]
	for ref: Dictionary in refs:
		var other: CanvasItem = ref["node"]
		if other == null or not is_instance_valid(other):
			_check(false, "%s：找不到参照单位 %s" % [label, ref["name"]])
			continue
		_check(_effective_z(corpse) < _effective_z(other),
			"%s：有效 z 低于%s（%d < %d）" % [label, ref["name"], _effective_z(corpse), _effective_z(other)])
		if ref["name"] == "活着的敌人":
			other.queue_free()


## CanvasItem 的有效 z：z_as_relative 为真时逐级累加父链
func _effective_z(item: CanvasItem) -> int:
	var z: int = item.z_index
	if not item.z_as_relative:
		return z
	var parent := item.get_parent()
	while parent is CanvasItem:
		var p := parent as CanvasItem
		z += p.z_index
		if not p.z_as_relative:
			break
		parent = p.get_parent()
	return z


func _spawn_enemy() -> Node2D:
	var p: Node2D = _scene.find_child("Player", true, false) as Node2D
	var base: Vector2 = p.global_position if p else Vector2.ZERO
	var e: Node2D = ENEMY_SCENE.instantiate() as Node2D
	_decor.add_child(e)
	e.global_position = base + Vector2(48, 48)
	return e


func _parent_name(node: Node) -> String:
	var par := node.get_parent()
	return str(par.name) if par else "无"
