@tool
class_name InteractiveSwitchNode
extends "res://script/director/move_node.gd"

## ── 架构定位 ──
## 系统：关卡机关（开关 / 拉杆 / 电闸）｜ 层：玩法（Node2D，继承 MoveNode）
## 联机：**各端本地表现** —— 信号由各端自己发（互动方是本机玩家），无 RPC、无同步
## 职责：在 MoveNode 的基础上加「可互动 + 双状态开关」：
##       玩家按功能键 → 状态翻转 → ①换行走图 ②按状态移动到各自终点 ③发**该状态的命名信号**
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

## 双状态动画开关的三态（对应 Inspector 下拉：沿用基类 / 开启 / 关闭）。
## 用三态而不是 bool：bool 无法表达「这个状态不覆盖，沿用基类」。
enum AnimOverride { INHERIT = 0, ENABLED = 1, DISABLED = 2 }

## 提示文字统一渲染层（不被角色/图块遮挡、不吃夜图暗度），见 script/ui/hint_text_layer.gd
const HINT_LAYER := preload("res://script/ui/hint_text_layer.gd")
## 成就系统入口（preload 常量而不是 class_name：本项目 class_name 不进全局类缓存）。
const ACHIEVEMENTS := preload("res://script/achievements.gd")

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

# ═══════════════════════════════════════
# 配置 — 双状态动画（2026-10-28 用户需求）
# ═══════════════════════════════════════
## 每个状态可以单独覆盖踏步 / 朝向动画：沿用基类（默认）、强制开、强制关；
## 帧序列留空 = 沿用基类的 step_frames / facing_frames，时长 <=0 = 沿用基类。
## ⚠ 只在基类 `use_walk_sprite = true` 时生效（非行走图模式本来就不取帧动画）。
@export_group("状态 A（关）· 动画")
@export_enum("沿用基类", "开启", "关闭") var off_step_animated: int = AnimOverride.INHERIT
## 关状态的踏步帧序列（空 = 沿用基类）。
@export var off_step_frames: Array[int] = []
## 关状态的踏步间隔秒数（<=0 = 沿用基类）。
@export_range(-1.0, 5.0, 0.01) var off_step_duration: float = -1.0
@export_enum("沿用基类", "开启", "关闭") var off_facing_animated: int = AnimOverride.INHERIT
## 关状态的朝向帧序列（0=下 1=左 2=右 3=上；空 = 沿用基类）。
@export var off_facing_frames: Array[int] = []
## 关状态的朝向切换间隔秒数（<=0 = 沿用基类）。
@export_range(-1.0, 5.0, 0.01) var off_facing_duration: float = -1.0

@export_group("状态 B（开）· 动画")
@export_enum("沿用基类", "开启", "关闭") var on_step_animated: int = AnimOverride.INHERIT
## 开状态的踏步帧序列（空 = 沿用基类）。
@export var on_step_frames: Array[int] = []
## 开状态的踏步间隔秒数（<=0 = 沿用基类）。
@export_range(-1.0, 5.0, 0.01) var on_step_duration: float = -1.0
@export_enum("沿用基类", "开启", "关闭") var on_facing_animated: int = AnimOverride.INHERIT
## 开状态的朝向帧序列（0=下 1=左 2=右 3=上；空 = 沿用基类）。
@export var on_facing_frames: Array[int] = []
## 开状态的朝向切换间隔秒数（<=0 = 沿用基类）。
@export_range(-1.0, 5.0, 0.01) var on_facing_duration: float = -1.0

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

@export_group("照明开关（成就判定）")
## 本开关是否算「照明」。玩家把它拨到「开」时记一次 `Achievements.on_lights_used()`，
## 用于原作成就「我们是暗夜族」（夜行猎手终章全程不打开照明）。
## ⚠ 只对**拨到开**记一次；关掉再开也只记同一局（幂等）。默认 false，不影响其它机关。
@export var is_light_switch: bool = false

