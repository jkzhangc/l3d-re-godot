class_name CharacterSwitchManager extends Node
## 角色切换管理器 — 处理 Q/Ctrl+1-3 切换、队友静态精灵、死亡切换
##
## 添加到关卡场景根节点（由 GameInit 自动创建），管理:
##   1. Q/数字键切换
##   2. 队友静态精灵的创建/更新/销毁
##   3. 切换时的镜头/状态迁移
##   4. 死亡后自动切换

@export var switch_cooldown: float = 0.5
@export var teammate_scene: PackedScene = preload("res://object/teammate_standin.tscn")

var _player: CharacterBody2D = null
var _camera: Camera2D = null
var _teammate_nodes: Array[Node2D] = []  ## 队友静态精灵节点列表，索引对应 team 索引
var _cooldown_timer: float = 0.0
var _team_size: int = 0

# ═══════════════════════════════════════
# 精灵帧常量（与 player.gd 一致）
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
const STAND_FRAME: int = 1
const DIR_ROWS: Array[int] = [0, 1, 2, 3]


func _ready() -> void:
	add_to_group("character_switch_manager")
	_team_size = Global.get_team_size()
	if _team_size <= 1:
		set_process(false)
		set_process_input(false)
		return
	_player = _find_player()
	_camera = _find_camera()
	_create_teammate_sprites()
	set_process(true)
	set_process_input(true)
	print("[SwitchMgr] 就绪 team=%d player=%s camera=%s" % [_team_size, str(_player), str(_camera)])


func _find_player() -> CharacterBody2D:
	var nodes: Array[Node] = get_tree().get_nodes_in_group("player")
	for node: Node in nodes:
		if node is CharacterBody2D and is_instance_valid(node):
			return node as CharacterBody2D
	return null


func _find_camera() -> Camera2D:
	if not get_tree() or not get_tree().current_scene:
		return null
	var cameras: Array[Node] = []
	_find_cameras_recursive(get_tree().current_scene, cameras)
	if cameras.size() > 0:
		return cameras[0] as Camera2D
	return null


func _find_cameras_recursive(node: Node, out_arr: Array) -> void:
	if node is Camera2D:
		out_arr.append(node)
	for child: Node in node.get_children():
		_find_cameras_recursive(child, out_arr)


# ═══════════════════════════════════════
# 队友静态精灵
# ═══════════════════════════════════════

func _create_teammate_sprites() -> void:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var decor: Node = tree.current_scene.find_child("DecorLayer", true, false)
	for i: int in range(_team_size):
		if i == Global.current_team_index:
			_teammate_nodes.append(null)
			continue
		var standin: Node2D = _create_standin_node(i, decor if decor else tree.current_scene)
		_teammate_nodes.append(standin)


func _create_standin_node(index: int, parent: Node) -> Node2D:
	var standin: Node2D = teammate_scene.instantiate()
	standin.name = "TeammateStandin_%d" % index
	standin.z_index = 1
	var member: Dictionary = Global.team[index]
	var pos: Vector2 = member.get("position", _get_default_spawn_pos())
	standin.position = pos
	_apply_standin_appearance(standin, member)
	parent.add_child(standin)
	return standin


func _get_default_spawn_pos() -> Vector2:
	if _player:
		return _player.global_position
	var tree := get_tree()
	if tree and tree.current_scene:
		var spawn: Node = tree.current_scene.find_child("PlayerSpawn", true, false)
		if spawn and spawn is Node2D:
			return (spawn as Node2D).position
	return Vector2(160, 160)


func _apply_standin_appearance(standin: Node2D, member: Dictionary) -> void:
	var cd: CharacterData = member.get("character") as CharacterData
	if not cd or not cd.walk_texture:
		return
	var sprite: Sprite2D = standin.get_node_or_null("Sprite2D")
	if not sprite:
		return
	sprite.texture = cd.walk_texture
	sprite.region_enabled = true
	var facing: int = member.get("facing", 0)
	var char_idx: int = cd.walk_char_index
	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var dir_row: int = DIR_ROWS[facing]
	var x: int = char_col * (FRAME_W * 3) + STAND_FRAME * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


func _remove_teammate_standin(index: int) -> void:
	if index < 0 or index >= _teammate_nodes.size():
		return
	var standin: Node2D = _teammate_nodes[index]
	if standin and is_instance_valid(standin):
		standin.queue_free()
	_teammate_nodes[index] = null


func _update_standin_from_player(old_index: int) -> void:
	if old_index < 0 or old_index >= _teammate_nodes.size():
		return
	var standin: Node2D = _teammate_nodes[old_index]
	if not standin or not is_instance_valid(standin):
		_create_standin_for_index(old_index)
		return
	if _player:
		standin.position = _player.global_position
	var member: Dictionary = Global.team[old_index]
	_apply_standin_appearance(standin, member)


func _create_standin_for_index(index: int) -> void:
	if index < 0 or index >= _team_size:
		return
	if index == Global.current_team_index:
		return
	while _teammate_nodes.size() <= index:
		_teammate_nodes.append(null)
	if _teammate_nodes[index] and is_instance_valid(_teammate_nodes[index]):
		return
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var decor: Node = tree.current_scene.find_child("DecorLayer", true, false)
	var parent: Node = decor if decor else tree.current_scene
	var standin: Node2D = _create_standin_node(index, parent)
	_teammate_nodes[index] = standin


