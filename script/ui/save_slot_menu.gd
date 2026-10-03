extends CanvasLayer

## ── 架构定位 ──
## 系统：存档 ｜ 层：表现（CanvasLayer，**代码构建、无 tscn**；标题画面 / 存档点共用）
## 联机：不涉及（存档点本身在联机会话里被禁用）
## 职责：存档槽位一览（20 格一屏）—— 保存模式 / 读取模式；每格显示该档的**整支队伍**
##       （名字 + Lv + HP）与队长头像。确定选中、取消返回。
## 依赖：SaveManager（槽位读写）、Global（字体）
##
## 【为什么是全代码构建】字段多、数量随 SLOT_COUNT 变，手写 tscn 得不偿失；
## 与「成就一览」同款做法（`add_child` 叠加、关闭即销毁）。
##
## 方向键在 4×5 网格里移动光标；左右跳 1 格、上下跳 4 格，边缘环绕。

signal chosen(slot_index: int)
signal closed

enum Mode { SAVE, LOAD }

const SAVE_MANAGER := preload("res://script/save_manager.gd")

const COLS: int = 4
const ROWS: int = 5
const PANEL_W: float = 1128.0
const PANEL_H: float = 660.0
const PAD: float = 28.0
const HEAD_H: float = 60.0
const FOOT_H: float = 38.0
const COL_GAP: float = 12.0
const ROW_GAP: float = 10.0
const FONT: int = 12
const PORTRAIT: float = 34.0

var mode: int = Mode.SAVE
## 打开时是否暂停游戏（存档点 = true；标题画面 = false，标题没有战斗可暂停）。
var pause_game: bool = false

var _slot_count: int = 20
var _cursor: int = 0
var _cells: Array[Control] = []      ## 每格的容器（用于摆光标框）
var _cursor_box: Panel = null
var _footer: Label = null
var _overwrite_armed: int = -1       ## 保存模式下「已按过一次确定、等待二次确认」的槽位
var _portrait_cache: Dictionary = {}  ## character_path -> Texture2D


func setup(m: int, pause: bool = false) -> void:
	mode = m
	pause_game = pause


func _ready() -> void:
	layer = 150
	process_mode = Node.PROCESS_MODE_ALWAYS
	_slot_count = SAVE_MANAGER.SLOT_COUNT
	if pause_game and get_tree() != null:
		get_tree().paused = true
	_build()
	_refresh_cursor()


func _exit_tree() -> void:
	## 保险：被直接释放（换场景）时也要解除暂停，否则整棵树永久冻结。
	if pause_game and get_tree() != null:
		get_tree().paused = false


# ═══════════════════════════════════════
# 构建
# ═══════════════════════════════════════

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := ColorRect.new()
	panel.color = Color(0.09, 0.10, 0.09, 0.97)
	panel.size = Vector2(PANEL_W, PANEL_H)
	panel.position = ((get_viewport().get_visible_rect().size - panel.size) * 0.5).floor()
	add_child(panel)

	var title := _make_label("要储存在哪里" if mode == Mode.SAVE else "要读取哪一个存档", 24)
	title.position = Vector2(PAD, 16)
	title.size = Vector2(PANEL_W - PAD * 2.0, 30)
	panel.add_child(title)

	var sep := ColorRect.new()
	sep.color = Color(0.55, 0.52, 0.42, 0.7)
	sep.position = Vector2(PAD, HEAD_H - 10.0)
	sep.size = Vector2(PANEL_W - PAD * 2.0, 1)
	panel.add_child(sep)

	var cell_w: float = (PANEL_W - PAD * 2.0 - COL_GAP * (COLS - 1)) / float(COLS)
	var cell_h: float = (PANEL_H - HEAD_H - FOOT_H - ROW_GAP * (ROWS - 1)) / float(ROWS)

	for i: int in range(_slot_count):
		var col: int = i % COLS
		var row: int = i / COLS
		var cell := Control.new()
		cell.size = Vector2(cell_w, cell_h)
		cell.position = Vector2(
			PAD + col * (cell_w + COL_GAP),
			HEAD_H + row * (cell_h + ROW_GAP)
		)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(cell)
		_build_cell(cell, i)
		_cells.append(cell)

	## 光标框：白色描边（与视频里的选中框一致）
	_cursor_box = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.10)
	sb.border_color = Color(1, 1, 1, 0.95)
	sb.set_border_width_all(2)
	_cursor_box.add_theme_stylebox_override("panel", sb)
	_cursor_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_box.size = Vector2(cell_w, cell_h)
	panel.add_child(_cursor_box)

	_footer = _make_label(_footer_text(), FONT)
	_footer.position = Vector2(PAD, PANEL_H - FOOT_H + 6.0)
	_footer.size = Vector2(PANEL_W - PAD * 2.0, 24)
	_footer.modulate = Color(0.82, 0.80, 0.72)
	panel.add_child(_footer)


