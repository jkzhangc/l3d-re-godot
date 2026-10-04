extends CanvasLayer

## ── 架构定位 ──
## 系统：存档 ｜ 层：表现（CanvasLayer，**代码构建、无 tscn**；由存档点节点打开）
## 联机：不涉及（存档点本身在联机会话里被禁用）
## 职责：存档点的功能菜单 —— ① 存档（转交槽位菜单）② 选择难度（立即生效）。
##       「放弃」按用户要求**不做**（= 重选战役/难度/角色）。
## 依赖：SaveManager、save_slot_menu、Global（字体/音效/selected_difficulty）
##
## 暂停策略：打开时暂停游戏（存档点交互期间不该被丧尸打断），关闭时恢复。
##
## ★2026-10-04 版式重做（用户实机反馈 + 原作视频参考）：窗口改用 `art/System/Window *`
##   （与角色选择 / 安全屋台词同一套皮肤），字号 24 → 36，窗口置于左上角（原作同款），
##   光标套白框。旧版是纯色块 + 24 号字，用户报「界面有点小」。

signal closed

const SAVE_MANAGER := preload("res://script/save_manager.gd")
const SLOT_MENU := preload("res://script/ui/save_slot_menu.gd")

# ── 窗口皮肤（与角色选择 / 台词窗口同款）──
const WINDOW_BG_PATH := "res://art/System/Window background color.png"
const WINDOW_FRAME_PATH := "res://art/System/Window frame.png"

enum State { MAIN, DIFFICULTY }

const MAIN_ITEMS: Array[String] = ["存档", "选择难度"]
const DIFFICULTY_NAMES: Array[String] = ["简单难度", "普通难度", "困难难度", "专家难度"]

## 存档点全局坐标 —— 随存档写入，读档时玩家落回存档点。
var save_position: Variant = null
var pause_game: bool = true

# ── 版式（像素字体铁律：字号只能是 12 的整倍）──
const FONT_ITEM: int = 36
const FONT_HINT: int = 24
const MARGIN: float = 32.0     ## 窗口距屏幕左上角
const WIN_W: float = 560.0
const LIST_TOP: float = 28.0
const ITEM_LEFT: float = 56.0
const ITEM_H: float = 64.0
const ITEM_GAP: float = 8.0
const FOOT_H: float = 56.0

var _state: int = State.MAIN
var _cursor: int = 0
var _items: Array = []
var _labels: Array[Label] = []
var _bg: TextureRect = null
var _frame: NinePatchRect = null
var _cursor_box: Panel = null
var _hint: Label = null
var _slot_menu: Node = null
var _busy: bool = false


## 层级：**必须低于触摸层的 `menu_layer`(110)** —— 手机端触摸层要压在菜单之上，
## 玩家才有「摇杆 + 确定 + 取消」可按（2026-10-04 用户手机实测：原来取 149，
## 把整套虚拟按键盖住、摇杆也点不动）。高于结算页(100)/暂停菜单(100) 即可。
const LAYER: int = 105


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	if pause_game and get_tree() != null:
		get_tree().paused = true
	_push_touch_menu_mode()
	_build_frame()
	_show_state(State.MAIN)


func _exit_tree() -> void:
	if pause_game and get_tree() != null:
		get_tree().paused = false
	_pop_touch_menu_mode()


## ★手机端：让触摸层切到「菜单按钮模式」（只留摇杆 + 确定 + 取消）并抬到本层之上。
## 地图场景里 `_menu_mode` 恒为 false（判定靠 `GameInit`），所以必须由叠加层自己登记。
func _push_touch_menu_mode() -> void:
	var tc: Node = _touch_layer()
	if tc != null and tc.has_method("push_menu_overlay"):
		tc.call("push_menu_overlay", self)


func _pop_touch_menu_mode() -> void:
	var tc: Node = _touch_layer()
	if tc != null and tc.has_method("pop_menu_overlay"):
		tc.call("pop_menu_overlay", self)


func _touch_layer() -> Node:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("touch_controls"):
		return g.call("touch_controls")
	return null


# ═══════════════════════════════════════
# 框架窗口
# ═══════════════════════════════════════

func _build_frame() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	## 窗口底色 + 九宫边框（尺寸在 _layout 里按条目数决定）。
	## ★「加底色 / 套边框」与「新建节点」分离（项目铁律：样式不能写在新建分支里）。
	_bg = TextureRect.new()
	_bg.texture = load(WINDOW_BG_PATH) as Texture2D
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_frame = NinePatchRect.new()
	_frame.texture = load(WINDOW_FRAME_PATH) as Texture2D
	_frame.patch_margin_left = 20
	_frame.patch_margin_top = 20
	_frame.patch_margin_right = 20
	_frame.patch_margin_bottom = 20
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_frame)

	_cursor_box = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.08)
	sb.border_color = Color(1, 1, 1, 0.95)
	sb.set_border_width_all(2)
	sb.corner_radius_top_left = 3
	sb.corner_radius_top_right = 3
	sb.corner_radius_bottom_left = 3
	sb.corner_radius_bottom_right = 3
	_cursor_box.add_theme_stylebox_override("panel", sb)
	_cursor_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cursor_box)

	_hint = _make_label("", FONT_HINT)
	_hint.modulate = Color(0.88, 0.90, 0.84)
	add_child(_hint)


