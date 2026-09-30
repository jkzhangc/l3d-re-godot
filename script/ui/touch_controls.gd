extends CanvasLayer

## ── 架构定位 ──
## 系统：触摸操作 ｜ 层：表现（CanvasLayer）
## 联机：不涉及（动作由既有 InputMap 承载，权威判定不变）
## 职责：手机端触摸操作层：把屏幕触摸转成既有 InputMap 动作（移动 / 攻击 / 装填 / 物品 / 系统）。
## 依赖：Global.is_mobile_platform()、Global.debug_enabled
##
## 【为什么是一个独立场景】用户要求"触摸按钮做成一个场景，每个按钮是独立节点，方便调整"：
## 全部按钮都在 `scene/ui/touch_controls.tscn` 里，位置 / 尺寸 / 贴图 / 映射动作
## 都能在编辑器里直接改，改完不必动任何脚本。
##
## 【挂载点改了（2026-09-29）】原先挂在每张地图的 `GameInit` 上 → 标题画面（= 主场景）与
## 角色选择 / 难度 / 章节选择这些**非地图场景**根本没有触摸层；而它们全是 RM2K3 光标式
##（Button 数 = 0，只认 `确定键`/`上`/`下`/`取消键`，且这些动作只绑键盘）
## → **手机上卡死在标题画面**。现在由 `Global._setup_touch_controls()` 全局创建一次，
## 本脚本按当前场景自动切「菜单模式 / 关卡模式」。

## 桌面端也显示（调布局用）。导出包（release）里 `debug_enabled` 恒 false，故不会误开。
@export var force_show_on_desktop: bool = false

## 关卡模式层级：在游戏 HUD 之上、黑幕(90)/结算页(100) 之下。
@export var control_layer: int = 80
## 菜单模式层级：**必须高于结算页**（章节总结 / 终章 ED 在 `layer = 100`）。
## ★2026-09-29 手机实测：章节总结页把触摸层整个盖住 → 手机上「按钮消失、确定键也按不了」，
## ED 流程卡死。菜单模式下抬到 110 让触摸层压在结算页之上。
@export var menu_layer: int = 110

## 判定「关卡场景」的标志节点名：每张地图都有 1 个 `GameInit`；其余（标题 / 菜单 /
## 联机大厅 / 结算页）都算菜单。
@export var gameplay_marker: String = "GameInit"

## 当前是否菜单模式（调试与用例读取）。
var _menu_mode: bool = false
var _last_scene: Node = null

## ── 触摸布局（手机端自由拖动按键 / 摇杆位置）2026-09-30 用户需求 ──
## ★基线用 **offset**（相对锚点）而不是 position：offset 在窗口尺寸变化时天然适配，
##   而 `position = anchor×父尺寸 + offset` 会随父尺寸漂移 → 换分辨率后自定义偏移就跑偏。
## `_layout_bases`：元素名 → 基线 offset（tscn 原始值，**只在首帧采一次**）。
var _layout_bases: Dictionary = {}
var _layout_ready: bool = false
var _layout_cache: Array[Control] = []
## 编辑模式：拖动 + 工具条；为 true 时所有元素强制显示、不派发动作、层级钉在 menu_layer。
var _layout_edit: bool = false
var _drag_name: String = ""
var _drag_touch: int = -2
var _drag_start_offset: Vector2 = Vector2.ZERO
var _drag_start_touch: Vector2 = Vector2.ZERO
## 本次触摸是否已越过 `DRAG_THRESHOLD` —— 没越过就在松手时当成"点一下"（切换隐藏）。
var _drag_moved: bool = false
var _edit_bar: Control = null
var _edit_buttons: Array[Dictionary] = []
## 上一次见到的画布尺寸（用于检测转屏 / 分辨率变化后重算自定义偏移）。
var _last_canvas: Vector2 = Vector2.ZERO

## 布局编辑结束（保存 / 恢复默认后）—— 设置页据此刷新「默认 / 自定义」显示。
signal layout_edit_finished(saved: bool)