func _build_cell(cell: Control, idx: int) -> void:
	var info: Dictionary = SAVE_MANAGER.slot_info(idx)
	var head := _make_label("档案 %d" % (idx + 1), FONT)
	head.position = Vector2(4, 0)
	head.size = Vector2(120, 16)
	head.modulate = Color(0.95, 0.82, 0.42)
	cell.add_child(head)

	if info.is_empty():
		var empty := _make_label("— 空 —", FONT)
		empty.position = Vector2(4, 22)
		empty.size = Vector2(200, 16)
		empty.modulate = Color(0.55, 0.53, 0.48)
		cell.add_child(empty)
		return

	## 队伍全体：每名成员一行「名字 Lv? HP?」
	var members: Array = info.get("members", [])
	var y: float = 20.0
	var max_lines: int = 4
	for k: int in range(mini(members.size(), max_lines)):
		var m: Dictionary = members[k]
		var line := _make_label("%s  Lv%d  HP%d" % [
			str(m.get("name", "?")), int(m.get("level", 1)), int(m.get("hp", 0))
		], FONT)
		line.position = Vector2(4, y)
		line.size = Vector2(cell.size.x - 8.0, 15)
		line.clip_text = true
		line.modulate = Color(0.90, 0.89, 0.84)
		cell.add_child(line)
		y += 15.0
	if members.size() > max_lines:
		var more := _make_label("…等 %d 人" % members.size(), FONT)
		more.position = Vector2(4, y)
		more.size = Vector2(cell.size.x - 8.0, 15)
		more.modulate = Color(0.70, 0.68, 0.62)
		cell.add_child(more)

	## 队长头像（右上角）
	var tex: Texture2D = _portrait_for(str(info.get("leader_path", "")))
	if tex != null:
		var pic := TextureRect.new()
		pic.texture = tex
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.size = Vector2(PORTRAIT, PORTRAIT)
		pic.position = Vector2(cell.size.x - PORTRAIT - 2.0, 0.0)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(pic)


func _portrait_for(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _portrait_cache.has(path):
		return _portrait_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is CharacterData:
			tex = (res as CharacterData).portrait_texture()
	_portrait_cache[path] = tex
	return tex


# ═══════════════════════════════════════
# 交互
# ═══════════════════════════════════════

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		get_viewport().set_input_as_handled()
		_close()
		return
	if event.is_action_pressed("确定键"):
		get_viewport().set_input_as_handled()
		_confirm()
		return

	var moved: bool = false
	if event.is_action_pressed("左"):
		_cursor = _wrap(_cursor, -1)
		moved = true
	elif event.is_action_pressed("右"):
		_cursor = _wrap(_cursor, 1)
		moved = true
	elif event.is_action_pressed("上"):
		_cursor = _wrap(_cursor, -COLS)
		moved = true
	elif event.is_action_pressed("下"):
		_cursor = _wrap(_cursor, COLS)
		moved = true
	if moved:
		Global.play_ui_sfx("cursor")
		## 移动光标即取消「覆盖确认」待定态
		if _overwrite_armed != _cursor:
			_arm_overwrite(-1)
		_refresh_cursor()


func _wrap(idx: int, delta: int) -> int:
	return ((idx + delta) % _slot_count + _slot_count) % _slot_count


func _confirm() -> void:
	if mode == Mode.LOAD and not SAVE_MANAGER.has_slot(_cursor):
		## 空槽不可读取 —— 只提示，不触发读档失败
		Global.play_ui_sfx("cancel")
		if _footer != null:
			_footer.text = "档案 %d 是空槽，无法读取" % (_cursor + 1)
		return
	if mode == Mode.SAVE and SAVE_MANAGER.has_slot(_cursor) and _overwrite_armed != _cursor:
		## 已有内容 → 要求二次确认（防手滑覆盖）
		_arm_overwrite(_cursor)
		Global.play_ui_sfx("cursor")
		return
	Global.play_ui_sfx("confirm")
	chosen.emit(_cursor)
	_close()


func _arm_overwrite(idx: int) -> void:
	_overwrite_armed = idx
	if _footer != null:
		_footer.text = _footer_text()


func _footer_text() -> String:
	if mode == Mode.SAVE and _overwrite_armed >= 0:
		return "★ 档案 %d 已有内容 —— 再按一次确定覆盖（取消返回）" % (_overwrite_armed + 1)
	var action: String = "保存（空槽新建 / 已有需二次确认）" if mode == Mode.SAVE else "读取"
	return "方向键选择 · 确定=%s · 取消=返回" % action


func _refresh_cursor() -> void:
	if _cursor_box == null or _cursor >= _cells.size():
		return
	var c: Control = _cells[_cursor]
	_cursor_box.position = c.position
	_cursor_box.size = c.size


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