func _show_state(s: int) -> void:
	_state = s
	_cursor = 0
	match s:
		State.MAIN:
			_items = MAIN_ITEMS.duplicate()
			_hint.text = "方向键选择 · 确定 · 取消=离开"
		State.DIFFICULTY:
			_items = DIFFICULTY_NAMES.duplicate()
			_hint.text = "改动立即生效（影响后续刷怪与敌人强度）"
	_layout()


func _layout() -> void:
	var n: int = _items.size()
	var win_h: float = LIST_TOP + n * (ITEM_H + ITEM_GAP) + FOOT_H
	var pos := Vector2(MARGIN, MARGIN)

	if _bg != null:
		_bg.position = pos
		_bg.size = Vector2(WIN_W, win_h)
	if _frame != null:
		_frame.position = pos
		_frame.size = Vector2(WIN_W, win_h)

	for l: Label in _labels:
		if is_instance_valid(l):
			l.queue_free()
	_labels.clear()

	for i: int in range(n):
		var l := _make_label(_items[i], FONT_ITEM)
		l.modulate = Color(0.97, 0.97, 0.92)
		l.position = pos + Vector2(ITEM_LEFT, LIST_TOP + i * (ITEM_H + ITEM_GAP))
		l.size = Vector2(WIN_W - ITEM_LEFT - 32.0, ITEM_H)
		add_child(l)
		_labels.append(l)

	_hint.position = pos + Vector2(ITEM_LEFT, win_h - FOOT_H + 12.0)
	_hint.size = Vector2(WIN_W - ITEM_LEFT - 32.0, 32)

	_refresh_cursor()


func _refresh_cursor() -> void:
	if _cursor >= _labels.size() or _cursor_box == null:
		return
	var l: Label = _labels[_cursor]
	_cursor_box.position = l.position + Vector2(-16.0, -6.0)
	_cursor_box.size = Vector2(WIN_W - ITEM_LEFT - 32.0 + 32.0, ITEM_H + 12.0)


# ═══════════════════════════════════════
# 输入
# ═══════════════════════════════════════

func _input(event: InputEvent) -> void:
	if _busy or _slot_menu != null:
		return
	if event.is_action_pressed("取消键"):
		get_viewport().set_input_as_handled()
		if _state == State.DIFFICULTY:
			Global.play_ui_sfx("cancel")
			_show_state(State.MAIN)
		else:
			_close()
		return
	if event.is_action_pressed("确定键"):
		get_viewport().set_input_as_handled()
		Global.play_ui_sfx("confirm")
		_confirm()
		return

	var n: int = _items.size()
	if n <= 0:
		return
	if event.is_action_pressed("上"):
		_cursor = (_cursor - 1 + n) % n
		Global.play_ui_sfx("cursor")
		_refresh_cursor()
	elif event.is_action_pressed("下"):
		_cursor = (_cursor + 1) % n
		Global.play_ui_sfx("cursor")
		_refresh_cursor()


func _confirm() -> void:
	if _state == State.MAIN:
		match _cursor:
			0:
				_open_slot_menu()
			1:
				_show_state(State.DIFFICULTY)
	else:
		## 难度：立即生效（Global.selected_difficulty 被难度倍率实时读取）
		Global.selected_difficulty = _cursor
		print("[存档点] 难度改为: %s" % DIFFICULTY_NAMES[_cursor])
		_toast_and_close("难度已改为 %s" % DIFFICULTY_NAMES[_cursor])


# ═══════════════════════════════════════
# 存档槽位
# ═══════════════════════════════════════

func _open_slot_menu() -> void:
	_slot_menu = SLOT_MENU.new()
	_slot_menu.setup(SLOT_MENU.Mode.SAVE, false)   ## 本层已暂停，槽位菜单不必再暂停
	_slot_menu.connect("chosen", _on_slot_chosen)
	_slot_menu.connect("closed", _on_slot_closed)
	add_child(_slot_menu)


func _on_slot_closed() -> void:
	_slot_menu = null


func _on_slot_chosen(idx: int) -> void:
	_slot_menu = null
	var ok: bool = SAVE_MANAGER.save_to_slot(idx, save_position)
	if not ok:
		_toast_and_close("保存失败（无法写入文件）")
		return
	_toast_and_close("已保存到 档案 %d" % (idx + 1))


# ═══════════════════════════════════════
# 提示与关闭
# ═══════════════════════════════════════

func _toast_and_close(text: String) -> void:
	_busy = true
	if _bg != null:
		_bg.visible = false
	if _frame != null:
		_frame.visible = false
	for l: Label in _labels:
		if is_instance_valid(l):
			l.visible = false
	_hint.visible = false
	_cursor_box.visible = false

	var toast := _make_label(text, FONT_ITEM)
	toast.modulate = Color(1, 1, 1)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var vp: Vector2 = get_viewport().get_visible_rect().size
	toast.position = Vector2(0, vp.y * 0.5 - 40.0)
	toast.size = Vector2(vp.x, 48)
	add_child(toast)

	var timer := Timer.new()
	timer.wait_time = 1.5
	timer.one_shot = true
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(timer)
	timer.timeout.connect(_close)
	timer.start()


func _close() -> void:
	if pause_game and get_tree() != null:
		get_tree().paused = false
	closed.emit()
	queue_free()


func _make_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", l, size)
		if g.has_method("apply_text_shadow"):
			g.call("apply_text_shadow", l)
	else:
		l.add_theme_font_size_override("font_size", size)
	return l
