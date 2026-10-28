@tool
class_name AmmoSupply extends Node2D

## ── 架构定位 ──
## 系统：弹药补给 ｜ 层：玩法（Node2D，可反复使用的地图互动物）
## 联机：Host 权威，Client 仅经 NetworkWorld 提交节点路径与位置提示。
## 职责：行走图预览/踏步、实体碰撞、附近功能键补给；按随身枪械配置补足备弹，
##       不改变弹夹、不降低已有备弹，无限次使用。仅联机开关不影响编辑器预览。
## 依赖：Players、PlayerState、Global、NetworkWorld（运行时）；可直接挂脚本或拖预制体。

const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
## 行走图文件名特殊前缀（`$` = 单角色表）解析，见 script/vx_walk_sheet.gd
const WALK := preload("res://script/vx_walk_sheet.gd")
## 提示文字统一渲染层（不被角色/图块遮挡、不吃夜图暗度），见 script/ui/hint_text_layer.gd
const HINT_LAYER := preload("res://script/ui/hint_text_layer.gd")

@export_group("出现条件")
## 勾选后单机移除整个节点（包括碰撞），联机保留；编辑器始终可见。
@export var multiplayer_only: bool = false

@export_group("行走图")
@export var walk_texture: Texture2D = preload("res://art/Weapon/[2K-VX]-Aアタッシュケース.png"):
	set(value):
		walk_texture = value
		_refresh_sprite()
@export_range(0, 7, 1) var walk_char_index: int = 3:
	set(value):
		walk_char_index = value
		_refresh_sprite()
@export_enum("下", "左", "右", "上") var walk_direction: int = 0:
	set(value):
		walk_direction = value
		_refresh_sprite()
@export var sprite_offset: Vector2 = Vector2(0, -16):
	set(value):
		sprite_offset = value
		_refresh_sprite()

@export_group("踏步动画")
@export var step_frames: Array[int] = [1, 0, 1, 2]
@export_range(0.02, 2.0, 0.01) var step_duration: float = 0.25
@export var animated: bool = true

## ── 朝向动画（2026-10-27 用户需求）──
## 与踏步动画同款，只是循环的是**朝向**而不是踏步帧；两者**各自独立计时**，
## 同时开 = 一边踏步一边转朝向。默认关 → 固定用 `walk_direction`，老地图零变化。
@export_group("朝向动画")
## 朝向帧序列（0=下 1=左 2=右 3=上），按顺序循环。
@export var facing_frames: Array[int] = [0]
## 每档朝向持续秒数。
@export_range(0.02, 5.0, 0.01) var facing_duration: float = 0.25
## 是否播放朝向动画。关掉 = 固定用 `walk_direction`。
@export var facing_animated: bool = false

@export_group("交互")
@export var interact_label: String = "补充弹药"
@export_range(24.0, 200.0, 4.0) var interact_range: float = 56.0
@export var refill_sound: AudioStream = preload("res://sound/カチャ.ogg")

@export_group("碰撞")
@export var collision_size: Vector2 = Vector2(32, 32):
	set(value):
		collision_size = value
		if is_node_ready():
			_ensure_collision()
@export var collision_offset: Vector2 = Vector2.ZERO:
	set(value):
		collision_offset = value
		if is_node_ready():
			_ensure_collision()

var _step_index: int = 0
var _step_timer: float = 0.0
var _facing_index: int = 0
var _facing_timer: float = 0.0
var _can_interact: bool = false
## 提示 Label 的缓存（2026-10-28）：提示文字会被搬到 HintTextLayer，之后按名字查不到。
var _hint_label: Label = null


func _ready() -> void:
	if not Engine.is_editor_hint() and multiplayer_only and not _online():
		# 不能只 hide：单机不得残留不可见的实体碰撞或可用交互。
		hide()
		process_mode = Node.PROCESS_MODE_DISABLED
		queue_free()
		return
	_ensure_children()
	_ensure_collision()
	_refresh_sprite()


func _ensure_children() -> void:
	var sprite := get_node_or_null("Sprite2D") as Sprite2D
	if not sprite:
		sprite = Sprite2D.new()
		sprite.name = "Sprite2D"
		add_child(sprite)
	var label: Label = _hint_label
	if label == null or not is_instance_valid(label):
		label = get_node_or_null("HintLabel") as Label
	if not label:
		label = Label.new()
		label.name = "HintLabel"
		add_child(label)
	_hint_label = label
	label.position = Vector2(-180, -70)
	label.size = Vector2(360, 24)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.visible = false
	# 编辑器没有运行时 Global，不能向 placeholder 调方法。
	if not Engine.is_editor_hint():
		var g := get_node_or_null("/root/Global")
		if g:
			g.apply_hint_font(label, 12)
			g.apply_text_shadow(label)
		label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	## ★提示文字层（2026-10-28）：搬到提示层（layer=89；不被角色/图块遮挡、不吃夜图暗度）。
	HINT_LAYER.attach(label)


func _ensure_collision() -> void:
	var body := get_node_or_null("Collision") as StaticBody2D
	if not body:
		body = StaticBody2D.new()
		body.name = "Collision"
		add_child(body)
	body.collision_layer = 33
	body.collision_mask = 0
	var shape_node := body.get_node_or_null("Shape") as CollisionShape2D
	if not shape_node:
		shape_node = CollisionShape2D.new()
		shape_node.name = "Shape"
		body.add_child(shape_node)
	# 各实例独享形状，Inspector 修改不会污染其它箱子。
	var rect := RectangleShape2D.new()
	rect.size = Vector2(maxf(1.0, collision_size.x), maxf(1.0, collision_size.y))
	shape_node.shape = rect
	shape_node.position = collision_offset


