@tool
class_name FinaleTrigger extends Node2D

## ── 架构定位 ──
## 系统：关卡流程 ｜ 层：玩法（Node2D，关卡作者标记）
## 联机：**Host 权威** —— Client 触发 = 向 Host 请求，Host 广播 ED 给全体（见 HoldoutMachine）
## 职责：独立摆放的「触发最终 ED」节点：VX 行走图 + 靠近提示 + 确定键。
##       触发后交给场景里的 HoldoutMachine 走它那条 ED 路径
##       （`start_finale_ending()` → 黑屏 → 角色结局 → 总结 → 名单）。
## 依赖：HoldoutMachine.start_finale_ending、CampaignEnding（没有机器时的本机兜底）、
##       Global（字体 / 文字阴影 / 音效）、Players 查询

## 【为什么要独立节点】
## 机器自带「打完再交互进 ED」，但那要求玩家回到机器旁边。想做成
## 「走到列车门口 / 铁门边按确定键 → 结局」就需要一个能摆在任意位置的触发物 ——
## 就是本节点。它自己不管 ED 编排（那份逻辑只有一份，在 CampaignEnding 里）。

## 【怎么用】
##   ① 实例化 `object/finale_trigger.tscn` 摆到目标位置；
##   ② 拖入行走图、选角色格 / 朝向；
##   ③ `machine_path` 留空 = 自动用**场景里最近的** HoldoutMachine（推荐）；
##      场景里没有机器时会走本机兜底（联机下直接拒绝，见 `_start_local_ending`）。
##   ④ 需要挡路就保留「碰撞」组的 default（32×32 实体层 33，与医疗箱同款）。

const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

## 与医疗箱 / 存档点 / 传送点同款：图块层 + 第 6 层「子弹阻挡」。
const COLLISION_NODE: String = "Collision"
const COLLISION_SHAPE_NODE: String = "Shape"
const COLLISION_LAYER: int = 33

const CAMPAIGN_ENDING := preload("res://script/director/campaign_ending.gd")

@export_group("外观（VX 行走图）")
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
@export var step_duration: float = 0.25
@export var animated: bool = true

## 朝向动画（与其他行走图物件同款）：循环的是朝向，与踏步**各自独立计时**。默认关。
@export_group("朝向动画")
@export var facing_frames: Array[int] = [0]
@export_range(0.02, 5.0, 0.01) var facing_duration: float = 0.25
@export var facing_animated: bool = false

@export_group("交互")
## 靠近时显示的提示文字（同传送点：只显示这行，不拼按键）。
@export var interact_label: String = "进入结局"
@export_range(8.0, 512.0, 1.0) var interact_range: float = 56.0
## 只能触发一次（ED 一旦开演就不会再回来）。
@export var one_shot: bool = true

@export_group("结局")
## 目标防守机器；留空 = 自动取场景里**最近**的 HoldoutMachine（它持有 ED 音效 / 淡出时长 /
## 联机广播通道）。找不到机器时走本机兜底，见 `_start_local_ending`。
@export var machine_path: NodePath
## 本机兜底时用的黑屏淡出时长（有机器时以机器上的 `ending_fade_seconds` 为准）。
@export_range(0.5, 6.0, 0.1) var ending_fade_seconds: float = 1.5
## 本机兜底时播放的音效（有机器时以机器上的 `ending_sound` 为准）。
@export var ending_sound: AudioStream

@export_group("碰撞")
## 是否生成实体碰撞盒（默认开：列车门 / 铁门这类东西不该能穿过去）。
@export var collision_enabled: bool = true
@export var collision_size: Vector2 = Vector2(32, 32)
@export var collision_offset: Vector2 = Vector2.ZERO

var _sprite: Sprite2D = null
var _label: Label = null
var _step_index: int = 0
var _step_timer: float = 0.0
var _facing_index: int = 0
var _facing_timer: float = 0.0
var _can_trigger: bool = false
var _triggered: bool = false


