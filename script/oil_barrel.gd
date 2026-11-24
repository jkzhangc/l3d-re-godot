@tool
extends Node2D

## ── 架构定位 ──
## 系统：油桶搬运 ｜ 层：玩法（Node2D 掉落物）
## 联机：Host 权威拾取/放下；Client 发请求，地面状态走 NetworkWorld 掉落物快照。
## 职责：地面油桶。靠近按功能键(D)拾取 → 玩家进入「持桶」状态（收枪、禁开火）；
##       持有中再按 D 由玩家侧放下（见 player.gd `drop_oil_barrel`）。
## 依赖：Players / NetworkWorld / Global / HintTextLayer
## ⚠ 不进 GroundItemCap（油桶是关卡道具，见 `_ready` 注释）
##
## 【为什么是独立脚本而不是 ItemData】油桶不是消耗品，也不进治疗/辅助/投掷槽，
## 它是「双手占用」的搬运物；用独立掉落物 + PlayerState.carried_oil_barrel 最干净。
##
## 【创意工坊/可编辑】贴图、拾取范围、提示文案、音效全部是导出字段，地图作者/模组可改。

const HINT_LAYER := preload("res://script/ui/hint_text_layer.gd")
const PICKUP_INTERACTION := preload("res://script/pickup_interaction.gd")
const INTERACT_PRIORITY := preload("res://script/interact_priority.gd")

@export_group("外观")
@export var texture: Texture2D:
	set(v):
		texture = v
		_refresh_sprite()
@export_range(0, 7, 1) var char_index: int = 0:
	set(v):
		char_index = v
		_refresh_sprite()
@export_range(0, 3, 1) var direction: int = 0:
	set(v):
		direction = v
		_refresh_sprite()
@export var sprite_offset: Vector2 = Vector2.ZERO
@export var sprite_scale: float = 1.0

@export_group("交互")
@export var hint_text: String = "拾取油桶"
@export_range(8.0, 128.0, 1.0) var pickup_range: float = 48.0
@export var pickup_sound: AudioStream
## 是否需要功能键（默认 true；关掉 = 靠近自动拾取）
@export var require_function_key: bool = true
@export var collision_enabled: bool = true

## NetworkWorld 用这个字段识别油桶（掉落物快照 kind = "oil"）
var is_oil_barrel: bool = true
var network_pickup_id: int = 0
## 客户端镜像节点：生命周期归 NetworkWorld，跳过地面物上限
var cap_exempt: bool = false

var _sprite: Sprite2D = null
var _hint: Label = null
var _player: Node2D = null
var _can_pick: bool = false
var _request_pending: bool = false
var _presentation_only: bool = false

## 地图油桶的共享外观（2026-11-23）：丢弃时新实例从这里复制。
## 不复制的话，`oil_barrel.tscn` 默认没有贴图 → 丢下的油桶透明、看不到行走图。
## 只由地图上的实例在 _ready 时写入（texture 非空），运行时新实例不覆盖。
static var shared_appearance: Dictionary = {}


func _ready() -> void:
	_ensure_children()
	_refresh_sprite()
	if Engine.is_editor_hint():
		return
	_capture_shared_appearance()
	add_to_group(&"ground_pickup")
	## ★2026-11-24 修「往容器里装了两个桶之后，其他桶自己消失」：
	## 油桶是**关卡道具**（如「死亡岛-第四关-港口」required_count=5，正好对应地图上摆的 5 个桶），
	## 此前却和掉落杂物一起注册 GroundItemCap(8)。尸潮里敌人掉的枪/药一旦把地面物顶过 8 个，
	## 被淘汰的"最早的"就是地图油桶 → 逐个 queue_free，容器永远装不满、尸潮也开不了。
	## 与 weapon_pickup / healing_pickup 的**地图预摆物**同款：油桶不参与「掉落杂物上限」。
	## 这里干脆全豁免（运行时丢下的桶也算）：丢一个桶再被杂物顶掉 = 关卡永久缺件，
	## 而油桶总量本来就由地图作者控制，不会像枪械掉落那样无限堆积。
	## `cap_exempt` 字段保留：NetworkWorld 的客户端镜像仍会在 add_child 前置位。
	_create_collision()


func _capture_shared_appearance() -> void:
	if texture == null:
		return
	shared_appearance = {
		"texture": texture,
		"char_index": char_index,
		"sprite_offset": sprite_offset,
		"sprite_scale": sprite_scale,
	}