func _ready() -> void:
	## ★暂停时也必须能操作（2026-09-29 用户实测「手机暂停画面里摇杆与按钮都动不了」）：
	## 触摸按钮改走 `_input()` 之后，整层一旦被 `paused` 停掉就收不到任何事件 ——
	## 而暂停菜单恰恰**只能靠虚拟按键**操作，等于功能死锁。触摸层整层设为 ALWAYS。
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = control_layer
	var g: Node = get_node_or_null("/root/Global")
	var mobile: bool = false
	if g != null and g.has_method("is_mobile_platform"):
		mobile = bool(g.call("is_mobile_platform"))
	var debug_on: bool = g != null and bool(g.get("debug_enabled"))
	visible = mobile or (force_show_on_desktop and debug_on)
	_apply_mode()
	print("[TouchControls] 移动平台=%s 调试=%s → 触摸层 visible=%s（%d 个按钮节点，菜单模式=%s）" % [
		mobile, debug_on, visible, _count_buttons(), _menu_mode])


## 场景切换时重新判定模式。每帧只做一次引用比较，开销可忽略。
##（Global 是 autoload，创建本层时主场景可能还没挂上 → 必须靠这里补一次判定。）
## 层级复查间隔（秒）。递归查找 CanvasLayer 不能每帧做，0.25s 对"菜单开关"这种
## 人眼可感知的事件足够快。
const LAYER_CHECK_INTERVAL: float = 0.25
var _layer_check_accum: float = 0.0

## 「拖动」判定阈值（px）：手指位移超过它算**拖动**（改位置），没超过算**点一下**
##（切换该元素的隐藏 / 显示）。两者共用一次按下，靠阈值区分，不用额外按钮。
const DRAG_THRESHOLD: float = 12.0


func _process(delta: float) -> void:
	## 首帧采集布局基线（此时 tscn 的锚点布局已生效）。
	## ⚠ 必须赶在**任何偏移被应用之前**采 —— 否则基线会带上旧偏移，自定义值越拖越远。
	if not _layout_ready:
		_capture_layout_bases()
		apply_saved_layout()
		apply_saved_hidden()
	## 画布尺寸变了（转屏 / 分辨率变化 / 窗口拉伸）→ 自定义偏移要按**新尺寸**重算。
	## ⚠ 基线（offset）不用重采：offset 是相对锚点的，锚点会自己适配父尺寸。
	var now_canvas: Vector2 = _canvas_size()
	if now_canvas != _last_canvas:
		_last_canvas = now_canvas
		apply_saved_layout()
	var cs: Node = get_tree().current_scene if get_tree() != null else null
	if cs != _last_scene:
		_apply_mode()
	if _layout_edit:
		## 编辑模式：层级钉在 menu_layer，保证工具条压在菜单窗口之上。
		if layer != menu_layer:
			layer = menu_layer
		return
	## ★关卡里暂停菜单 / 安全屋台词窗口的开关**不会**改变 `current_scene`，
	## 所以层级不能只在 `_apply_mode` 里算 —— 这里定期对一次（见 `_effective_layer`）。
	## ⚠ 该查找是**递归**的（菜单可能挂在地图场景内部），不能每帧做 → 降频到 0.25s。
	_layer_check_accum += delta
	if _layer_check_accum >= LAYER_CHECK_INTERVAL:
		_layer_check_accum = 0.0
		var want_layer: int = _effective_layer()
		if layer != want_layer:
			layer = want_layer
	## ★屏幕诊断已撤（2026-09-30 定位完成）：
	## 根因是「运行时改 `content_scale_size` 让输入坐标系与画布脱节」，已回退画布加宽解决。
	## `touch_button` / `touch_joystick` 里的 `print` 诊断保留（各限 40 条）——
	## 以后再遇到"位置对不上"可以直接看 stdout，不必再往屏幕上贴字。


## 是否菜单模式（菜单里只留摇杆 + 确定 + 取消）。
func is_menu_mode() -> bool:
	return _menu_mode


