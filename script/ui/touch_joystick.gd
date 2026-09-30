extends Control

## ── 架构定位 ──
## 系统：触摸操作 ｜ 层：表现（Control）
## 联机：不涉及
## 职责：虚拟摇杆：在摇杆区域内触摸拖动 → 输出 上/下/左/右 四个 InputMap 动作的按下与松开。
## 依赖：`Global.dispatch_virtual_action()`（改动作状态 + 补发 InputEventAction，唯一入口）
##
## 用法：把本节点放在左下角，尺寸即摇杆的触摸热区（建议 280~320px）。
## 视觉：子节点 `Base`（圆形底盘，铺满热区）+ `Knob`（摇杆头，居中）。
## ★按下处即摇杆中心（**浮动摇杆**）：整组随按下点平移，摇杆头再按拖动方向偏移，松手全部复位。

## 死区：位移比例小于它就不触发方向（避免误触）。
@export_range(0.0, 0.9, 0.01) var dead_zone: float = 0.28
## 摇杆头最大位移比例（相对半径）。
@export_range(0.1, 1.0, 0.01) var knob_max_ratio: float = 0.42

## ── 视觉节点（都走 **NodePath**）──
## ★为什么不能用 `@export var knob: Control`：
##   .tscn 里只能写成 `knob = NodePath("Knob")`，而 Godot 不会把它解析成 Control
##   （实测读回 **null**）→ 摇杆头永远不动 = 用户报的「拖摇杆时头不跟着动」（2026-09-29）。
##   导出成 NodePath 再自己 get_node 才是可靠的绑定方式。
@export var base_path: NodePath = ^"Base"
@export var knob_path: NodePath = ^"Knob"

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
var _base: Control = null
var _knob: Control = null
var _base_home: Vector2 = Vector2.ZERO
var _knob_home: Vector2 = Vector2.ZERO
var _global: Node = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_global = get_node_or_null("/root/Global")
	## ⚠ 铁律：先拿 Node 再 `is` 判定，**禁**「先 as 后判 valid」（对已释放对象 `as` 会抛错）。
	var nb: Node = get_node_or_null(base_path)
	if nb is Control:
		_base = nb
		_base_home = _base.position
	var nk: Node = get_node_or_null(knob_path)
	if nk is Control:
		_knob = nk
		_knob_home = _knob.position
	_origin = size * 0.5
	_sync_visual()


## ★一律走 Global.dispatch_virtual_action()（2026-09-29 手机实测）：只按 `Input.action_press()`
## 不会派发事件 → 菜单光标（读 `_input` 事件）推不动。
func _forward(act: StringName, pressed: bool) -> void:
	if _global != null and _global.has_method("dispatch_virtual_action"):
		_global.call("dispatch_virtual_action", act, pressed)
	else:
		push_warning("[TouchJoystick] 找不到 /root/Global，摇杆输入未派发（act=%s）" % act)


## 由 TouchControls 调用：菜单模式默认保留（摇杆正好用来走菜单光标）。
## `scene_key` 只有按钮用得上（菜单场景白名单），摇杆忽略。
func set_menu_mode(menu_mode: bool, _scene_key: String = "") -> void:
	visible = (not menu_mode) or show_in_menu
	if not visible:
		## ★隐藏时必须先松开：否则角色会一直朝最后的方向走。
		_release_all()


## ★临时诊断（2026-09-30）：手机端触摸位置对不上，先打真实数值（含摇杆）。
const DIAG_LIMIT: int = 40
static var _diag_count: int = 0


func _diag(msg: String) -> void:
	if _diag_count >= DIAG_LIMIT:
		return
	_diag_count += 1
	print("[触摸诊断-摇杆 %d] %s" % [_diag_count, msg])


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed:
			_diag("收到触点 idx=%d pos(局部)=%s size=%s global=%s" % [
				t.index, t.position, size, get_global_rect()])
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


## 触摸热区的等效半径（取较短边的一半）。
func _radius() -> float:
	return maxf(minf(size.x, size.y) * 0.5, 1.0)


func _update(pos: Vector2) -> void:
	var radius: float = _radius()
	var v: Vector2 = pos - _origin
	if v.length() > radius:
		v = v.normalized() * radius
	_dir = v / radius
	_apply()
	_sync_visual()


## 把「底盘 + 摇杆头」画到当前手指位置与方向上。
## 浮动摇杆：整组按「按下点 − 热区中心」平移（按下处即摇杆中心）；摇杆头再沿 _dir 偏移。
func _sync_visual() -> void:
	var shift: Vector2 = Vector2.ZERO
	if _active_index != -2:
		shift = _origin - size * 0.5
	if _base != null and is_instance_valid(_base):
		_base.position = _base_home + shift
	if _knob != null and is_instance_valid(_knob):
		_knob.position = _knob_home + shift + _dir * _radius() * knob_max_ratio


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
			_forward(act, true)
		elif not want and held:
			_pressed[act] = false
			_forward(act, false)


func _release_all() -> void:
	_active_index = -2
	_dir = Vector2.ZERO
	for key: Variant in _pressed.keys():
		if bool(_pressed[key]):
			_forward(key, false)
	_pressed.clear()
	_sync_visual()


## 换场景 / 节点被移除时兜底松开，避免"角色一直往一个方向走"。
func _exit_tree() -> void:
	_release_all()
