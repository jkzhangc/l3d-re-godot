extends CanvasLayer

## ── 架构定位 ──
## 系统：存档 ｜ 层：表现（CanvasLayer，**代码构建、无 tscn**；由存档点节点打开）
## 联机：不涉及（存档点本身在联机会话里被禁用）
## 职责：存档点的功能菜单 —— ① 存档（转交槽位菜单）② 选择难度（立即生效）。
##       「放弃」按用户要求**不做**（= 重选战役/难度/角色）。
## 依赖：SaveManager、save_slot_menu、Global（字体/音效/selected_difficulty）
##
## 暂停策略：打开时暂停游戏（存档点交互期间不该被丧尸打断），关闭时恢复。

signal closed

const SAVE_MANAGER := preload("res://script/save_manager.gd")
const SLOT_MENU := preload("res://script/ui/save_slot_menu.gd")

enum State { MAIN, DIFFICULTY }

const MAIN_ITEMS: Array[String] = ["存档", "选择难度"]
const DIFFICULTY_NAMES: Array[String] = ["简单难度", "普通难度", "困难难度", "专家难度"]

## 存档点全局坐标 —— 随存档写入，读档时玩家落回存档点。
var save_position: Variant = null
var pause_game: bool = true

var _state: int = State.MAIN
var _cursor: int = 0
var _items: Array = []
var _labels: Array[Label] = []
var _win: Control = null
var _cursor_box: Panel = null
var _title: Label = null
var _hint: Label = null
var _slot_menu: Node = null
var _busy: bool = false

const WIN_W: float = 420.0
const ITEM_H: float = 46.0
const ITEM_GAP: float = 8.0
const LIST_TOP: float = 66.0
const FOOT_H: float = 40.0


func _ready() -> void:
	layer = 149
	process_mode = Node.PROCESS_MODE_ALWAYS
	if pause_game and get_tree() != null:
		get_tree().paused = true
	_build_frame()
	_show_state(State.MAIN)


func _exit_tree() -> void:
	if pause_game and get_tree() != null:
		get_tree().paused = false


# ═══════════════════════════════════════
# 框架窗口
# ═══════════════════════════════════════

func _build_frame() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	_win = ColorRect.new()
	_win.color = Color(0.09, 0.28, 0.17, 0.98)   ## RM 风格深绿窗口
	_win.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_win)

	_cursor_box = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.08)
	sb.border_color = Color(1, 1, 1, 0.95)
	sb.set_border_width_all(2)
	_cursor_box.add_theme_stylebox_override("panel", sb)
	_cursor_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cursor_box)

	_title = _make_label("", 24)
	_title.modulate = Color(0.98, 0.97, 0.92)
	add_child(_title)

	_hint = _make_label("", 12)
	_hint.modulate = Color(0.82, 0.90, 0.82)
	add_child(_hint)


func _show_state(s: int) -> void:
	_state = s
	_cursor = 0
	match s:
		State.MAIN:
			_items = MAIN_ITEMS.duplicate()
			_title.text = "存档点"
			_hint.text = "方向键选择 · 确定 · 取消=离开"
		State.DIFFICULTY:
			_items = DIFFICULTY_NAMES.duplicate()
			_title.text = "选择难度"
			_hint.text = "改动立即生效（影响后续刷怪与敌人强度）"
	_layout()


func _layout() -> void:
	var n: int = _items.size()
	var win_h: float = LIST_TOP + n * (ITEM_H + ITEM_GAP) + FOOT_H
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var pos: Vector2 = ((vp - Vector2(WIN_W, win_h)) * 0.5).floor()
	_win.size = Vector2(WIN_W, win_h)
	_win.position = pos

	_title.position = pos + Vector2(20, 16)
	_title.size = Vector2(WIN_W - 40, 28)

	for l: Label in _labels:
		if is_instance_valid(l):
			l.queue_free()
	_labels.clear()

	for i: int in range(n):
		var l := _make_label(_items[i], 24)
		l.modulate = Color(0.97, 0.96, 0.90)
		l.position = pos + Vector2(34, LIST_TOP + i * (ITEM_H + ITEM_GAP))
		l.size = Vector2(WIN_W - 60, ITEM_H)
		add_child(l)
		_labels.append(l)

	_hint.position = pos + Vector2(20, win_h - FOOT_H + 8)
	_hint.size = Vector2(WIN_W - 40, 22)

	_refresh_cursor()


func _refresh_cursor() -> void:
	if _cursor >= _labels.size():
		return
	var l: Label = _labels[_cursor]
	_cursor_box.position = l.position + Vector2(-10, 0)
	_cursor_box.size = Vector2(WIN_W - 40, ITEM_H)


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
	if _win != null:
		_win.visible = false
	for l: Label in _labels:
		if is_instance_valid(l):
			l.visible = false
	_title.visible = false
	_hint.visible = false
	_cursor_box.visible = false

	var toast := _make_label(text, 24)
	toast.modulate = Color(1, 1, 1)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var vp: Vector2 = get_viewport().get_visible_rect().size
	toast.position = Vector2(0, vp.y * 0.5 - 40.0)
	toast.size = Vector2(vp.x, 40)
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
	else:
		l.add_theme_font_size_override("font_size", size)
	return l