## 当前该用的层级。★2026-09-30 用户实测：**关卡里打开暂停菜单 / 安全屋开头台词时，
## 按键会被整个盖住** —— 因为那时 `current_scene` 仍是地图（有 GameInit），
## 触摸层判定为「关卡模式」留在 80，而菜单窗口是 100。
## 所以关卡模式也要动态看一眼：root 下有没有**可见且层级更高**的 CanvasLayer UI。
## （只遍历 root 的直接子节点，数量很少，每帧开销可忽略。）
func _effective_layer() -> int:
	if _menu_mode:
		return menu_layer
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return control_layer
	## ⚠ 必须**递归**找：暂停菜单 `menu.tscn` 的根虽是 CanvasLayer，但它可能是被挂到
	## 地图场景内部（不是 root 的直接子节点）—— 只扫一层会漏。所以调用方要降频。
	for node: Node in tree.root.find_children("*", "CanvasLayer", true, false):
		if node == self:
			continue
		var cl: CanvasLayer = node
		if cl.visible and cl.layer > control_layer:
			return menu_layer
	return control_layer


## 用「当前场景里有没有 GameInit」区分关卡与菜单，再把模式下发到每个按钮。
## `scene_key_override`：仅用例用 —— 直接指定「当前菜单场景的脚本名」，
## 以便在同一个测试场景里验证菜单场景白名单（见 BtnStart 的 menu_scene_filter）。
func _apply_mode(scene_key_override: String = "") -> void:
	var tree: SceneTree = get_tree()
	var cs: Node = tree.current_scene if tree != null else null
	_last_scene = cs
	## ⚠ `get_node_or_null()` 只吃 NodePath：StringName / String 都得显式转（实测 StringName 直接报 Parse Error）。
	var gameplay: bool = cs != null and cs.get_node_or_null(NodePath(gameplay_marker)) != null
	_menu_mode = not gameplay
	if _layout_edit:
		## 编辑模式忽略菜单/关卡过滤：所有元素都要显示出来才拖得到。
		_show_all_for_edit()
		layer = menu_layer
		return
	## 菜单里压在结算页(100)之上；关卡里平时留在黑幕(90)/结算页之下，
	## 但**只要有更高层的可见 UI（暂停菜单 / 安全屋台词）冒出来就抬上去**（见 _effective_layer）。
	layer = _effective_layer()
	_propagate(self, _menu_mode, scene_key_override if not scene_key_override.is_empty() else _current_scene_key(cs))


## 当前菜单场景的脚本文件名（不含扩展名），如 `character_select_menu`。
## 场景没挂脚本 / 取不到路径时返回空串（= 不匹配任何白名单 → 只显示无过滤的按钮）。
func _current_scene_key(cs: Node) -> String:
	if cs == null or cs.get_script() == null:
		return ""
	var path: String = (cs.get_script() as Script).resource_path
	return path.get_file().get_basename()


func _propagate(node: Node, menu_mode: bool, scene_key: String) -> void:
	for child: Node in node.get_children():
		if child.has_method("set_menu_mode"):
			child.call("set_menu_mode", menu_mode, scene_key)
		_propagate(child, menu_mode, scene_key)


func _count_buttons() -> int:
	var n: int = 0
	for node: Node in find_children("*", "Button", true, false):
		if node.get_script() != null:
			n += 1
	return n


# ═══════════════════════════════════════
# 触摸布局（手机端自由拖动按键 / 摇杆位置，2026-09-30 用户需求）
# ═══════════════════════════════════════

## 可拖元素 = 触摸层里带 `set_layout_edit` 的节点（摇杆 + 每个 TouchButton）。
## 用「有没有这个方法」筛选 → 以后往 tscn 里加按钮，不用改这里就能拖。
## ⚠ 结果缓存：拖动时每个事件都会查，遍历全树太浪费（按钮增删才需 `_invalidate_layout_cache`）。
func _layout_elements() -> Array[Control]:
	if not _layout_cache.is_empty():
		return _layout_cache
	var out: Array[Control] = []
	for n: Node in find_children("*", "", true, false):
		if n is Control and n.has_method("set_layout_edit"):
			out.append(n)
	_layout_cache = out
	return out


