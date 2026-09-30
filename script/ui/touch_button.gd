extends Button

## ── 架构定位 ──
## 系统：触摸操作 ｜ 层：表现（Control）
## 联机：不涉及 —— 只把触摸转成既有 InputMap 动作，动作本身的权威判定完全不变
## 职责：**一个触摸按钮 = 一个 InputMap 动作的按下/松开来源**。
## 依赖：`Global.dispatch_virtual_action()`（改动作状态 + 补发 InputEventAction，唯一入口）

## 该按钮映射到的 InputMap 动作名（在编辑器里逐个节点设置）。
## 可用值见 project.godot 的 [input] 段：确定键 / 装填键 / SA键 / 推击键 / 功能键 /
## 治疗品键 / 辅助品键 / 投掷物键 / 主武器键 / 副武器键 / 菜单键 / 取消键 /
## 丢弃武器键 / 切换角色键 / 举起放下武器键 / 行走键 …
@export var action: StringName = &"确定键"

## 松手时是否立即松开该动作。持枪/行走类需要"按住持续"，保持 true 即可；
## 单次触发的动作（如丢弃武器）也无需改 —— 松开本来就该结束。
@export var release_on_up: bool = true

## ── 可见性规则（2026-09-29）──
## 前端菜单（标题 / 角色选择 / 难度 / 章节选择 / 结算页）是 RM2K3 光标式，只认
## `确定键` / `上` / `下` / `取消键`。菜单里显示整套战斗按钮会盖住菜单 →
## 只让「确定 / 取消」留下。由 TouchControls 按当前场景自动调用 set_menu_mode()。
##
## 三种常用组合：
##   ① 两模式都要（攻击=确定、取消、摇杆）→ `show_in_menu = true`
##   ② **只在菜单里**（如「开始游戏」）      → `show_in_menu = true` + `hide_in_gameplay = true`
##   ③ 只在关卡里（装填 / 物品 / 切人…）    → 两个都用默认 false
@export var show_in_menu: bool = false
## 关卡模式下隐藏（配合 `show_in_menu` 得到「只在菜单里出现」的按钮）。
@export var hide_in_gameplay: bool = false
## 菜单模式下替换的文字（留空 = 不改）。例：攻击键（=确定键）在菜单里显示「确定」。
@export var menu_text: String = ""
## 菜单模式下**只在这些场景**显示（按场景脚本文件名匹配，**不含**扩展名）。
## 留空 = 所有菜单场景都显示。例：「开始游戏」只在角色选择界面有意义 →
## `["character_select_menu"]`（全项目只有它读 `开始游戏键`，其余菜单显示它纯属干扰）。
@export var menu_scene_filter: PackedStringArray = PackedStringArray()

## ★多点触控（2026-09-29 手机实测「按住摇杆时其他按钮全失灵」）：
## Godot 的 `Input.emulate_mouse_from_touch` **只把第一个触点模拟成鼠标事件**，
## 而 `Button` 的按下完全依赖鼠标事件 → 第一根手指占着摇杆时，第二根手指按攻击键
## 什么都收不到。所以触摸按钮改为**自己处理 `InputEventScreenTouch`**，各按钮按触点
## index 独立跟踪，与摇杆互不干扰。（桌面端鼠标点击照常处理，调试不受影响。）
var _touch_index: int = -2   ## 本按钮当前负责的触点；-2 = 空闲
var _mouse_held: bool = false
var _held: bool = false
var _base_text: String = ""
var _global: Node = null


func _ready() -> void:
	_base_text = text
	focus_mode = Control.FOCUS_NONE
	_global = get_node_or_null("/root/Global")
	## ⚠ 刻意**不接** `button_down`/`button_up`：那两个信号来自鼠标模拟，只有第一个
	## 触点会触发（见上）。改由 `_input()` 自己按触点 index 处理。
	## ⚠ `_input` 在 GUI 之前收到事件，所以 Button 自己那套鼠标处理不会把它吃掉。


## ★把触摸事件的坐标换成 **viewport 逻辑坐标**（2026-09-30 用户实测「按下的位置与按钮视觉位置对不上」）。
## 根因：Godot 只对 `InputEventMouse` 系列做 content-scale 变换，**`InputEventScreenTouch` /
## `ScreenDrag` 的 `position` 保持屏幕坐标** —— 而 `get_global_rect()` 是逻辑坐标。
## 一旦画面有非 1:1 缩放（手机端分数缩放 0.75 / 1.125），两者就整体错位。
## ⚠ 摇杆走 `_gui_input`，坐标由 GUI 系统自动转过，所以没这个问题 —— 只有本文件（`_input`）要自己转。
func _to_logical(screen_pos: Vector2) -> Vector2:
	var vp: Viewport = get_viewport()
	if vp == null:
		return screen_pos
	return vp.get_final_transform().affine_inverse() * screen_pos


func _input(event: InputEvent) -> void:
	if not visible or action == &"":
		return
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed:
			if _touch_index == -2 and get_global_rect().has_point(_to_logical(t.position)):
				_touch_index = t.index
				_on_down()
		elif t.index == _touch_index:
			_on_up()
	elif event is InputEventScreenDrag:
		## 手指滑出按钮范围 → 松开。多点触控下 Button 的 `mouse_exited` 兜底不可靠，
		## 少了这一步会出现"动作一直按着"（角色一直走 / 一直开枪）。
		var d: InputEventScreenDrag = event
		if d.index == _touch_index and not get_global_rect().has_point(_to_logical(d.position)):
			_on_up()
	elif event is InputEventMouseButton:
		## 鼠标事件 Godot 已经变换过了 → 直接用 `mb.position`（不要重复变换）。
		var mb: InputEventMouseButton = event
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			if not _mouse_held and get_global_rect().has_point(mb.position):
				_mouse_held = true
				_on_down()
		elif _mouse_held:
			_mouse_held = false
			_on_up()


## ★一律走 Global.dispatch_virtual_action()（2026-09-29 手机实测）：
## `Input.action_press()` **只改状态、不派发事件** → 只认 `_input` 的菜单收不到 → 按了没反应。
func _forward(act: StringName, pressed: bool) -> void:
	if _global != null and _global.has_method("dispatch_virtual_action"):
		_global.call("dispatch_virtual_action", act, pressed)
	else:
		push_warning("[TouchButton] 找不到 /root/Global，虚拟按键未派发（act=%s）" % act)


## 由 TouchControls 调用：按模式（+ 当前菜单场景）决定显隐，并可选替换文字。
## `scene_key` = 当前场景脚本的文件名（不含扩展名），供 `menu_scene_filter` 过滤。
func set_menu_mode(menu_mode: bool, scene_key: String = "") -> void:
	if menu_mode:
		visible = show_in_menu and (menu_scene_filter.is_empty() or menu_scene_filter.has(scene_key))
	else:
		visible = not hide_in_gameplay
	if not visible:
		## ★隐藏时必须先松开：按钮被隐藏后收不到 button_up → 动作会永远保持按下
		##（角色一直走 / 一直开枪）。切场景那一帧正好会走到这里。
		_on_up()
	text = menu_text if (menu_mode and not menu_text.is_empty()) else _base_text


func _on_down() -> void:
	if action == &"" or _held:
		return
	_held = true
	_forward(action, true)


func _on_up() -> void:
	_touch_index = -2
	_mouse_held = false
	if action == &"" or not _held:
		return
	_held = false
	if release_on_up:
		_forward(action, false)


## 节点被移除 / 换场景时兜底松开 —— 否则动作会一直保持按下状态。
func _exit_tree() -> void:
	if _held:
		_held = false
		if action != &"":
			_forward(action, false)
