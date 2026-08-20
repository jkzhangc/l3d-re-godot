class_name TeleportPoint extends Node2D
## 传送点 — 放在地图上，玩家靠近后按交互键传送到目标场景
##
## 使用 VX Ace 行走图渲染，支持踏步动画

# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
@export var target_scene: String = ""              ## 目标场景路径，如 "res://scene/maps/街道.tscn"
@export var walk_texture: Texture2D                ## 精灵表
@export var capture_checkpoint: bool = true        ## 传送前捕获 checkpoint（安全屋出口应为 true）
@export var walk_char_index: int = 0               ## 精灵表中的角色索引
@export var walk_direction: int = 0                ## 朝向（0=下, 1=左, 2=右, 3=上）

@export_group("踏步动画")
@export var step_frames: Array[int] = [1, 0, 1, 2] ## 踏步帧序列
@export var step_duration: float = 0.25            ## 每帧持续秒数
@export var animated: bool = true                  ## 是否播放踏步动画

@export_group("交互")
@export var interact_label: String = "前往"         ## 交互提示文字
@export var interact_range: float = 48.0           ## 交互触发距离（像素）

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _player_nearby: bool = false
var _player_ref: CharacterBody2D = null
var _step_index: int = 0
var _step_timer: float = 0.0
var _can_interact: bool = false


# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	if target_scene.is_empty():
		printerr("[TeleportPoint] target_scene 未设置！")

	if step_frames.is_empty():
		step_frames = [1]

	# ── 确保 Sprite2D 子节点存在 ──
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not s:
		s = Sprite2D.new()
		s.name = "Sprite2D"
		s.centered = true
		add_child(s)

	# ── 确保 HintLabel 子节点存在 ──
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		label = Label.new()
		label.name = "HintLabel"
		label.add_theme_font_size_override("font_size", 14)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.position = Vector2(-50, -56)
		label.size = Vector2(100, 24)
		label.modulate = Color(1, 1, 1, 0.9)
		label.hide()
		add_child(label)

	_refresh_sprite()
	if animated:
		_step_timer = step_duration


func _process(delta: float) -> void:
	if animated:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(step_duration, 0.02)
			_step_index = (_step_index + 1) % step_frames.size()
			_refresh_sprite()

	# 静态行走图同样需要持续检测玩家是否在范围内。
	_check_player_proximity()


func _input(event: InputEvent) -> void:
	if not _can_interact:
		return
	if event.is_action_pressed("确定键"):
		_do_teleport()


# ═══════════════════════════════════════
# 精灵渲染
# ═══════════════════════════════════════

func _refresh_sprite() -> void:
	if not walk_texture:
		return

	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not s:
		return

	s.texture = walk_texture
	s.region_enabled = true

	var frame: int = step_frames[_step_index] if animated else step_frames[0]
	var char_col: int = walk_char_index % CHARS_PER_ROW
	var char_row: int = walk_char_index / CHARS_PER_ROW
	var dir_row: int = walk_direction

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
	s.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


# ═══════════════════════════════════════
# 玩家检测
# ═══════════════════════════════════════

func _check_player_proximity() -> void:
	var player: CharacterBody2D = _find_player()
	if not player:
		_player_nearby = false
		_player_ref = null
		_can_interact = false
		_update_label()
		return

	var dist: float = global_position.distance_to(player.global_position)
	var was_near: bool = _can_interact
	_can_interact = dist <= interact_range
	_player_ref = player

	if _can_interact != was_near:
		_update_label()


func _update_label() -> void:
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		return
	if _can_interact:
		label.text = interact_label
		label.show()
	else:
		label.hide()


# ═══════════════════════════════════════
# 传送
# ═══════════════════════════════════════

func _do_teleport() -> void:
	if target_scene.is_empty():
		printerr("[TeleportPoint] target_scene 为空，无法传送")
		return

	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("is_online_session") and net.is_online_session():
		# 联机时场景由 Host 权威广播；客户端不能自行切图。
		if net.is_host and capture_checkpoint:
			Global.capture_checkpoint()
		if net.has_method("request_scene_change"):
			net.request_scene_change(target_scene)
		return

	print("[TeleportPoint] 传送至: %s" % target_scene)
	if capture_checkpoint:
		Global.capture_checkpoint()
	var tree: SceneTree = get_tree()
	if tree:
		tree.change_scene_to_file.call_deferred(target_scene)


func _find_player() -> CharacterBody2D:
	return Players.nearest_entity_to(global_position) as CharacterBody2D