func _ready() -> void:
	if step_frames.is_empty():
		step_frames = [1]
	_ensure_children()
	_ensure_collision()
	_refresh_sprite()
	_step_timer = step_duration
	_facing_timer = facing_duration
	if Engine.is_editor_hint():
		return


func _process(delta: float) -> void:
	if animated and step_frames.size() > 1:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(step_duration, 0.02)
			_step_index = (_step_index + 1) % step_frames.size()
			_refresh_sprite()
	# 朝向动画（与踏步**各自独立计时**）
	if facing_animated and facing_frames.size() > 1:
		_facing_timer -= delta
		if _facing_timer <= 0.0:
			_facing_timer += maxf(facing_duration, 0.02)
			_facing_index = (_facing_index + 1) % facing_frames.size()
			_refresh_sprite()
	if Engine.is_editor_hint():
		return  ## 编辑器里只播动画，不碰 Players / 交互
	_check_player_proximity()
	_update_label()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or _triggered:
		return
	if not _can_trigger:
		return
	if event.is_action_pressed("确定键"):
		## 与传送点 / 安全门一致：UI 先消费按键，不会隔着菜单误触发。
		get_viewport().set_input_as_handled()
		trigger()


# ═══════════════════════════════════════
# 触发
# ═══════════════════════════════════════

## 手动 / 交互触发入口（幂等：one_shot 时只生效一次）。
func trigger() -> void:
	if one_shot and _triggered:
		return
	_triggered = true
	_hide_label()
	var machine: Node = _resolve_machine()
	if machine != null and machine.has_method("start_finale_ending"):
		print("[FinaleTrigger] %s → 交给防守机器 %s 起 ED" % [name, machine.name])
		machine.call("start_finale_ending")
		return
	_start_local_ending()


## 目标机器：`machine_path` 优先（相对本节点 → 相对场景根）；留空则取场景里**最近**的一台。
## 运行时解析（不缓存）：机器的 `_ready` 才加入 `holdout_machine` 组，节点顺序不保证。
func _resolve_machine() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	if not machine_path.is_empty():
		var direct: Node = get_node_or_null(machine_path)
		if direct != null:
			return direct
		if tree.current_scene != null:
			return tree.current_scene.get_node_or_null(machine_path)
		return null
	var best: Node = null
	var best_dist: float = INF
	for node: Node in tree.get_nodes_in_group("holdout_machine"):
		if not (node is Node2D) or not is_instance_valid(node):
			continue
		var dist: float = global_position.distance_squared_to((node as Node2D).global_position)
		if dist < best_dist:
			best_dist = dist
			best = node
	return best


## 场景里没有防守机器时的**本机兜底**：直接起一段本地 ED。
## ⚠ 联机下拒绝：没有机器就没有「Host 广播 ED」的通道，各端各自起会时序分叉。
func _start_local_ending() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	if _is_online_session():
		print("[FinaleTrigger] 联机会话里找不到 HoldoutMachine → 拒绝本机起 ED（ED 必须由 Host 广播）")
		_triggered = false
		return
	## 单一所有者不变量（与 HoldoutMachine._begin_ending 同款）：先收掉残留的 ED 所有者。
	for node: Node in tree.root.get_children():
		if node.has_method("stop_ending_music"):
			node.call("stop_ending_music")
	if ending_sound != null:
		Global.play_sfx_managed(ending_sound, tree.current_scene)
	var ending: Node = CAMPAIGN_ENDING.new()
	ending.set("fade_seconds", ending_fade_seconds)
	tree.root.add_child(ending)
	ending.call("start")
	print("[FinaleTrigger] 场景里没有 HoldoutMachine → 本机直接起 ED")


# ═══════════════════════════════════════
# 子节点
# ═══════════════════════════════════════