func _invalidate_layout_cache() -> void:
	_layout_cache.clear()


func _canvas_size() -> Vector2:
	var vp: Viewport = get_viewport()
	return vp.get_visible_rect().size if vp != null else Vector2(1280.0, 960.0)


## 采集基线 offset（tscn 原始值）。**只在首帧调一次** —— 之后 offset 已被自定义值覆盖。
func _capture_layout_bases() -> void:
	_invalidate_layout_cache()
	_layout_bases.clear()
	for e: Control in _layout_elements():
		_layout_bases[String(e.name)] = Vector2(e.offset_left, e.offset_top)
	_layout_ready = true


## 把元素整体平移到目标 offset（**保持 size**）。
## ⚠ 不能只改 `offset_left` —— 那只挪左边界，等于改**宽度**而不是位置。
func _set_element_offset(e: Control, off: Vector2) -> void:
	var sz: Vector2 = e.size
	e.offset_left = off.x
	e.offset_top = off.y
	e.offset_right = off.x + sz.x
	e.offset_bottom = off.y + sz.y


func _element_by_name(n: String) -> Control:
	if n.is_empty():
		return null
	for e: Control in _layout_elements():
		if String(e.name) == n:
			return e
	return null


## 按 `Global.touch_layout` 落位。没有自定义项的元素回到基线。
func apply_saved_layout() -> void:
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("touch_layout_offset"):
		return
	if not _layout_ready:
		_capture_layout_bases()
	var cs: Vector2 = _canvas_size()
	for e: Control in _layout_elements():
		var n: String = String(e.name)
		var base: Vector2 = _layout_bases.get(n, Vector2(e.offset_left, e.offset_top))
		var ratio: Vector2 = g.call("touch_layout_offset", n)
		_set_element_offset(e, base + Vector2(ratio.x * cs.x, ratio.y * cs.y))


func is_layout_edit() -> bool:
	return _layout_edit


## 编辑模式下把全部元素显示出来（忽略菜单/关卡过滤），并切回按钮原始文字。
## ⚠ 被玩家隐藏的元素**也要显示**（否则隐藏过的按钮永远拖不回来）——
##   它只是换成"红色描边 + 半透明"来提示"现在不显示"。
func _show_all_for_edit() -> void:
	var g: Node = get_node_or_null("/root/Global")
	for e: Control in _layout_elements():
		if e.has_method("set_menu_mode"):
			e.call("set_menu_mode", false, "")
		e.visible = true
		if e.has_method("set_edit_hidden") and g != null and g.has_method("touch_hidden_is"):
			e.call("set_edit_hidden", bool(g.call("touch_hidden_is", String(e.name))))


## 把 Global 的隐藏列表应用到各元素（非编辑模式下才会真正隐藏）。
func apply_saved_hidden() -> void:
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("touch_hidden_is"):
		return
	for e: Control in _layout_elements():
		if e.has_method("set_custom_hidden"):
			e.call("set_custom_hidden", bool(g.call("touch_hidden_is", String(e.name))))


## 进入布局编辑模式（设置页调用）。幂等。
func enter_layout_edit() -> bool:
	if _layout_edit:
		return true
	if not _layout_ready:
		_capture_layout_bases()
	## 先把玩家的隐藏设置同步到各元素（编辑态仍显示，只是换成红框 + 半透明）。
	apply_saved_hidden()
	_layout_edit = true
	_show_all_for_edit()
	_set_elements_layout_edit(true)
	_build_edit_bar()
	layer = menu_layer
	print("[TouchControls] 进入触摸布局编辑模式（%d 个可拖元素）" % _layout_elements().size())
	return true


## 退出编辑模式。`saved` 只用于告知设置页；真正落盘在工具条按钮里做。
func exit_layout_edit(saved: bool) -> void:
	if not _layout_edit:
		return
	_end_drag()
	_layout_edit = false
	_set_elements_layout_edit(false)
	if _edit_bar != null and is_instance_valid(_edit_bar):
		_edit_bar.queue_free()
	_edit_bar = null
	_edit_buttons.clear()
	_apply_mode()
	layout_edit_finished.emit(saved)
	print("[TouchControls] 退出触摸布局编辑模式（saved=%s）" % saved)


