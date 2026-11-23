@tool
extends Node2D

## ── 架构定位 ──
## 系统：油桶搬运 ｜ 层：玩法（Node2D，地图机关）
## 联机：Host 权威（交付/计数/装满）；Client 发请求，状态由 NetworkWorld 广播。
## 职责：油桶容器。玩家持桶靠近按功能键(D)交付；装满后切换行走图/索引，
##       播放指定尸潮 BGM，并提升场景里无限尸潮节点的数量与频率。
## 依赖：Players / NetworkWorld / Global / HintTextLayer / 无限尸潮节点（可选）
##
## 【参考防守战机器】行走图实体 + 32×32 碰撞 + 靠近提示 + Host 权威事务。

const WALK := preload("res://script/vx_walk_sheet.gd")
const HINT_LAYER := preload("res://script/ui/hint_text_layer.gd")
const PICKUP_INTERACTION := preload("res://script/pickup_interaction.gd")
const INTERACT_PRIORITY := preload("res://script/interact_priority.gd")

@export_group("外观（未装满）")
@export var walk_texture: Texture2D:
	set(v):
		walk_texture = v
		_refresh_sprite()
@export_range(0, 7, 1) var walk_char_index: int = 0:
	set(v):
		walk_char_index = v
		_refresh_sprite()
@export_range(0, 3, 1) var walk_direction: int = 0:
	set(v):
		walk_direction = v
		_refresh_sprite()
@export var sprite_offset: Vector2 = Vector2.ZERO

@export_group("踏步动画")
@export var step_frames: Array[int] = [1, 0, 1, 2]
@export_range(0.02, 5.0, 0.01) var step_duration: float = 0.25
@export var animated: bool = true

@export_group("装满后外观")
## 留空 = 沿用未装满的贴图；索引由下面单独配
@export var filled_texture: Texture2D
@export var filled_char_index: int = 0
@export var filled_direction: int = 0

@export_group("油桶需求")
@export_range(1, 20, 1) var required_count: int = 3
@export var deposit_range: float = 56.0
@export var fill_sound: AudioStream
@export var full_sound: AudioStream

@export_group("装满效果")
## 指定尸潮 BGM（留空 = 不播；容器上固定曲目，符合 2026-11-21 用户确认）
@export var horde_music: AudioStream
@export_range(-40.0, 6.0, 0.5) var horde_music_volume_db: float = -8.0
@export var horde_music_loop: bool = true
## 提升无限尸潮：数量倍率 / 间隔倍率
@export_range(0.1, 10.0, 0.05) var boost_count_multiplier: float = 1.5
@export_range(0.1, 5.0, 0.01) var boost_interval_multiplier: float = 0.7

signal filled

var _filled_count: int = 0
var _is_full: bool = false
var _sprite: Sprite2D = null
var _hint: Label = null
var _player: Node2D = null
var _can_deposit: bool = false
var _step_index: int = 0
var _step_timer: float = 0.0
var _music_player: AudioStreamPlayer = null
var _net_world: Node = null


func _ready() -> void:
	if step_frames.is_empty():
		step_frames = [1]
	_ensure_children()
	_refresh_sprite()
	_create_collision()
	if Engine.is_editor_hint():
		return
	add_to_group(&"oil_barrel_container")
	_net_world = _find_network_world()
	if _net_world != null and _net_world.has_signal("oil_container_state_received"):
		_net_world.connect("oil_container_state_received", _on_net_state)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_tick_animation(delta)
	_check_player()
	_update_hint()
	if not _can_deposit:
		return
	if not PICKUP_INTERACTION.tapped_once("功能键"):
		return
	INTERACT_PRIORITY.mark_pickup_key_used()
	_try_deposit()


func _tick_animation(delta: float) -> void:
	if not animated or _is_full:
		return
	if step_frames.size() <= 1:
		return
	_step_timer -= delta
	if _step_timer <= 0.0:
		_step_timer += maxf(step_duration, 0.02)
		_step_index = (_step_index + 1) % step_frames.size()
		_refresh_sprite()


func _check_player() -> void:
	var net: Node = get_node_or_null("/root/Net")
	var online: bool = net != null and net.has_method("is_online_session") and bool(net.is_online_session())
	_player = Players.get_local_entity() if online else Players.nearest_entity_to(global_position)
	_can_deposit = not _is_full and _player != null and is_instance_valid(_player) \
		and _player.global_position.distance_to(global_position) <= deposit_range
	if _can_deposit:
		var st: PlayerState = Players.get_state_for_entity(_player)
		_can_deposit = st != null and st.carried_oil_barrel


## 玩家放下前调用（2026-11-23）：交付范围内且持桶时**优先装进容器**，
## 返回 true = 已处理，调用方不要再丢到地上。容器优先级高于「随地丢弃」。
func try_deposit_from(player: Node2D) -> bool:
	if _is_full or player == null or not is_instance_valid(player):
		return false
	if player.global_position.distance_to(global_position) > deposit_range:
		return false
	var st: PlayerState = Players.get_state_for_entity(player)
	if st == null or not st.carried_oil_barrel:
		return false
	_player = player
	_try_deposit()
	return true


