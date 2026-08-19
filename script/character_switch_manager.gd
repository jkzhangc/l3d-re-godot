class_name CharacterSwitchManager extends Node
## 角色切换管理器 — 处理 Q/Ctrl+1-3 切换、队友静态精灵、死亡切换
##
## 添加到关卡场景根节点（由 GameInit 自动创建），管理:
##   1. Q/数字键切换
##   2. 队友静态精灵的创建/更新/销毁（可选，默认关闭）
##   3. 切换时的镜头/状态迁移
##   4. 死亡后自动切换

@export var switch_cooldown: float = 0.5
@export var teammate_scene: PackedScene = preload("res://object/teammate_standin.tscn")
## 是否在地图上显示未操控队友的站立精灵（L4D2 风格）
@export var show_teammate_standins: bool = false

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
	_team_size = Players.seat_count()
	if _team_size <= 1:
		set_process(false)
		set_process_input(false)
		return
	_player = Players.get_local_entity() as CharacterBody2D
	_camera = _find_camera()
	if show_teammate_standins:
		_create_teammate_sprites()
	set_process(true)
	set_process_input(true)
	print("[SwitchMgr] 就绪 team=%d player=%s camera=%s standins=%s" % [_team_size, str(_player), str(_camera), str(show_teammate_standins)])


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
	if not show_teammate_standins:
		return
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var decor: Node = tree.current_scene.find_child("DecorLayer", true, false)
	for i: int in range(_team_size):
		if i == Players.active_seat_index:
			_teammate_nodes.append(null)
			continue
		var standin: Node2D = _create_standin_node(i, decor if decor else tree.current_scene)
		_teammate_nodes.append(standin)


func _create_standin_node(index: int, parent: Node) -> Node2D:
	var standin: Node2D = teammate_scene.instantiate()
	standin.name = "TeammateStandin_%d" % index
	standin.z_index = 1
	var st: PlayerState = Players.get_seat(index)
	# 位置同步到当前玩家位置（避免 Vector2.ZERO 导致出现在地图原点）
	var pos: Vector2 = st.position if st else Vector2.ZERO
	if pos == Vector2.ZERO and _player:
		pos = _player.global_position
		if st:
			st.position = pos
	standin.position = pos
	_apply_standin_appearance(standin, st)
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


func _apply_standin_appearance(standin: Node2D, st: PlayerState) -> void:
	if not st:
		return
	var cd: CharacterData = st.character
	if not cd or not cd.walk_texture:
		return
	var sprite: Sprite2D = standin.get_node_or_null("Sprite2D")
	if not sprite:
		return
	sprite.texture = cd.walk_texture
	sprite.region_enabled = true
	var facing: int = st.facing
	var char_idx: int = cd.walk_char_index
	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var dir_row: int = DIR_ROWS[facing]
	var x: int = char_col * (FRAME_W * 3) + STAND_FRAME * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


func _remove_teammate_standin(index: int) -> void:
	if not show_teammate_standins:
		return
	if index < 0 or index >= _teammate_nodes.size():
		return
	var standin: Node2D = _teammate_nodes[index]
	if standin and is_instance_valid(standin):
		standin.queue_free()
	_teammate_nodes[index] = null


func _update_standin_from_player(old_index: int) -> void:
	if not show_teammate_standins:
		return
	if old_index < 0 or old_index >= _teammate_nodes.size():
		return
	var standin: Node2D = _teammate_nodes[old_index]
	if not standin or not is_instance_valid(standin):
		_create_standin_for_index(old_index)
		return
	if _player:
		standin.position = _player.global_position
	_apply_standin_appearance(standin, Players.get_seat(old_index))


func _create_standin_for_index(index: int) -> void:
	if not show_teammate_standins:
		return
	if index < 0 or index >= _team_size:
		return
	if index == Players.active_seat_index:
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
	if target_index == Players.active_seat_index:
		return
	var target_state: PlayerState = Players.get_seat(target_index)
	if not target_state or not target_state.is_alive():
		return

	_do_switch(target_index)
	_cooldown_timer = switch_cooldown


func _process(delta: float) -> void:
	if _cooldown_timer > 0.0:
		_cooldown_timer -= delta


