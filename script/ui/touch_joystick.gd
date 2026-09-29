extends Control

## ── 架构定位 ──
## 系统：触摸操作 ｜ 层：表现（Control）
## 联机：不涉及
## 职责：虚拟摇杆：在摇杆区域内触摸拖动 → 输出 上/下/左/右 四个 InputMap 动作的按下与松开。
## 依赖：无
##
## 用法：把本节点放在左下角，尺寸即摇杆的触摸热区（建议 280~320px）。
## 摇杆头（Knob）可选：在编辑器里把子节点拖到 `knob` 上，拖动时会跟随手指。

## 死区：位移比例小于它就不触发方向（避免误触）。
@export_range(0.0, 0.9, 0.01) var dead_zone: float = 0.28
## 摇杆头最大位移比例（相对半径）。
@export_range(0.1, 1.0, 0.01) var knob_max_ratio: float = 0.42
## 摇杆头节点（可选，拖动时跟随）。
@export var knob: Control = null

## ── 菜单模式（2026-09-29）──
## 菜单界面的光标也是靠 `上/下` 动作走的，所以摇杆默认在菜单里**保留**。
@export var show_in_menu: bool = true

@export_group("输出动作")
@export var up_action: StringName = &"上"
@export var down_action: StringName = &"下"
@export var left_action: StringName = &"左"
@export var right_action: StringName = &"右"

## 激活的触点索引（触摸为 index；鼠标模拟用 -1 表示未激活，0 表示鼠标）。
var _active_index: int = -2
var _origin: Vector2 = Vector2.ZERO
var _dir: Vector2 = Vector2.ZERO
var _pressed: Dictionary = {}
var _knob_home: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if knob != null and is_instance_valid(knob):
		_knob_home = knob.position
	_origin = size * 0.5


## 由 TouchControls 调用：菜单模式默认保留（摇杆正好用来走菜单光标）。
func set_menu_mode(menu_mode: bool) -> void:
	visible = (not menu_mode) or show_in_menu
	if not visible:
		## ★隐藏时必须先松开：否则角色会一直朝最后的方向走。
		_release_all()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed and _active_index == -2:
			_active_index = t.index
			_origin = t.position
			_update(t.position)
		elif not t.pressed and t.index == _active_index:
			_release_all()
	elif event is InputEventScreenDrag:
		var d: InputEventScreenDrag = event
		if d.index == _active_index:
			_update(d.position)
	elif event is InputEventMouseButton:
		## 桌面端调试用：鼠标按下拖动等价于触摸（导出包不会有鼠标，故无副作用）。
		var mb: InputEventMouseButton = event
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed and _active_index == -2:
			_active_index = 0
			_origin = mb.position
			_update(mb.position)
		elif not mb.pressed and _active_index == 0:
			_release_all()
	elif event is InputEventMouseMotion and _active_index == 0:
		_update((event as InputEventMouseMotion).position)


func _update(pos: Vector2) -> void:
	var radius: float = maxf(minf(size.x, size.y) * 0.5, 1.0)
	var v: Vector2 = pos - _origin
	if v.length() > radius:
		v = v.normalized() * radius
	_dir = v / radius
	if knob != null and is_instance_valid(knob):
		knob.position = _knob_home + _dir * radius * knob_max_ratio
	_apply()


func _apply() -> void:
	var wants: Dictionary = {
		up_action: _dir.y < -dead_zone,
		down_action: _dir.y > dead_zone,
		left_action: _dir.x < -dead_zone,
		right_action: _dir.x > dead_zone,
	}
	for key: Variant in wants.keys():
		var act: StringName = key
		if act == &"":
			continue
		var want: bool = bool(wants[key])
		var held: bool = bool(_pressed.get(act, false))
		if want and not held:
			_pressed[act] = true
			Input.action_press(act)
		elif not want and held:
			_pressed[act] = false
			Input.action_release(act)


func _release_all() -> void:
	_active_index = -2
	_dir = Vector2.ZERO
	for key: Variant in _pressed.keys():
		if bool(_pressed[key]):
			Input.action_release(key)
	_pressed.clear()
	if knob != null and is_instance_valid(knob):
		knob.position = _knob_home


## 换场景 / 节点被移除时兜底松开，避免"角色一直往一个方向走"。
func _exit_tree() -> void:
	_release_all()