# ═══════════════════════════════════════
# 配置 — 联动（2026-10-28 用户需求）
# ═══════════════════════════════════════
@export_group("联动")
## 绑定的其他开关（路径：先按**相对本节点**找，找不到再按**相对场景根**找）。
## 本开关状态变化时同步给它们：一个开 → 另一个也开；一个关 → 另一个也关。
## · 双向联动**只在一侧填**就够（传播只走一跳，被联动方不会再传回来）；
## · 两侧都填也不会死循环（同一跳内的二次传播被 `_link_depth` 挡掉）；
## · 同步会走对方的完整 `set_on()`，因此对方的外观/位移/命名信号/`switched` 都会照常触发。
## ⚠ 初始状态不自动同步：两个开关的 `start_on` 请配成一致。
@export var linked_switches: Array[NodePath] = []

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _is_on: bool = false
var _home: Vector2 = Vector2.ZERO
var _can_interact: bool = false
var _label: Label = null
var _key_hint: String = "功能键"

## ── 基类原值快照（2026-10-28）──
## 状态覆盖项留空（-1 / null / 空数组）时必须能**回到基类值**。
## 旧实现只在「有覆盖」时赋值 → 关状态没配 off_* 就永远停在开状态的 char/direction，
## 表现就是「开了开关就关不回去」（用户实测）。
var _base_texture: Texture2D = null
var _base_char_index: int = 0
var _base_direction: int = 0
var _base_animated: bool = true
var _base_step_frames: Array[int] = []
var _base_step_duration: float = 0.25
var _base_facing_animated: bool = false
var _base_facing_frames: Array[int] = []
var _base_facing_duration: float = 0.25


func _ready() -> void:
	_home = position
	_is_on = start_on
	## ★必须早于任何 `_apply_state_appearance()`：那一步会把状态覆盖写进基类字段。
	_capture_base_state()
	super._ready()
	_ensure_label()
	_ensure_user_signals()
	_apply_state_appearance()
	_refresh_sprite()
	_update_label()
	if Engine.is_editor_hint():
		return
	add_to_group("interactive_switch")


## 记录基类原值（贴图 / 角色格 / 朝向 / 四条动画参数），供「该状态没配覆盖」时回退。
func _capture_base_state() -> void:
	_base_texture = texture
	_base_char_index = walk_char_index
	_base_direction = walk_direction
	_base_animated = animated
	_base_step_frames = step_frames.duplicate()
	_base_step_duration = step_duration
	_base_facing_animated = facing_animated
	_base_facing_frames = facing_frames.duplicate()
	_base_facing_duration = facing_duration


func _process(delta: float) -> void:
	super._process(delta)
	if Engine.is_editor_hint():
		return
	_check_player_proximity()
	_update_label()
	## 功能键走**轮询**而不是 _unhandled_input：事件路径依赖"没人先 consume"，
	## 任何一处 consume 都会让它静默失效（2026-10-02 用户实测「互动不了」的根因），
	## 与医疗箱 / 弹药堆 / 防守机器同一口径。
	if _can_interact and Input.is_action_just_pressed("功能键"):
		interact()


## ── 交互输入仲裁（2026-10-27）──
## 语义：此刻按「功能键」，本节点会不会真的做事（详见 `interact_priority.gd`）。
## 必须与 `interact()` 的门禁**完全一致**：不可见 / 玩家不在范围内都要返回 false，
## 否则隐形的开关会把功能键从存档点手里抢走。
func can_use_function_key() -> bool:
	if Engine.is_editor_hint():
		return false
	return _can_interact and is_visible_in_tree()


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

## 玩家状态下按功能键（也会检查距离 / 可见性）。
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


## 切到指定状态：换外观 → 移动到该状态终点 → 发命名信号 → `switched` → `on_state_changed`
## → 同步给 `linked_switches`。`animate=false` 时直接落位（读档 / 初始化用）。
func set_on(value: bool, animate: bool = true) -> void:
	_is_on = value
	## 成就「我们是暗夜族」：照明开关被拨到「开」就记一笔（关掉不会清除本局记录）。
	if _is_on and is_light_switch:
		ACHIEVEMENTS.on_lights_used()
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
	_propagate_links(value, animate)