# ═══════════════════════════════════════
# 输入处理
# ═══════════════════════════════════════

func _input(event: InputEvent) -> void:
	if _team_size <= 1:
		return
	if _cooldown_timer > 0.0:
		return

	var target_index: int = -1

	if event.is_action_pressed("切换角色键"):
		target_index = _find_next_living_member()
	elif event.is_action_pressed("选择队员1键"):
		target_index = 0
	elif event.is_action_pressed("选择队员2键"):
		target_index = 1
	elif event.is_action_pressed("选择队员3键"):
		target_index = 2
	else:
		return

	if target_index < 0 or target_index >= _team_size:
		return
	if target_index == Global.current_team_index:
		return
	var member: Dictionary = Global.team[target_index]
	if member.get("current_hp", 0.0) <= 0.0:
		return

	_do_switch(target_index)
	_cooldown_timer = switch_cooldown


func _process(delta: float) -> void:
	if _cooldown_timer > 0.0:
		_cooldown_timer -= delta


func _find_next_living_member() -> int:
	var size: int = _team_size
	for offset: int in range(1, size):
		var idx: int = (Global.current_team_index + offset) % size
		var member: Dictionary = Global.team[idx]
		if member.get("current_hp", 0.0) > 0.0:
			return idx
	return -1


# ═══════════════════════════════════════
# 切换逻辑
# ═══════════════════════════════════════

func _do_switch(target_index: int) -> void:
	if not _player:
		_player = _find_player()
	if not _player:
		return

	var old_index: int = Global.current_team_index

	# 1. 保存当前队员状态
	_save_current_player_state()

	# 2. 更新当前队员的站立精灵 / 位置
	_update_standin_from_player(old_index)

	# 3. 加载目标队员
	Global._save_global_to_team_member(old_index)
	Global.set_active_team_index(target_index)

	# 4. 销毁目标队员的站立精灵（他变成了 Player）
	_remove_teammate_standin(target_index)

	# 5. 为刚才操控的队员创建站立精灵
	_create_standin_for_index(old_index)

	# 6. 刷新玩家外观和状态
	_player.refresh_after_switch()

	# 7. 玩家跳到目标队员之前的位置
	var saved_pos: Vector2 = Global.team[target_index].get("position", _player.global_position)
	_player.global_position = saved_pos

	# 8. 镜头瞬切
	if _camera:
		_camera.position = _player.global_position

	print("[SwitchMgr] 切换 %d→%d pos=%s" % [old_index, target_index, str(_player.global_position)])


func _save_current_player_state() -> void:
	if not _player:
		return
	var member: Dictionary = Global.get_current_team_member()
	if member.is_empty():
		return
	member["facing"] = _player.facing
	member["position"] = _player.global_position


# ═══════════════════════════════════════
# 死亡切换
# ═══════════════════════════════════════

## 死亡后自动切换到下一存活队员。返回 true 表示切换成功。
func switch_after_death() -> bool:
	var next_idx: int = _find_next_living_member()
	if next_idx < 0:
		return false

	var old_index: int = Global.current_team_index

	# 保存死亡队员位置
	_save_current_player_state()
	# 更新站立精灵（当前队员已死到此位置）
	_update_standin_from_player(old_index)

	Global._save_global_to_team_member(old_index)
	Global.set_active_team_index(next_idx)

	_remove_teammate_standin(next_idx)
	_create_standin_for_index(old_index)

	if not _player:
		_player = _find_player()
	if not _player:
		return false

	# 恢复玩家（清死亡状态）
	_player._is_dying = false
	_player._death_phase = 0
	_player._switch_on_death_attempted = false

	# 恢复状态机
	var sm: Node = _player.get_node_or_null("StateMachine")
	if sm:
		sm.set_process(true)
		sm.set_physics_process(true)
		var idle: State = sm.states.get("Idle") if sm.has_method("get") else sm.get_node_or_null("Idle")
		if idle and sm.current_state:
			sm.current_state.exit()
			sm.current_state = idle
			idle.enter()

	# 恢复碰撞
	var cs: CollisionShape2D = _player.get_node_or_null("CollisionShape2D")
	if cs:
		cs.set_deferred("disabled", false)
	if _player.hurt_area:
		_player.hurt_area.set_deferred("monitoring", true)
		_player.hurt_area.set_deferred("monitorable", true)

	# 恢复动画 timer
	if _player.animation_timer:
		_player.animation_timer.start()

	# 刷新外观 & 镜头
	_player.refresh_after_switch()
	var saved_pos: Vector2 = Global.team[next_idx].get("position", _player.global_position)
	_player.global_position = saved_pos
	_player._moving = false
	_player.velocity = Vector2.ZERO
	_player.queue_redraw()

	if _camera:
		_camera.position = _player.global_position

	print("[SwitchMgr] 死亡切换 %d→%d" % [old_index, next_idx])
	return true