func _ensure_children() -> void:
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if s == null:
		s = Sprite2D.new()
		s.name = "Sprite2D"
		s.centered = true
		add_child(s)
	_sprite = s

	var label: Label = get_node_or_null("HintLabel") as Label
	if label == null:
		label = Label.new()
		label.name = "HintLabel"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.position = Vector2(-90, -56)
		label.size = Vector2(180, 24)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.hide()
		add_child(label)
	_label = label
	## 字体 / 阴影**无条件套**（预置节点同样要吃到全局样式，项目踩过坑）。
	var g: Node = get_node_or_null("/root/Global")
	if g:
		if g.has_method("apply_hint_font"):
			g.apply_hint_font(_label, 12)
		if g.has_method("apply_text_shadow"):
			g.apply_text_shadow(_label)


## 实体碰撞（与医疗箱 / 存档点 / HintMarker 同款）。幂等：预置节点只改参数不重建。
func _ensure_collision() -> void:
	var body: StaticBody2D = get_node_or_null(COLLISION_NODE) as StaticBody2D
	if body == null:
		body = StaticBody2D.new()
		body.name = COLLISION_NODE
		add_child(body)
	var active: bool = collision_enabled and is_visible_in_tree()
	body.collision_layer = COLLISION_LAYER if active else 0
	body.collision_mask = 0

	var shape_node: CollisionShape2D = body.get_node_or_null(COLLISION_SHAPE_NODE) as CollisionShape2D
	if shape_node == null:
		shape_node = CollisionShape2D.new()
		shape_node.name = COLLISION_SHAPE_NODE
		body.add_child(shape_node)
	var rect: RectangleShape2D = shape_node.shape as RectangleShape2D
	if rect == null:
		rect = RectangleShape2D.new()
		shape_node.shape = rect
	rect.size = Vector2(maxf(collision_size.x, 1.0), maxf(collision_size.y, 1.0))
	shape_node.position = collision_offset


# ═══════════════════════════════════════
# 精灵 / 提示
# ═══════════════════════════════════════

func _refresh_sprite() -> void:
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if s == null:
		return
	s.texture = walk_texture
	s.position = sprite_offset
	s.visible = walk_texture != null
	if walk_texture == null:
		s.region_enabled = false
		return
	s.region_enabled = true
	var frame: int = clampi(step_frames[_step_index], 0, 2) if _step_index < step_frames.size() else 0
	var char_col: int = walk_char_index % CHARS_PER_ROW
	var char_row: int = walk_char_index / CHARS_PER_ROW
	s.region_rect = Rect2(
		char_col * (FRAME_W * 3) + frame * FRAME_W,
		char_row * (FRAME_H * DIRECTIONS) + _current_facing() * FRAME_H,
		FRAME_W, FRAME_H)


## 当前应显示的朝向：朝向动画开着取序列里的值，否则用 walk_direction。
func _current_facing() -> int:
	if not facing_animated or facing_frames.is_empty():
		return clampi(walk_direction, 0, 3)
	return clampi(facing_frames[_facing_index % facing_frames.size()], 0, 3)


func _check_player_proximity() -> void:
	var player: Node2D = _local_player()
	if player == null or not is_instance_valid(player):
		_can_trigger = false
		return
	_can_trigger = global_position.distance_to(player.global_position) <= interact_range


## 联机只看**本机操控的实体**（与医疗箱 / HintMarker 同口径）。
func _local_player() -> Node2D:
	var net: Node = get_node_or_null("/root/Net")
	if net != null and net.has_method("is_online_session") and bool(net.is_online_session()):
		return Players.get_local_entity()
	return Players.nearest_entity_to(global_position)


func _update_label() -> void:
	if _label == null:
		return
	var show: bool = _can_trigger and not _triggered and is_visible_in_tree()
	if _label.visible == show:
		return
	_label.visible = show
	if show:
		_label.text = interact_label


func _hide_label() -> void:
	if _label != null:
		_label.hide()


func _is_online_session() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and bool(net.is_online_session())