func _find_next_living_member() -> int:
	return Players.next_living_seat(Players.active_seat_index)


# ═══════════════════════════════════════
# 切换逻辑
# ═══════════════════════════════════════

func _do_switch(target_index: int) -> void:
	if not _player:
		_player = Players.get_local_entity() as CharacterBody2D
	if not _player:
		return

	var old_index: int = Players.active_seat_index

	# 1. 把玩家节点上的位姿写回当前座位
	_save_current_player_state()

	# 2. 更新当前队员的站立精灵 / 位置
	_update_standin_from_player(old_index)

	# 3. 换绑到目标座位（不再逐字段拷贝 —— 座位本身就是那份状态）
	Players.set_active_seat(target_index)

	# 4. 销毁目标队员的站立精灵（他变成了 Player）
	_remove_teammate_standin(target_index)

	# 5. 为刚才操控的队员创建站立精灵
	_create_standin_for_index(old_index)

	# 6. 重置状态机为 Idle（防止切换时卡在攻击/武器状态）
	_reset_player_state_machine()

	# 7. 刷新玩家外观和状态
	_player.refresh_after_switch()

	# 8. 保持当前玩家位置（切换角色直接替换，不传送）
	# 同时更新目标座位的位置为当前位置（保证数据一致）
	var target_state: PlayerState = Players.get_seat(target_index)
	if target_state:
		target_state.position = _player.global_position

	# 9. 镜头不瞬切：切换角色不改玩家位置（设计上不传送），相机继续阻尼跟随即可。
	#    旧实现调 teleport_to_player()，玩家移动时会把阻尼滞后的相机瞬拉到玩家位置，
	#    造成可见跳变（小地图下还会与 limit 居中钳制冲突）。仅当未来切换改为传送玩家时才需恢复瞬切。
	print("[SwitchMgr] 切换 %d→%d pos=%s" % [old_index, target_index, str(_player.global_position)])


func _save_current_player_state() -> void:
	if not _player:
		return
	var st: PlayerState = Players.get_active_state()
	st.facing = _player.facing
	st.position = _player.global_position


func _reset_player_state_machine() -> void:
	if not _player:
		return
	var sm: Node = _player.get_node_or_null("StateMachine")
	if not sm:
		return
	if sm.current_state:
		sm.current_state.exit()
	# 尝试切换到 Idle 状态
	var idle: State = null
	if sm.get("states") is Dictionary:
		idle = sm.states.get("Idle")
	else:
		idle = sm.get_node_or_null("Idle")
	if idle:
		sm.current_state = idle
		idle.enter()


# ═══════════════════════════════════════
# 死亡切换
# ═══════════════════════════════════════

## 死亡后自动切换到下一存活队员。返回 true 表示切换成功。
func switch_after_death() -> bool:
	var next_idx: int = _find_next_living_member()
	if next_idx < 0:
		return false

	var old_index: int = Players.active_seat_index

	# 保存死亡队员位置
	_save_current_player_state()
	# 更新站立精灵（当前队员已死到此位置）
	_update_standin_from_player(old_index)

	Players.set_active_seat(next_idx)

	_remove_teammate_standin(next_idx)
	_create_standin_for_index(old_index)

	if not _player:
		_player = Players.get_local_entity() as CharacterBody2D
	if not _player:
		return false

	# 恢复玩家（清死亡状态）
	_player._is_dying = false
	_player._death_phase = 0
	_player._switch_on_death_attempted = false

	# 恢复状态机
	_reset_player_state_machine()
	var sm: Node = _player.get_node_or_null("StateMachine")
	if sm:
		sm.set_process(true)
		sm.set_physics_process(true)

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
	# 保持当前玩家位置（死亡切换不传送）
	var next_state: PlayerState = Players.get_seat(next_idx)
	if next_state:
		next_state.position = _player.global_position
	_player._moving = false
	_player.velocity = Vector2.ZERO
	_player.queue_redraw()

	# 镜头不瞬切（同 _do_switch）：死亡切换保持玩家位置不变，相机继续阻尼跟随。
	print("[SwitchMgr] 死亡切换 %d→%d" % [old_index, next_idx])
	return true