func _set_elements_layout_edit(on: bool) -> void:
	for e: Control in _layout_elements():
		if e.has_method("set_layout_edit"):
			e.call("set_layout_edit", on)


# ── 工具条（动态创建，不写进 tscn）──

func _build_edit_bar() -> void:
	if _edit_bar != null and is_instance_valid(_edit_bar):
		return
	var bar := Control.new()
	bar.name = "LayoutEditBar"
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.z_index = 100
	add_child(bar)
	_edit_bar = bar

	## ★摆在**左侧中部**（2026-09-30）：
	## 左上角 (40,40)-(450,170) 是 SystemPad（菜单 / 取消 / 丢弃）—— 放那儿会压住它们；
	## 底部中央又会压住右下动作区（BtnSA / BtnPush）。而左侧中部这条带子
	##（x 40~580, y 230~352）在现有布局里是空的：SystemPad 到 y=170、摇杆从 y=610、
	## BtnWalk 从 y=470、物品区在 x≥720。仍留 40px 边距避开圆角 / 刘海。
	var tip := Label.new()
	tip.text = "拖动移动 · 点一下隐藏 / 显示"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	tip.add_theme_font_size_override("font_size", 24)
	tip.add_theme_color_override("font_color", Color(1, 1, 1))
	tip.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	tip.add_theme_constant_override("shadow_offset_x", 2)
	tip.add_theme_constant_override("shadow_offset_y", 2)
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip.size = Vector2(600.0, 32.0)
	tip.position = Vector2(40.0, 230.0)
	bar.add_child(tip)

	_edit_buttons.clear()
	var bw: float = 260.0
	_make_edit_button("恢复默认", Vector2(40.0, 280.0), Vector2(bw, 72.0), "reset")
	_make_edit_button("保存", Vector2(320.0, 280.0), Vector2(bw, 72.0), "save")


## 工具条按钮用 `mouse_filter = IGNORE` + 自己在 `_input` 里判矩形 —— 
## 普通 Button 只吃「第一个触点模拟出来的鼠标事件」，玩家另一根手指还按着按钮时就点不动。
func _make_edit_button(text: String, pos: Vector2, sz: Vector2, action_key: String) -> void:
	var b := Button.new()
	b.name = "EditBtn_" + action_key
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.position = pos
	b.size = sz
	b.add_theme_font_size_override("font_size", 24)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.14, 0.92)
	sb.border_color = Color(1.0, 0.9, 0.3, 0.95)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_color_override("font_color", Color(1, 0.95, 0.75))
	_edit_bar.add_child(b)
	_edit_buttons.append({"key": action_key, "ctrl": b})


func _hit_edit_button(pos: Vector2) -> String:
	for d: Dictionary in _edit_buttons:
		var c: Control = d.get("ctrl")
		if c != null and is_instance_valid(c) and c.get_global_rect().has_point(pos):
			return String(d.get("key"))
	return ""


# ── 输入（仅在编辑模式生效；平时完全不动事件流）──

func _input(event: InputEvent) -> void:
	if not _layout_edit:
		return
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed:
			var hit: String = _hit_edit_button(t.position)
			if not hit.is_empty():
				_on_edit_button(hit)
				return
			if _drag_touch == -2:
				_begin_drag(t.index, t.position)
		elif t.index == _drag_touch:
			_end_drag()
	elif event is InputEventScreenDrag:
		var d: InputEventScreenDrag = event
		if d.index == _drag_touch:
			_update_drag(d.position)
	elif event is InputEventMouseButton:
		## 桌面端调试：鼠标也能拖（导出包没有鼠标，无副作用）。用 index = -1 标记。
		var mb: InputEventMouseButton = event
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			var hit2: String = _hit_edit_button(mb.position)
			if not hit2.is_empty():
				_on_edit_button(hit2)
				return
			if _drag_touch == -2:
				_begin_drag(-1, mb.position)
		elif _drag_touch == -1:
			_end_drag()
	elif event is InputEventMouseMotion and _drag_touch == -1:
		_update_drag((event as InputEventMouseMotion).position)


