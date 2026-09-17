@tool
extends Node2D

## ── 架构定位 ──
## 系统：医疗箱 ｜ 层：玩法（Node2D，一次性互动物）
## 联机：Host/单机触发；治疗写各座位 PlayerState（数据权威），实体表现本地同步。
## 职责：靠近显示「治疗全体角色 [功能键]」；按 D 治疗全体角色——
##       全座位回满 HP（含 HP=0 的死亡队员=复活），存活实体同步满血+绿闪；
##       只能用一次，用完直接清除（queue_free）。
## 依赖：Players（座位/实体）、ItemData 无关（不消耗喷雾）。
## 素材：art/Characters/[2K-VX]-救急箱.png（标准 576×512 四角色表，寻址同 weapon_pickup）。

# ═══════════════════════════════════════
# 精灵帧常量（VX 行走图寻址，与 weapon_pickup 一致）
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

const COLLISION_NODE: String = "Collision"
const COLLISION_SHAPE_NODE: String = "Shape"
const COLLISION_SIZE: int = 32

@export_group("外观")
@export var box_texture: Texture2D = preload("res://art/Characters/[2K-VX]-救急箱.png")
@export var box_char_idx: int = 0           ## 精灵表中的角色索引
@export var box_direction: int = 0          ## 朝向（0=下）
@export var sprite_offset: Vector2 = Vector2(0, -20)

@export_group("交互")
@export var interact_label: String = "治疗全体角色"
@export_range(24.0, 200.0, 4.0) var interact_range: float = 56.0

@export_group("音效")
@export var heal_sound: AudioStream = preload("res://sound/回復1.ogg")  ## 治疗音效（留空=不播）

var _can_interact: bool = false
var _used: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		_refresh_sprite()
		return
	_ensure_collision()
	_ensure_label()
	_refresh_sprite()


func _ensure_collision() -> void:
	var body: StaticBody2D = get_node_or_null(COLLISION_NODE) as StaticBody2D
	if not body:
		body = StaticBody2D.new()
		body.name = COLLISION_NODE
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)
	var shape_node: CollisionShape2D = body.get_node_or_null(COLLISION_SHAPE_NODE) as CollisionShape2D
	if not shape_node:
		shape_node = CollisionShape2D.new()
		shape_node.name = COLLISION_SHAPE_NODE
		body.add_child(shape_node)
	if not shape_node.shape:
		var rect := RectangleShape2D.new()
		rect.size = Vector2(COLLISION_SIZE, COLLISION_SIZE)
		shape_node.shape = rect


func _ensure_label() -> void:
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		label = Label.new()
		label.name = "HintLabel"
		label.position = Vector2(-90, -70)
		label.size = Vector2(180, 28)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		var g: Node = get_node_or_null("/root/Global")
		if g:
			g.apply_hint_font(label, 12)  ## 字体统一（2026-09-17）
			g.apply_text_shadow(label)
		label.hide()
		add_child(label)


func _refresh_sprite() -> void:
	var sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not sprite or not box_texture:
		return
	sprite.texture = box_texture
	sprite.position = sprite_offset
	sprite.region_enabled = true
	var frame: int = 1  # 站立帧
	var char_col: int = box_char_idx % CHARS_PER_ROW
	var char_row: int = box_char_idx / CHARS_PER_ROW
	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + box_direction * FRAME_H
	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_check_player_proximity()
	if _can_interact and Input.is_action_just_pressed("功能键"):
		get_viewport().set_input_as_handled()
		_use()


func _check_player_proximity() -> void:
	var candidate: Node2D = Players.get_local_entity() if _is_online_session() else Players.nearest_entity_to(global_position)
	_can_interact = (
		not _used
		and candidate != null
		and is_instance_valid(candidate)
		and candidate.global_position.distance_to(global_position) <= interact_range
	)
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		return
	if _is_online_session():
		label.text = "%s（需主机操作）" % interact_label
	else:
		label.text = "%s  [功能键]" % interact_label
	label.visible = _can_interact


func _is_online_session() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and bool(net.is_online_session())


## 治疗全体角色：全座位回满（HP=0 的死亡队员=复活），存活实体同步 + 绿闪。
func _use() -> void:
	if _used:
		return
	_used = true
	# 全座位回满（死亡队员由此复活——切人时 refresh_after_switch 会用回满的座位 HP）
	for s: PlayerState in Players.seats:
		if s:
			s.current_hp = s.get_max_hp()
	# 存活实体同步满血 + 绿色反馈
	for entity: Node2D in Players.all_entities(false):
		if not is_instance_valid(entity):
			continue
		var state: PlayerState = Players.get_state_for_entity(entity)
		if state and entity.get("_is_dying") != true:
			entity.set("current_hp", state.current_hp)
			if entity.has_method("_play_hit_feedback"):
				entity._play_hit_feedback(Color(1.6, 2.0, 1.6, 1.0), 0.4)
	if heal_sound:
		Global.play_sfx_managed(heal_sound, get_tree().current_scene)
	print("[医疗箱] 全体角色治疗完毕（含死亡队员复活），医疗箱清除")
	# 用完直接清除
	queue_free()


func _draw() -> void:
	if Engine.is_editor_hint():
		return
	if not Global.debug_visuals:
		return
	var color: Color = Color(0.2, 1.0, 0.4, 0.75) if _can_interact else Color(1.0, 0.7, 0.2, 0.5)
	draw_arc(Vector2.ZERO, interact_range, 0.0, TAU, 48, color, 1.5)
