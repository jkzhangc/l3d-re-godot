class_name SafeDoor extends Node2D
## 安全门实体：使用 VX Ace 行走图显示，玩家靠近并按“确定键”后进入目标安全屋。
## 联机时由 NetworkWorld 验证所有已连接玩家都在同一扇门附近且分别确认，才统一切图。

const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

@export_file("*.tscn") var target_scene: String = ""
@export var walk_texture: Texture2D
@export_range(0, 7, 1) var walk_char_index: int = 0
@export_range(0, 3, 1) var walk_direction: int = 0

@export_group("踏步动画")
@export var step_frames: Array[int] = [1]
@export_range(0.02, 5.0, 0.01) var step_duration: float = 0.25
@export var animated: bool = false

@export_group("交互")
@export var interact_label: String = "进入安全屋"
@export_range(8.0, 512.0, 1.0) var interact_range: float = 56.0

@export_group("进入效果")
@export var heal_on_enter: bool = false
@export var reset_pacing: bool = true

var _player_ref: Node2D = null
var _can_interact: bool = false
var _transitioning: bool = false
var _step_index: int = 0
var _step_timer: float = 0.0
var _network_ready_count: int = 0
var _network_total_count: int = 0
var _local_network_ready: bool = false


func _ready() -> void:
	if target_scene.is_empty():
		push_warning("[SafeDoor] target_scene 未设置")
	if step_frames.is_empty():
		step_frames = [1]
	_ensure_children()
	_step_timer = step_duration
	_refresh_sprite()
	_update_label()


func _process(delta: float) -> void:
	# 静态门也必须持续检查距离；不能像旧 TeleportPoint 那样随动画一起 return。
	if animated and step_frames.size() > 1:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(step_duration, 0.02)
			_step_index = (_step_index + 1) % step_frames.size()
			_refresh_sprite()
	_check_player_proximity()


func _unhandled_input(event: InputEvent) -> void:
	if _transitioning or not _can_interact:
		return
	if event.is_action_pressed("确定键"):
		get_viewport().set_input_as_handled()
		_enter_safe_room()


func _ensure_children() -> void:
	var sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not sprite:
		sprite = Sprite2D.new()
		sprite.name = "Sprite2D"
		sprite.centered = true
		add_child(sprite)

	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		label = Label.new()
		label.name = "HintLabel"
		label.position = Vector2(-72, -62)
		label.size = Vector2(144, 28)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.32))
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		label.add_theme_constant_override("shadow_offset_x", 2)
		label.add_theme_constant_override("shadow_offset_y", 2)
		add_child(label)


func _refresh_sprite() -> void:
	var sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not sprite:
		return
	sprite.texture = walk_texture
	sprite.visible = walk_texture != null
	if not walk_texture:
		return

	sprite.region_enabled = true
	var frame_index: int = clampi(step_frames[_step_index], 0, 2)
	var char_col: int = walk_char_index % CHARS_PER_ROW
	var char_row: int = walk_char_index / CHARS_PER_ROW
	var x: int = char_col * FRAME_W * 3 + frame_index * FRAME_W
	var y: int = char_row * FRAME_H * DIRECTIONS + walk_direction * FRAME_H
	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


func _is_online_session() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net and net.has_method("is_online_session") and bool(net.is_online_session())


func _check_player_proximity() -> void:
	# 联机提示只能基于本机操控的角色，不能因远端玩家靠近而在本机显示可交互。
	var candidate: Node2D = Players.get_local_entity() if _is_online_session() else Players.nearest_entity_to(global_position)
	_player_ref = candidate
	_can_interact = (
		candidate != null
		and is_instance_valid(candidate)
		and candidate.global_position.distance_to(global_position) <= interact_range
		and not _transitioning
	)
	_update_label()


func _update_label() -> void:
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		return
	if _is_online_session() and _network_total_count > 0:
		label.text = "%s  [确定键]  (%d/%d 已准备)" % [interact_label, _network_ready_count, _network_total_count]
	else:
		label.text = "%s  [确定键]" % interact_label
	label.visible = _can_interact and not _transitioning


func get_network_door_key() -> String:
	var scene := get_tree().current_scene
	return str(scene.get_path_to(self)) if scene else ""


func apply_network_ready_status(ready_count: int, total_count: int, local_ready: bool) -> void:
	_network_ready_count = maxi(0, ready_count)
	_network_total_count = maxi(0, total_count)
	_local_network_ready = local_ready
	_update_label()


func begin_network_transition() -> void:
	_transitioning = true
	_can_interact = false
	_update_label()


func _enter_safe_room() -> void:
	if target_scene.is_empty() or not ResourceLoader.exists(target_scene):
		printerr("[SafeDoor] 无法进入安全屋，目标场景不存在: %s" % target_scene)
		return

	var net: Node = get_node_or_null("/root/Net")
	var online: bool = false
	if net and net.has_method("is_online_session"):
		online = bool(net.is_online_session())
	if online:
		var scene := get_tree().current_scene
		var world: Node = scene.find_child("NetworkWorld", true, false) if scene else null
		if world and world.has_method("request_safe_door_ready"):
			# 不在本地切图/冻结；只登记本玩家对这一扇门的准备意图。
			world.request_safe_door_ready(get_network_door_key())
			return
		push_warning("[SafeDoor] 联机世界未就绪，忽略安全门请求")
		return

	begin_network_transition()
	_apply_entry_effects()
	_finish_chapter()
	print("[SafeDoor] 进入安全屋: %s" % target_scene)
	get_tree().change_scene_to_file.call_deferred(target_scene)


func commit_host_network_entry() -> void:
	## 只由 Host 的 NetworkWorld 在验证所有玩家到位后调用。
	if _transitioning:
		return
	begin_network_transition()
	_apply_entry_effects()
	_finish_chapter()
	print("[SafeDoor] Host 统一进入安全屋: %s" % target_scene)
	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("request_scene_change"):
		net.request_scene_change(target_scene)


func _finish_chapter() -> void:
	var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
	if chapter_stats and chapter_stats.has_method("finish_chapter"):
		chapter_stats.finish_chapter()


func _apply_entry_effects() -> void:
	if heal_on_enter:
		for entity: Node2D in Players.all_entities(false):
			var state: PlayerState = Players.get_state_for_entity(entity)
			if not state:
				continue
			state.current_hp = state.get_max_hp()
			if entity.get("current_hp") != null:
				entity.set("current_hp", state.current_hp)

	if reset_pacing:
		var director: Node = get_node_or_null("/root/Director")
		if director:
			var controller: Node = director.get_node_or_null("PacingController")
			if controller and controller.has_method("force_cooldown"):
				controller.force_cooldown()
