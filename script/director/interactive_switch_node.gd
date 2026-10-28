@tool
class_name InteractiveSwitchNode
extends "res://script/director/move_node.gd"

## ── 架构定位 ──
## 系统：关卡机关（开关 / 拉杆 / 电闸）｜ 层：玩法（Node2D，继承 MoveNode）
## 联机：**各端本地表现** —— 信号由各端自己发（互动方是本机玩家），无 RPC、无同步
## 职责：在 MoveNode 的基础上加「可互动 + 双状态开关」：
##       玩家按确定键 → 状态翻转 → ①换行走图 ②按状态移动到各自终点 ③发**该状态的命名信号**
##       → 监听方（灯光 / 门 / 演出）各自动作。
## 依赖：MoveNode（移动 / 外观 / 碰撞 / 外部信号接线）、Global（提示字体）、Players

## 【开关语义（用户 2026-10-27 需求）】
##   第一次互动 = 「开」→ 发 `signal_on_name`；再互动 = 「关」→ 发 `signal_off_name`。
##   两个信号名都可在 Inspector 改；留空 = 该方向不发信号（只做自身表现）。
##   ⚠ 信号是**运行时 add_user_signal 注册**的（名字作者可改），监听方必须
##     `call_deferred` 之后再连（见 SignalVisibilityNode），否则可能连到不存在的信号。

## 【双状态参数】
##   关 / 开 各自可以覆盖：贴图、角色格、朝向、终点偏移、移动时长。
##   `off_*` / `on_*` 留空（贴图）或 <0（索引/朝向/时长）= 沿用基类当前值。

## 【自定义接口（用户说的「接收信号后可以自定义做什么」）】
##   ① 虚函数 `on_state_changed(is_on)` —— 派生脚本重写即可（演出 / 音效 / 开门等）；
##   ② 固定信号 `switched(is_on)` —— 场景里用信号面板连；
##   ③ 命名信号 `signal_on_name` / `signal_off_name` —— 给 SignalVisibilityNode 之类用。

## 固定信号：任何一次翻转都会发（带状态），与命名信号并存。
signal switched(is_on: bool)

# ═══════════════════════════════════════
# 配置 — 开关
# ═══════════════════════════════════════
@export_group("开关")
## 摆放时的初始状态（勾上 = 一开始就是「开」）。
@export var start_on: bool = false
## 「开」时发出的信号名（监听方按名字连）。
@export var signal_on_name: String = "switch_on"
## 「关」时发出的信号名。
@export var signal_off_name: String = "switch_off"

@export_group("状态 A（关）")
## 关状态的贴图（留空 = 沿用基类 texture）。
@export var off_texture: Texture2D
## 关状态的角色格（-1 = 沿用基类 walk_char_index）。
@export var off_char_index: int = -1
## 关状态的朝向（-1 = 沿用基类 walk_direction）。
@export var off_direction: int = -1

@export_group("状态 B（开）")
## 开状态的贴图（留空 = 沿用基类 texture）。
@export var on_texture: Texture2D
## 开状态的角色格（-1 = 沿用基类 walk_char_index）。
@export var on_char_index: int = -1
## 开状态的朝向（-1 = 沿用基类 walk_direction）。
@export var on_direction: int = -1

@export_group("状态位移")
## 关状态相对**摆放位置**的终点偏移（ZERO = 原地不动，只换图/发信号）。
@export var off_offset: Vector2 = Vector2.ZERO
## 开状态相对**摆放位置**的终点偏移。
@export var on_offset: Vector2 = Vector2.ZERO
## 关状态的移动时长（≤0 = 用基类的 duration）。
@export var off_duration: float = -1.0
## 开状态的移动时长（≤0 = 用基类的 duration）。
@export var on_duration: float = -1.0

# ═══════════════════════════════════════
# 配置 — 交互
# ═══════════════════════════════════════
@export_group("交互")
## 关状态下的靠近提示。
@export var interact_label: String = "开关"
## 开状态下的靠近提示（留空 = 沿用上面那条）。
@export var interact_label_on: String = ""
## 交互距离（px）。
@export_range(8.0, 512.0, 1.0) var interact_range: float = 56.0

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _is_on: bool = false
var _home: Vector2 = Vector2.ZERO
var _can_interact: bool = false
var _label: Label = null


func _ready() -> void:
	_home = position
	_is_on = start_on
	super._ready()
	_ensure_label()
	_ensure_user_signals()
	_apply_state_appearance()
	_refresh_sprite()
	_update_label()
	if Engine.is_editor_hint():
		return
	add_to_group("interactive_switch")


func _process(delta: float) -> void:
	super._process(delta)
	if Engine.is_editor_hint():
		return
	_check_player_proximity()
	_update_label()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if not _can_interact or not is_visible_in_tree():
		return
	if event.is_action_pressed("确定键"):
		## 与传送点 / 安全门 / 结局触发器一致：UI 先消费按键，不隔着菜单误触发。
		get_viewport().set_input_as_handled()
		interact()