## 丢弃后由调用方套用：把地图油桶的外观复制到新实例。
func apply_shared_appearance() -> void:
	if shared_appearance.is_empty():
		return
	texture = shared_appearance.get("texture") as Texture2D
	char_index = int(shared_appearance.get("char_index", 0))
	sprite_offset = shared_appearance.get("sprite_offset", Vector2.ZERO)
	sprite_scale = float(shared_appearance.get("sprite_scale", 1.0))
	_refresh_sprite()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _presentation_only and network_pickup_id <= 0:
		visible = false
		return
	visible = true
	_check_player()
	_update_hint()
	if not _can_pick:
		return
	if require_function_key:
		if not PICKUP_INTERACTION.tapped_once("功能键"):
			return
		INTERACT_PRIORITY.mark_pickup_key_used()
	_try_pickup()


func _check_player() -> void:
	var net: Node = get_node_or_null("/root/Net")
	var online: bool = net != null and net.has_method("is_online_session") and bool(net.is_online_session())
	_player = Players.get_local_entity() if online else Players.nearest_entity_to(global_position)
	_can_pick = _player != null and is_instance_valid(_player) \
		and _player.global_position.distance_to(global_position) <= pickup_range \
		and not _request_pending
	## 已经拿着油桶的人不能再捡（D 要留给「放下」）
	if _can_pick:
		var st: PlayerState = Players.get_state_for_entity(_player)
		if st != null and st.carried_oil_barrel:
			_can_pick = false


func _try_pickup() -> void:
	if _player == null:
		return
	var net: Node = get_node_or_null("/root/Net")
	var online: bool = net != null and net.has_method("is_online_session") and bool(net.is_online_session())
	if online and network_pickup_id > 0:
		var world: Node = _find_network_world()
		if world != null and world.has_method("request_pickup"):
			_request_pending = true
			world.call("request_pickup", network_pickup_id, _player.global_position)
			return
		_request_pending = false
		return
	## 单机 / Host 自己（Host 的拾取走 NetworkWorld 事务；单机直接本地）
	var st: PlayerState = Players.get_state_for_entity(_player)
	if st == null or st.carried_oil_barrel:
		return
	_player.call("apply_oil_barrel_carry", true)
	if pickup_sound != null:
		Global.play_sfx_managed(pickup_sound, get_parent())
	queue_free()


func _find_network_world() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.find_child("NetworkWorld", true, false)


func _update_hint() -> void:
	if _hint == null:
		return
	var show: bool = _can_pick and is_visible_in_tree()
	_hint.visible = show
	if show:
		_hint.text = "%s  [%s]" % [hint_text, Global.key_hint(&"功能键")]


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
		_hint.position = Vector2(-104, -58)
		_hint.size = Vector2(208, 24)
		_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_hint)
	var g: Node = get_node_or_null("/root/Global")
	if g != null:
		if g.has_method("apply_hint_font"):
			g.call("apply_hint_font", _hint, 12)
		if g.has_method("apply_text_shadow"):
			g.call("apply_text_shadow", _hint)
	HINT_LAYER.attach(_hint)
	_hint.add_theme_color_override("font_color", Color(1.0, 0.9, 0.32))


func _create_collision() -> void:
	var body: StaticBody2D = get_node_or_null("Collision") as StaticBody2D
	if body == null:
		body = StaticBody2D.new()
		body.name = "Collision"
		add_child(body)
	body.collision_layer = 33 if collision_enabled else 0
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
	rect.size = Vector2(20, 20)


func _refresh_sprite() -> void:
	if _sprite == null:
		return
	_sprite.texture = texture
	_sprite.position = sprite_offset
	_sprite.scale = Vector2.ONE * sprite_scale
	_sprite.visible = texture != null
	if texture == null:
		return
	## 行走图（多角色表）支持：文件名带 `$` 前缀时按 vx_walk_sheet 取帧
	var walk := preload("res://script/vx_walk_sheet.gd")
	_sprite.region_enabled = true
	_sprite.region_rect = walk.region_rect(texture, char_index, direction, 0)


## ── NetworkWorld 掉落物协议 ──
func configure_network_pickup(pickup_id: int, presentation_only: bool = false) -> void:
	network_pickup_id = pickup_id
	_presentation_only = presentation_only
	_request_pending = false
	if pickup_id > 0:
		visible = true


func reset_network_pickup_request() -> void:
	_request_pending = false


func disable_network_pickup() -> void:
	_presentation_only = true
	_request_pending = false
	visible = false
	set_process(false)
