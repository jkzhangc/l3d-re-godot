extends Control

## ── 架构定位 ──
## 系统：游戏模式选择 ｜ 层：表现（Control，代码构建、无 tscn；标题画面叠加打开）
## 联机：不涉及（单人流程专用；联机大厅不走这里）
## 职责：单人「开始游戏」后的第一道选择：标准模式 / 计时竞速 / 限时挑战。
##       选择结果写 `Global.run_mode`，随后进入战役选择。
## 依赖：Global（run_mode / 字体 / 音效 / 触摸层）
##
## 【为什么是叠加层而不是场景】与收藏馆/成就同款：`add_child` 挂在标题画面上，
## 关闭即销毁；不必为两行字单独维护一个 .tscn，也不会打断标题画面的 BGM。
##
## 【操作】↑↓ 选择 · 确定 进入 · 取消/Esc 返回 · 鼠标可直接点选

signal closed

const WINDOW_BG_PATH := "res://art/System/Window background color.png"
const WINDOW_FRAME_PATH := "res://art/System/Window frame.png"
const CAMPAIGN_SCENE := "res://scene/campaign_select.tscn"

const FONT_TITLE: int = 36
const FONT_BODY: int = 24

## 三个模式各占一行（56px）；说明最多 4 行 + 「当前：」一行，留 180px 才不压到底部提示。
const PANEL_SIZE := Vector2(880.0, 560.0)
const PAD: float = 28.0
const ROW_TOP: float = 112.0
const ROW_H: float = 56.0
const LINE_H: float = 32.0

const COLOR_TITLE := Color(0.98, 0.96, 0.88)
const COLOR_ACTIVE := Color(1.0, 0.97, 0.88)
const COLOR_IDLE := Color(0.60, 0.58, 0.54)
const COLOR_DESC := Color(0.86, 0.84, 0.78)
const COLOR_ACCENT := Color(0.98, 0.84, 0.42)

var _cursor: int = 0
var _panel: Control = null
var _item_labels: Array[Label] = []
var _desc_root: Control = null
var _cursor_box: Panel = null
var _hint: Label = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cursor = clampi(Global.run_mode, 0, Global.RUN_MODE_NAMES.size() - 1)
	_push_touch_menu_mode()
	_build()
	_refresh()


func _exit_tree() -> void:
	_pop_touch_menu_mode()


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
# 构建
# ═══════════════════════════════════════

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var vp: Vector2 = get_viewport_rect().size
	var pos: Vector2 = (vp - PANEL_SIZE) * 0.5
	_panel = _build_window(pos, PANEL_SIZE)
	var content_w: float = PANEL_SIZE.x - PAD * 2.0

	var title := _make_label("游 戏 模 式", FONT_TITLE)
	title.position = Vector2(PAD, 16)
	title.size = Vector2(content_w, 44)
	title.modulate = COLOR_TITLE
	_panel.add_child(title)

	var sep := ColorRect.new()
	sep.color = Color(0.55, 0.50, 0.42, 0.7)
	sep.position = Vector2(PAD, 76.0)
	sep.size = Vector2(content_w, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(sep)

	## 光标框：套在当前项上（与收藏馆/存档槽位同款白描边）
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
	_panel.add_child(_cursor_box)

	for i: int in range(Global.RUN_MODE_NAMES.size()):
		var row := Control.new()
		row.position = Vector2(PAD, ROW_TOP + i * ROW_H)
		row.size = Vector2(content_w, ROW_H - 8.0)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_on_row_gui_input.bind(i))
		_panel.add_child(row)

		var lbl := _make_label(Global.RUN_MODE_NAMES[i], FONT_TITLE)
		lbl.position = Vector2(16, 2)
		lbl.size = Vector2(content_w - 32.0, 44)
		row.add_child(lbl)
		_item_labels.append(lbl)

	_desc_root = Control.new()
	_desc_root.position = Vector2(PAD, ROW_TOP + Global.RUN_MODE_NAMES.size() * ROW_H + 16.0)
	_desc_root.size = Vector2(content_w, 180.0)
	_desc_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_desc_root)

	_hint = _make_label(_hint_text(), FONT_BODY)
	_hint.position = Vector2(PAD, PANEL_SIZE.y - 46.0)
	_hint.size = Vector2(content_w, 32)
	_hint.modulate = COLOR_DESC
	_panel.add_child(_hint)


func _hint_text() -> String:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("is_mobile_platform") and bool(g.call("is_mobile_platform")):
		return "点按选择 · %s 返回" % str(g.call("key_hint", &"取消键"))
	return "↑↓ 选择 · Enter 确定 · Esc 返回（鼠标可直接点选）"


func _build_window(pos: Vector2, window_size: Vector2) -> Control:
	var win := Control.new()
	win.position = pos
	win.size = window_size
	win.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(win)

	var bg := TextureRect.new()
	bg.texture = load(WINDOW_BG_PATH) as Texture2D
	bg.size = window_size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(bg)

	var frame := NinePatchRect.new()
	frame.texture = load(WINDOW_FRAME_PATH) as Texture2D
	frame.patch_margin_left = 20
	frame.patch_margin_top = 20
	frame.patch_margin_right = 20
	frame.patch_margin_bottom = 20
	frame.size = window_size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(frame)
	return win