## 开关默认**不接外部信号**（主入口是玩家互动）；要接就把基类的 trigger_source_path 填上。
## 这样没有防守机器的场景不会每次启动都打印「找不到触发源」。
func _connect_trigger() -> void:
	if trigger_source_path.is_empty():
		return
	super._connect_trigger()


## 基类的 trigger（外部信号入口）在开关上等同于「翻一次」。
func trigger() -> void:
	interact()


# ═══════════════════════════════════════
# 状态
# ═══════════════════════════════════════

## 玩家按下确定键（也会检查距离 / 可见性）。
func interact() -> void:
	if not is_visible_in_tree():
		return
	if not _can_interact:
		return
	toggle()


func toggle() -> void:
	set_on(not _is_on)


func is_on() -> bool:
	return _is_on


## 切到指定状态：换外观 → 移动到该状态终点 → 发命名信号 → `switched` → `on_state_changed`。
## `animate=false` 时直接落位（读档 / 初始化用）。
func set_on(value: bool, animate: bool = true) -> void:
	_is_on = value
	_apply_state_appearance()
	if animate:
		_start_move(_state_duration())
	else:
		position = _state_target_local()
	_ensure_user_signals()
	_emit_state_signal()
	switched.emit(_is_on)
	on_state_changed(_is_on)
	_update_label()


## ★自定义接口：状态变化后调用。派生脚本重写它即可挂演出 / 音效 / 开门等，
## 也可以不重写、直接在场景里连 `switched` 信号。
func on_state_changed(_is_on: bool) -> void:
	pass


## 开关的终点一律以「摆放位置 + 该状态偏移」为准 —— 反复翻转一定回到原位，
## 不会因为基类的「当前位置 + 偏移」而越走越远。
func target_local_position() -> Vector2:
	return _state_target_local()


func _state_target_local() -> Vector2:
	return _home + (on_offset if _is_on else off_offset)


func _state_duration() -> float:
	var d: float = on_duration if _is_on else off_duration
	return d if d > 0.0 else duration


func _apply_state_appearance() -> void:
	var tex: Texture2D = on_texture if _is_on else off_texture
	if tex != null:
		texture = tex   ## setter 内部会 _refresh_sprite
	var idx: int = on_char_index if _is_on else off_char_index
	if idx >= 0:
		walk_char_index = idx
	var dir: int = on_direction if _is_on else off_direction
	if dir >= 0:
		walk_direction = dir
	_refresh_sprite()


## 命名信号：名字作者可改，所以运行时 add_user_signal 注册（已存在则跳过）。
func _ensure_user_signals() -> void:
	for raw: String in [signal_on_name, signal_off_name]:
		var sig_name: String = raw.strip_edges()
		if sig_name.is_empty() or has_signal(sig_name):
			continue
		add_user_signal(sig_name)


func _emit_state_signal() -> void:
	var sig_name: String = (signal_on_name if _is_on else signal_off_name).strip_edges()
	if sig_name.is_empty():
		return
	if not has_signal(sig_name):
		add_user_signal(sig_name)
	emit_signal(sig_name)


# ═══════════════════════════════════════
# 提示 / 距离
# ═══════════════════════════════════════

func _ensure_label() -> void:
	if _label != null and is_instance_valid(_label):
		return
	_label = get_node_or_null("HintLabel") as Label
	if _label == null:
		_label = Label.new()
		_label.name = "HintLabel"
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.position = Vector2(-90, -56)
		_label.size = Vector2(180, 24)
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label.hide()
		add_child(_label)
	## 字体 / 阴影无条件套（预置节点同样要吃到全局样式）
	var g: Node = get_node_or_null("/root/Global")
	if g:
		if g.has_method("apply_hint_font"):
			g.apply_hint_font(_label, 12)
		if g.has_method("apply_text_shadow"):
			g.apply_text_shadow(_label)


func _update_label() -> void:
	if _label == null:
		return
	var show: bool = _can_interact and is_visible_in_tree()
	if _label.visible != show:
		_label.visible = show
	if not show:
		return
	var text: String = interact_label
	if _is_on and not interact_label_on.strip_edges().is_empty():
		text = interact_label_on
	if _label.text != text:
		_label.text = text


func _check_player_proximity() -> void:
	var player: Node2D = _local_player()
	if player == null or not is_instance_valid(player):
		_can_interact = false
		return
	_can_interact = global_position.distance_to(player.global_position) <= interact_range


## 联机只看**本机操控的实体**（与医疗箱 / HintMarker / FinaleTrigger 同口径）。
func _local_player() -> Node2D:
	var net: Node = get_node_or_null("/root/Net")
	if net != null and net.has_method("is_online_session") and bool(net.is_online_session()):
		return Players.get_local_entity()
	return Players.nearest_entity_to(global_position)
