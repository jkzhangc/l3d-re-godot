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
## 布局编辑模式（2026-09-30）：为 true 时不响应输入，拖动交给 TouchControls 统一处理。
var _layout_edit: bool = false
var _edit_outline: Panel = null
var _edit_outline_sb: StyleBoxFlat = null
## 「模式显隐」：由 set_menu_mode 按菜单/关卡算出的**逻辑**可见性。
var _mode_visible: bool = true
## 「玩家隐藏」：在「按键布局」里点一下隐藏。最终 visible = 两者相与。
var _custom_hidden: bool = false
## 编辑模式下本摇杆当前是否处于"已隐藏"（红描边 + 半透明）。
var _edit_hidden: bool = false


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
	_mode_visible = (not menu_mode) or show_in_menu
	_apply_visibility()


## 最终显隐 = 「模式显隐」∧「未被玩家隐藏」。
## ★不可见时必须先松开：否则角色会一直朝最后的方向走。
func _apply_visibility() -> void:
	visible = _mode_visible and not _custom_hidden
	if not visible:
		_release_all()


## 由 TouchControls 应用玩家的隐藏设置（隐藏 = 不显示、不吃触摸）。
func set_custom_hidden(on: bool) -> void:
	if _custom_hidden == on:
		return
	_custom_hidden = on
	_apply_visibility()


## 编辑模式下标记「本摇杆当前是隐藏的」：红描边 + 半透明。
func set_edit_hidden(hidden: bool) -> void:
	_edit_hidden = hidden
	modulate = Color(1, 1, 1, 0.4) if hidden else Color.WHITE
	if _edit_outline_sb != null:
		var c: Color = Color(1.0, 0.35, 0.3, 0.95) if hidden else Color(1.0, 0.9, 0.3, 0.95)
		_edit_outline_sb.border_color = c
		_edit_outline_sb.bg_color = Color(c.r, c.g, c.b, 0.08)


## ★临时诊断（2026-09-30）：手机端触摸位置对不上，先打真实数值（含摇杆）。
const DIAG_LIMIT: int = 40
static var _diag_count: int = 0


func _diag(msg: String) -> void:
	if _diag_count >= DIAG_LIMIT:
		return
	_diag_count += 1
	print("[触摸诊断-摇杆 %d] %s" % [_diag_count, msg])


## ── 布局编辑模式（2026-09-30 用户需求：手机端可自由拖动摇杆位置）──
## 进入后摇杆**不响应输入**（否则拖动摇杆 = 角色一直走），只保留"能被拖"这一件事。
## ⚠ 进入时先 `_release_all()`：手指可能正推着摇杆，不松开会让角色一直朝那个方向走。
func set_layout_edit(on: bool) -> void:
	if _layout_edit == on:
		return
	_layout_edit = on
	if on:
		_release_all()
	else:
		## 退出编辑：清掉「已隐藏」的半透明与红框，回到正常外观。
		_edit_hidden = false
		modulate = Color.WHITE
	_apply_edit_outline(on)


## 描边用**子节点**（Panel）：它是摇杆的孩子 → 拖动时自动跟随；铺满热区即为「可拖范围」。
func _apply_edit_outline(on: bool) -> void:
	if on:
		if _edit_outline == null or not is_instance_valid(_edit_outline):
			var p := Panel.new()
			p.name = "LayoutEditOutline"
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(1.0, 0.9, 0.3, 0.08)
			sb.border_color = Color(1.0, 0.9, 0.3, 0.95)
			sb.set_border_width_all(2)
			sb.set_corner_radius_all(12)
			p.add_theme_stylebox_override("panel", sb)
			p.mouse_filter = Control.MOUSE_FILTER_IGNORE
			p.set_anchors_preset(Control.PRESET_FULL_RECT)
			add_child(p)
			_edit_outline = p
			_edit_outline_sb = sb   ## 留着，供 set_edit_hidden() 改描边颜色（隐藏=红，可拖=黄）
		_edit_outline.visible = true
	elif _edit_outline != null and is_instance_valid(_edit_outline):
		_edit_outline.visible = false


func _gui_input(event: InputEvent) -> void:
	## ★布局编辑模式：不响应任何输入（拖动统一由 TouchControls 处理）。
	if _layout_edit:
		return
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