# ═══════════════════════════════════════
# 刷新
# ═══════════════════════════════════════

func _refresh() -> void:
	for i: int in range(_item_labels.size()):
		_item_labels[i].modulate = COLOR_ACTIVE if i == _cursor else COLOR_IDLE
	if _cursor_box != null and _cursor < _item_labels.size():
		_cursor_box.position = Vector2(PAD, ROW_TOP + _cursor * ROW_H) + Vector2(0, -4)
		_cursor_box.size = Vector2(PANEL_SIZE.x - PAD * 2.0, ROW_H)
	_refresh_desc()


func _refresh_desc() -> void:
	if _desc_root == null:
		return
	for old: Node in _desc_root.get_children():
		_desc_root.remove_child(old)
		old.queue_free()
	var text: String = str(Global.RUN_MODE_DESCS[clampi(_cursor, 0, Global.RUN_MODE_DESCS.size() - 1)])
	var y: float = 0.0
	for line: String in _wrap_text(text, PANEL_SIZE.x - PAD * 2.0 - 8.0, FONT_BODY):
		var lbl := _make_label(line, FONT_BODY)
		lbl.position = Vector2(0, y)
		lbl.size = Vector2(PANEL_SIZE.x - PAD * 2.0, LINE_H)
		lbl.modulate = COLOR_DESC
		_desc_root.add_child(lbl)
		y += LINE_H

	## 底部补一句「当前选择」，免得玩家点完不知道进了哪个模式。
	var cur := _make_label("当前：%s" % Global.RUN_MODE_NAMES[
		clampi(_cursor, 0, Global.RUN_MODE_NAMES.size() - 1)], FONT_BODY)
	cur.position = Vector2(0, y + 8.0)
	cur.size = Vector2(PANEL_SIZE.x - PAD * 2.0, 30)
	cur.modulate = COLOR_ACCENT
	_desc_root.add_child(cur)


# ═══════════════════════════════════════
# 输入
# ═══════════════════════════════════════

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		get_viewport().set_input_as_handled()
		Global.play_ui_sfx("cancel")
		_close()
		return
	if event.is_action_pressed("上"):
		get_viewport().set_input_as_handled()
		Global.play_ui_sfx("cursor")
		_cursor = posmod(_cursor - 1, Global.RUN_MODE_NAMES.size())
		_refresh()
		return
	if event.is_action_pressed("下"):
		get_viewport().set_input_as_handled()
		Global.play_ui_sfx("cursor")
		_cursor = posmod(_cursor + 1, Global.RUN_MODE_NAMES.size())
		_refresh()
		return
	if event.is_action_pressed("确定键"):
		get_viewport().set_input_as_handled()
		Global.play_ui_sfx("confirm")
		_confirm()
		return


func _on_row_gui_input(event: InputEvent, idx: int) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if _cursor != idx:
		_cursor = idx
		Global.play_ui_sfx("cursor")
		_refresh()
		return
	Global.play_ui_sfx("confirm")
	_confirm()


func _confirm() -> void:
	Global.run_mode = clampi(_cursor, 0, Global.RUN_MODE_NAMES.size() - 1)
	print("[游戏模式] 选择：%s" % Global.run_mode_name())
	var err: Error = get_tree().change_scene_to_file(CAMPAIGN_SCENE)
	if err != OK:
		printerr("[游戏模式] 进入战役选择失败: %s" % CAMPAIGN_SCENE)


func _close() -> void:
	closed.emit()
	queue_free()


# ═══════════════════════════════════════
# 工具
# ═══════════════════════════════════════

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


## 按像素宽折行（同收藏馆：ASCII 单词整块 + 行首禁则，见 collection_menu._wrap_text 的说明）。
func _wrap_text(text: String, max_w: float, size: int) -> Array[String]:
	var out: Array[String] = []
	var font: Font = null
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("get_ui_font"):
		font = g.call("get_ui_font") as Font
	if font == null:
		font = ThemeDB.fallback_font
	var current: String = ""
	for ch: String in _chunks(text):
		if ch == "\n":
			out.append(current)
			current = ""
			continue
		if current.is_empty():
			if ch == " ":
				continue
			current = ch
			continue
		if font.get_string_size(current + ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
			current += ch
			continue
		out.append(current)
		current = ch
	if not current.is_empty():
		out.append(current)
	return out


func _chunks(text: String) -> Array[String]:
	var out: Array[String] = []
	var i: int = 0
	var n: int = text.length()
	while i < n:
		var ch: String = text[i]
		if ch == "\n":
			out.append("\n")
			i += 1
			continue
		var c: int = ch.unicode_at(0)
		var is_word: bool = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		if is_word:
			var start: int = i
			while i < n:
				var cc: int = text[i].unicode_at(0)
				var still: bool = (cc >= 48 and cc <= 57) or (cc >= 65 and cc <= 90) or (cc >= 97 and cc <= 122)
				if not still:
					break
				i += 1
			out.append(text.substr(start, i - start))
			continue
		out.append(ch)
		i += 1
	return out