## 联动传播深度（静态）：>0 说明本次状态变化是被别的开关联动过来的 → 不再往下传，
## 这样 A↔B 互绑也不会 A→B→A 无限来回。代价是**只传播一跳**：
## 三个以上串联请把每个开关的 `linked_switches` 都直接填全。
static var _link_depth: int = 0


## 把本次状态同步给绑定的开关（走对方的完整 `set_on`，对方的信号/动画照常触发）。
func _propagate_links(value: bool, animate: bool) -> void:
	if _link_depth > 0 or linked_switches.is_empty():
		return
	_link_depth += 1
	for path: NodePath in linked_switches:
		var other: Node = _resolve_linked_switch(path)
		if other == null or other == self:
			continue
		if other.has_method("set_on"):
			other.call("set_on", value, animate)
		else:
			push_warning("[InteractiveSwitch] %s 的联动目标 %s 不是开关" % [name, str(path)])
	_link_depth -= 1


## 联动路径解析：先相对本节点，再相对场景根（与 HoldoutMachine 的节点路径同口径）。
func _resolve_linked_switch(path: NodePath) -> Node:
	if path.is_empty():
		return null
	var node: Node = get_node_or_null(path)
	if node != null:
		return node
	var tree: SceneTree = get_tree()
	if tree != null and tree.current_scene != null:
		return tree.current_scene.get_node_or_null(path)
	return null


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
	## 有覆盖就用覆盖；**没覆盖必须回退基类原值** —— 旧实现只是「不赋值」，
	## 结果切到开状态后，关状态没配 off_char_index / off_direction 就永远回不去，
	## 表现即「开了开关就关不了」（2026-10-28 用户实测）。
	var tex: Texture2D = on_texture if _is_on else off_texture
	texture = tex if tex != null else _base_texture
	var idx: int = on_char_index if _is_on else off_char_index
	walk_char_index = idx if idx >= 0 else _base_char_index
	var dir: int = on_direction if _is_on else off_direction
	walk_direction = dir if dir >= 0 else _base_direction
	_apply_state_animation()
	_refresh_sprite()


## 双状态动画（2026-10-28 用户需求）：踏步 / 朝向各自「三态开关 + 帧序列 + 间隔」。
## 空序列 / 非正时长 = 沿用基类；切换后重置相位，避免沿用上一状态的下标。
func _apply_state_animation() -> void:
	var step_mode: int = on_step_animated if _is_on else off_step_animated
	animated = _base_animated if step_mode == AnimOverride.INHERIT \
			else (step_mode == AnimOverride.ENABLED)
	var step_seq: Array[int] = on_step_frames if _is_on else off_step_frames
	step_frames = step_seq.duplicate() if not step_seq.is_empty() else _base_step_frames.duplicate()
	var step_dur: float = on_step_duration if _is_on else off_step_duration
	step_duration = step_dur if step_dur > 0.0 else _base_step_duration

	var face_mode: int = on_facing_animated if _is_on else off_facing_animated
	facing_animated = _base_facing_animated if face_mode == AnimOverride.INHERIT \
			else (face_mode == AnimOverride.ENABLED)
	var face_seq: Array[int] = on_facing_frames if _is_on else off_facing_frames
	facing_frames = face_seq.duplicate() if not face_seq.is_empty() else _base_facing_frames.duplicate()
	var face_dur: float = on_facing_duration if _is_on else off_facing_duration
	facing_duration = face_dur if face_dur > 0.0 else _base_facing_duration

	## 重置相位与计时：序列可能变短（旧下标会越界），也会让切换瞬间"跳一帧"。
	_step_index = 0
	_facing_index = 0
	_step_timer = step_duration
	_facing_timer = facing_duration


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
		if g.has_method("key_hint"):
			_key_hint = String(g.call("key_hint", &"功能键"))
	## ★提示文字层（2026-10-28）：搬到提示层（layer=89；不被角色/图块遮挡、不吃夜图暗度）。
	HINT_LAYER.attach(_label)


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
	text = "%s  [%s]" % [text, _key_hint]
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