func _refresh_sprite() -> void:
	var sprite := get_node_or_null("Sprite2D") as Sprite2D
	if not sprite:
		return
	sprite.texture = walk_texture
	sprite.position = sprite_offset
	sprite.region_enabled = walk_texture != null
	if not walk_texture:
		return
	var frame: int = 1
	if not step_frames.is_empty():
		var index := posmod(_step_index, step_frames.size()) if animated else 0
		frame = clampi(step_frames[index], 0, 2)
	## 文件名带 `$` 前缀时按单角色表取帧（帧尺寸 = 图/3×4），见 vx_walk_sheet.gd
	sprite.region_rect = WALK.region_rect(walk_texture, walk_char_index,
		_current_facing(), frame)


## 当前应显示的朝向：朝向动画开着取序列里的值，否则用 walk_direction。
func _current_facing() -> int:
	if not facing_animated or facing_frames.is_empty():
		return clampi(walk_direction, 0, 3)
	return clampi(facing_frames[_facing_index % facing_frames.size()], 0, 3)


func _process(delta: float) -> void:
	if animated:
		_step_timer += delta
		if _step_timer >= maxf(step_duration, 0.02):
			_step_timer = fmod(_step_timer, maxf(step_duration, 0.02))
			_step_index = (_step_index + 1) % maxi(1, step_frames.size())
			_refresh_sprite()
	# 朝向动画（与踏步**各自独立计时**）
	if facing_animated and facing_frames.size() > 1:
		_facing_timer += delta
		if _facing_timer >= maxf(facing_duration, 0.02):
			_facing_timer = fmod(_facing_timer, maxf(facing_duration, 0.02))
			_facing_index = (_facing_index + 1) % facing_frames.size()
			_refresh_sprite()
	if Engine.is_editor_hint():
		return
	if multiplayer_only and not _online():
		return
	var player: Node2D = Players.get_local_entity()
	var eligible := can_player_use(player)
	_can_interact = eligible
	var label: Label = _hint_label
	if label and is_instance_valid(label):
		label.text = "%s  [%s]" % [interact_label, Global.key_hint(&"功能键")]
		label.visible = eligible
	if eligible and Input.is_action_just_pressed("功能键") and not get_tree().paused:
		_request_use(player)


func can_player_use(player: Node2D) -> bool:
	if not is_instance_valid(player) or not is_visible_in_tree():
		return false
	if player.get("_is_dying") == true or player.get("network_swallow_locked") == true:
		return false
	if player.global_position.distance_to(global_position) > interact_range:
		return false
	var state: PlayerState = Players.get_state_for_entity(player)
	return state != null and state.current_hp > 0.0 and needs_refill(state)


## ── 交互输入仲裁（2026-10-27 用户需求）──
## 语义：此刻按「功能键」，本节点会不会真的做事（供存档点让路，见 interact_priority.gd）。
## 与 `_process` 的触发条件同源：联机专属箱在单机不响应；暂停时不响应；
## 玩家在范围内且**确实缺备弹**才算占用此键（弹药已满时按键无收益 → 不挡存档）。
func can_use_function_key() -> bool:
	if Engine.is_editor_hint():
		return false
	if multiplayer_only and not _online():
		return false
	var tree: SceneTree = get_tree()
	if tree != null and tree.paused:
		return false
	return can_player_use(Players.get_local_entity())


## 同弹种的两把枪共用一个库存：目标取较大的配置值，不能叠加或每次越补越多。
func _reserve_targets(state: PlayerState) -> Dictionary:
	var targets: Dictionary = {}
	if state == null:
		return targets
	for slot: String in ["primary", "secondary"]:
		var weapon: WeaponData = state.get_equipped_weapon(slot)
		if weapon == null or not weapon.is_ranged or weapon.has_infinite_ammo() \
				or weapon.ammo_item_id.is_empty() or weapon.initial_reserve_ammo <= 0:
			continue
		targets[weapon.ammo_item_id] = maxi(int(targets.get(weapon.ammo_item_id, 0)), weapon.initial_reserve_ammo)
	return targets


func needs_refill(state: PlayerState) -> bool:
	var targets := _reserve_targets(state)
	for ammo_id: String in targets:
		if state.count_ammo_item(ammo_id) < int(targets[ammo_id]):
			return true
	return false


## 纯数据补给入口；联机只有 Host 在校验玩家/距离/节点身份之后调用。
## 返回实际补充的总发数；弹夹和其它库存完全不动，满备弹/无限备弹返回 0。
func refill_state(state: PlayerState) -> int:
	if state == null:
		return 0
	var targets := _reserve_targets(state)
	var added: int = 0
	for ammo_id: String in targets:
		var current := state.count_ammo_item(ammo_id)
		var target: int = int(targets[ammo_id])
		if current >= target:
			continue
		var prototype: ItemData = state._load_ammo_item_resource(ammo_id)
		if prototype == null or prototype.item_id != ammo_id or prototype.item_type != ItemData.ItemType.AMMO:
			print("[弹药补给] 未配置弹药资源，跳过 %s" % ammo_id)
			continue
		state.set_ammo_item_count(ammo_id, target, prototype)
		added += target - current
	return added


func _request_use(player: Node2D) -> void:
	if not can_player_use(player):
		return
	if _online():
		var scene := get_tree().current_scene
		var world := scene.get_node_or_null("NetworkWorld") if scene else null
		if world and world.has_method("request_ammo_supply"):
			world.call("request_ammo_supply", scene.get_path_to(self), player.global_position)
		return
	var state: PlayerState = Players.get_state_for_entity(player)
	if refill_state(state) > 0:
		play_refill_feedback()


func play_refill_feedback() -> void:
	if refill_sound:
		Global.play_sfx_managed(refill_sound, self, true)


func _online() -> bool:
	var net := get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and bool(net.is_online_session())