func _begin_drag(touch_index: int, pos: Vector2) -> void:
	var e: Control = _hit_layout_element(pos)
	if e == null:
		return
	_drag_touch = touch_index
	_drag_name = String(e.name)
	_drag_start_offset = Vector2(e.offset_left, e.offset_top)
	_drag_start_touch = pos
	_drag_moved = false


## 命中可拖元素：**倒序**遍历（后加的节点画在上面，应当优先被拖到）。
func _hit_layout_element(pos: Vector2) -> Control:
	var arr: Array[Control] = _layout_elements()
	for i: int in range(arr.size() - 1, -1, -1):
		var e: Control = arr[i]
		if e.visible and e.get_global_rect().has_point(pos):
			return e
	return null


func _update_drag(pos: Vector2) -> void:
	var e: Control = _element_by_name(_drag_name)
	if e == null:
		return
	var d: Vector2 = pos - _drag_start_touch
	## 越过阈值才真的开始移动 —— 否则"想点一下隐藏"会顺手把按钮挪偏几像素。
	if not _drag_moved and d.length() >= DRAG_THRESHOLD:
		_drag_moved = true
	if _drag_moved:
		_set_element_offset(e, _drag_start_offset + d)


## 松手：位移没超过阈值 → 视为"点一下"，切换该元素的隐藏 / 显示；
## 超过了 → 把当前位置换算成**画布比例**存进 Global。
## ⚠ `persist=false` —— 编辑过程只改内存，点「保存」才落盘（中途退出 / 崩溃不留半成品）。
func _end_drag() -> void:
	if not _drag_name.is_empty():
		if not _drag_moved:
			_toggle_element_hidden(_drag_name)
		else:
			var e: Control = _element_by_name(_drag_name)
			var base: Vector2 = _layout_bases.get(_drag_name, _drag_start_offset)
			var cs: Vector2 = _canvas_size()
			if e != null and cs.x > 1.0 and cs.y > 1.0:
				var off: Vector2 = Vector2(e.offset_left, e.offset_top)
				var ratio := Vector2((off.x - base.x) / cs.x, (off.y - base.y) / cs.y)
				var g: Node = get_node_or_null("/root/Global")
				if g != null and g.has_method("set_touch_layout_offset"):
					g.call("set_touch_layout_offset", _drag_name, ratio, false)
	_drag_name = ""
	_drag_touch = -2
	_drag_moved = false


## 点一下 = 隐藏 / 显示该元素（2026-09-30 用户需求）。
## 编辑态里元素始终可见，只是换成"红色描边 + 半透明"表示它现在是隐藏的。
func _toggle_element_hidden(elem_name: String) -> void:
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("set_touch_hidden"):
		return
	var now_hidden: bool = not bool(g.call("touch_hidden_is", elem_name))
	g.call("set_touch_hidden", elem_name, now_hidden, false)
	var e: Control = _element_by_name(elem_name)
	if e != null and e.has_method("set_edit_hidden"):
		e.call("set_edit_hidden", now_hidden)
	print("[TouchControls] %s → %s" % [elem_name, "隐藏" if now_hidden else "显示"])


func _on_edit_button(key: String) -> void:
	var g: Node = get_node_or_null("/root/Global")
	match key:
		"reset":
			if g != null and g.has_method("reset_touch_layout"):
				g.call("reset_touch_layout")   ## 内部会 save_config
			apply_saved_layout()               ## 立即回到默认位置
			print("[TouchControls] 触摸布局已恢复默认")
			exit_layout_edit(false)
		"save":
			if g != null and g.has_method("save_config"):
				g.call("save_config")
			var n: int = 0
			if g != null:
				var t: Variant = g.get("touch_layout")
				n = t.size() if t is Dictionary else 0
			print("[TouchControls] 触摸布局已保存（%d 项自定义）" % n)
			exit_layout_edit(true)
		_:
			push_warning("[TouchControls] 未知的布局工具条按钮: %s" % key)