func _try_deposit() -> void:
	var net: Node = get_node_or_null("/root/Net")
	var online: bool = net != null and net.has_method("is_online_session") and bool(net.is_online_session())
	if online:
		var world: Node = _find_network_world()
		if world != null and world.has_method("request_oil_container_deposit"):
			world.call("request_oil_container_deposit", get_path())
			return
	var st: PlayerState = Players.get_state_for_entity(_player)
	if st == null or not st.carried_oil_barrel:
		return
	st.carried_oil_barrel = false
	if _player.has_method("apply_oil_barrel_carry"):
		_player.call("apply_oil_barrel_carry", false)
	host_accept_barrel()


## Host / 单机：真正记账（NetworkWorld 校验后也会调这里）。
func host_accept_barrel() -> void:
	if _is_full:
		return
	_filled_count = mini(_filled_count + 1, required_count)
	if fill_sound != null:
		Global.play_sfx_managed(fill_sound, self)
	if _filled_count >= required_count:
		_enter_full()
	_broadcast_state()


func _enter_full() -> void:
	if _is_full:
		return
	_is_full = true
	_step_index = 0
	_refresh_sprite()
	if full_sound != null:
		Global.play_sfx_managed(full_sound, self)
	_play_horde_music()
	_boost_infinite_horde()
	filled.emit()


func _play_horde_music() -> void:
	if horde_music == null:
		return
	if _music_player == null:
		_music_player = AudioStreamPlayer.new()
		_music_player.name = "HordeMusic"
		_music_player.bus = &"Music"
		add_child(_music_player)
	_music_player.stream = horde_music
	_music_player.volume_db = horde_music_volume_db
	if horde_music_loop and horde_music.has_method("set_loop"):
		horde_music.call("set_loop", true)
	_music_player.play()


func _boost_infinite_horde() -> void:
	for node: Node in get_tree().get_nodes_in_group("infinite_horde_machine"):
		if node.has_method("set_intensity"):
			node.call("set_intensity", boost_count_multiplier, boost_interval_multiplier)


func _update_hint() -> void:
	var show: bool = not _is_full and _player != null and is_instance_valid(_player) \
		and _player.global_position.distance_to(global_position) <= deposit_range
	_hint.visible = show
	if not show:
		return
	if _can_deposit:
		_hint.text = "需要油桶 %d/%d  [%s]" % [_filled_count, required_count, Global.key_hint(&"功能键")]
	else:
		_hint.text = "需要油桶 %d/%d" % [_filled_count, required_count]


func _ensure_children() -> void:
	_sprite = get_node_or_null("Sprite2D") as Sprite2D
	if _sprite == null:
		_sprite = Sprite2D.new()
		_sprite.name = "Sprite2D"
		_sprite.centered = true
		add_child(_sprite)
	_hint = get_node_or_null("HintLabel") as Label
	if _hint == null:
		_hint = Label.new()
		_hint.name = "HintLabel"
		_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hint.position = Vector2(-120, -72)
		_hint.size = Vector2(240, 24)
		_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_hint)
	var g: Node = get_node_or_null("/root/Global")
	if g != null:
		if g.has_method("apply_hint_font"):
			g.call("apply_hint_font", _hint, 12)
		if g.has_method("apply_text_shadow"):
			g.call("apply_text_shadow", _hint)
	HINT_LAYER.attach(_hint)
	_hint.add_theme_color_override("font_color", Color(0.55, 0.9, 1.0))


func _create_collision() -> void:
	var body: StaticBody2D = get_node_or_null("Collision") as StaticBody2D
	if body == null:
		body = StaticBody2D.new()
		body.name = "Collision"
		add_child(body)
	body.collision_layer = 33
	body.collision_mask = 0
	var shape: CollisionShape2D = body.get_node_or_null("Shape") as CollisionShape2D
	if shape == null:
		shape = CollisionShape2D.new()
		shape.name = "Shape"
		body.add_child(shape)
	var rect: RectangleShape2D = shape.shape as RectangleShape2D
	if rect == null:
		rect = RectangleShape2D.new()
		shape.shape = rect
	rect.size = Vector2(32, 32)


func _refresh_sprite() -> void:
	if _sprite == null:
		return
	var tex: Texture2D = filled_texture if _is_full and filled_texture != null else walk_texture
	_sprite.texture = tex
	_sprite.position = sprite_offset
	_sprite.visible = tex != null
	if tex == null:
		return
	var index: int = filled_char_index if _is_full else walk_char_index
	var facing: int = filled_direction if _is_full else walk_direction
	_sprite.region_enabled = true
	_sprite.region_rect = WALK.region_rect(tex, index, facing, step_frames[_step_index])


func _find_network_world() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.find_child("NetworkWorld", true, false)


func _broadcast_state() -> void:
	if _net_world != null and _net_world.has_method("broadcast_oil_container_state"):
		_net_world.call("broadcast_oil_container_state", get_path(), _filled_count, _is_full)


func _on_net_state(node_path: NodePath, count: int, is_full: bool) -> void:
	if str(node_path) != str(get_path()):
		return
	var became_full: bool = is_full and not _is_full
	_filled_count = clampi(count, 0, required_count)
	_is_full = is_full
	if became_full:
		_refresh_sprite()
		_play_horde_music()
	else:
		_refresh_sprite()
