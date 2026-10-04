extends CanvasLayer

## ── 架构定位 ──
## 系统：存档 ｜ 层：表现（CanvasLayer，**代码构建、无 tscn**；标题画面 / 存档点共用）
## 联机：不涉及（存档点本身在联机会话里被禁用）
## 职责：存档槽位一览（20 格，**竖排滚动列表**）—— 保存模式 / 读取模式；每格显示该档的
##       **整支队伍**（名字 + Lv + HP）与队长头像 + 大立绘。
## 依赖：SaveManager（槽位读写）、Global（字体 / 音效 / 窗口皮肤）
##
## 【为什么是全代码构建】字段多、数量随 SLOT_COUNT 变，手写 tscn 得不偿失；
## 与「成就一览」同款做法（`add_child` 叠加、关闭即销毁）。
##
## ★2026-10-04 版式重做（用户实机反馈 + 原作视频参考）：
##   旧版是 4×5 小格子 + 12 号字，用户报「界面有点小」。现按原作 RM2K3 存档画面改为
##   **整行竖排列表**：每行 = 「档案 N」+ 角色名 + `Lv N  HP N` + 右侧大立绘；
##   行与行之间一条细白线；右侧上下箭头表示还能滚动；光标套一个白框（原作同款）。
##   字体统一 24 / 36（像素字体只允许 12 的整倍），窗口改用 `art/System/Window *` 皮肤
##   （与角色选择 / 安全屋台词窗口同一套）。
##
## 方向键：上下移动 1 行；左右整页翻（= 当前可见行数）；边缘环绕；光标始终保持在可视区内。

signal chosen(slot_index: int)
signal closed

enum Mode { SAVE, LOAD }

const SAVE_MANAGER := preload("res://script/save_manager.gd")

# ── 窗口皮肤（与角色选择 / 台词窗口同款）──
const WINDOW_BG_PATH := "res://art/System/Window background color.png"
const WINDOW_FRAME_PATH := "res://art/System/Window frame.png"
const ARROW_UP_PATH := "res://art/System/arrow_up.png"
const ARROW_DOWN_PATH := "res://art/System/arrow_down.png"

# ── 字号（像素字体铁律：只能是 12 的整倍）──
const FONT_TITLE: int = 36
const FONT_ROW: int = 36
const FONT_HINT: int = 24

# ── 版式 ──
const MARGIN: float = 32.0        ## 屏幕四周边距
const PAD: float = 14.0           ## 窗口内边距
const HEADER_H: float = 84.0      ## 标题窗高度
const HEADER_GAP: float = 12.0    ## 标题窗与列表窗之间的缝
const ROW_H: float = 142.0        ## 单行高度（容纳 3 行 36 号字）
const ROW_GAP: float = 6.0        ## 行间距
const VISIBLE_ROWS: int = 5       ## 一屏可见行数（放不下会自动减少）
const ARROW_GUTTER: float = 44.0  ## 右侧滚动箭头占用的通道宽
const PORTRAIT: float = 116.0     ## 立绘边长
const ARROW_W: float = 40.0
const ARROW_H: float = 24.0
const MAX_MEMBER_SLOTS: int = 4   ## 单格最多列出 4 名队员（2 列 × 2 行）

var mode: int = Mode.SAVE
## 打开时是否暂停游戏（存档点 = true；标题画面 = false，标题没有战斗可暂停）。
var pause_game: bool = false

var _slot_count: int = 20
var _cursor: int = 0
var _scroll_top: int = 0
var _visible: int = VISIBLE_ROWS
var _cells: Array[Control] = []      ## 每行的容器（与槽位一一对应，20 个）
var _rows_root: Control = null       ## 滚动容器（整体上下平移）
var _list_clip: Control = null       ## 裁剪框
var _cursor_box: Panel = null
var _hint: Label = null
var _arrow_up: TextureRect = null
var _arrow_down: TextureRect = null
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
	var vp: Vector2 = get_viewport().get_visible_rect().size

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel_w: float = vp.x - MARGIN * 2.0
	var list_top: float = MARGIN + HEADER_H + HEADER_GAP

	## 一屏能放几行（视口更小时自动减少；至少 1 行）
	var hint_y: float = vp.y - 52.0
	var avail: float = hint_y - 16.0 - list_top - PAD * 2.0
	_visible = clampi(int((avail + ROW_GAP) / (ROW_H + ROW_GAP)), 1, 6)
	var list_h: float = _visible * ROW_H + (_visible - 1) * ROW_GAP + PAD * 2.0

	# ── 标题窗（「要储存在哪里」/「要读取哪一个存档」）──
	_build_window(Vector2(MARGIN, MARGIN), Vector2(panel_w, HEADER_H))
	var title := _make_label(_title_text(), FONT_TITLE)
	title.position = Vector2(MARGIN + PAD + 12.0, MARGIN + 20.0)
	title.size = Vector2(panel_w - (PAD + 12.0) * 2.0, 48)
	title.modulate = Color(0.96, 0.96, 0.92)
	add_child(title)

	# ── 列表窗 ──
	_build_window(Vector2(MARGIN, list_top), Vector2(panel_w, list_h))

	var inner_w: float = panel_w - PAD * 2.0
	var row_w: float = inner_w - ARROW_GUTTER

	_list_clip = Control.new()
	_list_clip.position = Vector2(MARGIN + PAD, list_top + PAD)
	_list_clip.size = Vector2(inner_w, list_h - PAD * 2.0)
	_list_clip.clip_contents = true
	_list_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_list_clip)

	_rows_root = Control.new()
	_rows_root.size = _list_clip.size
	_rows_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list_clip.add_child(_rows_root)

	for i: int in range(_slot_count):
		var cell := Control.new()
		cell.size = Vector2(row_w, ROW_H)
		cell.position = Vector2(0.0, i * (ROW_H + ROW_GAP))
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_rows_root.add_child(cell)
		_build_cell(cell, i)
		_cells.append(cell)

	## 光标框：白色描边（与视频里的选中框一致），套在「档案 N」外面 → 必须挂在
	## _rows_root 下，才能随列表一起滚动。
	_cursor_box = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.10)
	sb.border_color = Color(1, 1, 1, 0.95)
	sb.set_border_width_all(2)
	sb.corner_radius_top_left = 3
	sb.corner_radius_top_right = 3
	sb.corner_radius_bottom_left = 3
	sb.corner_radius_bottom_right = 3
	_cursor_box.add_theme_stylebox_override("panel", sb)
	_cursor_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_root.add_child(_cursor_box)

	# ── 右侧滚动箭头（原作：列表右上 ▲ / 右下 ▼）──
	_arrow_up = _make_arrow(ARROW_UP_PATH)
	_arrow_up.position = Vector2(MARGIN + panel_w - PAD - ARROW_W, list_top + PAD + 2.0)
	add_child(_arrow_up)
	_arrow_down = _make_arrow(ARROW_DOWN_PATH)
	_arrow_down.position = Vector2(
		MARGIN + panel_w - PAD - ARROW_W, list_top + list_h - PAD - ARROW_H - 2.0)
	add_child(_arrow_down)

	# ── 底部提示行 ──
	_hint = _make_label(_hint_text(), FONT_HINT)
	_hint.position = Vector2(MARGIN + PAD, hint_y)
	_hint.size = Vector2(panel_w - PAD * 2.0, 32)
	_hint.modulate = Color(0.86, 0.85, 0.78)
	add_child(_hint)

	## 箭头初始态：列表在顶部时「上」是暗的（原作里它表示"还能往上滚"）
	_refresh_arrows()


## 一块 RM 风格窗口：Window background 打底 + Window frame 九宫描边。
## ★必须是**独立的**「加底色 + 套边框」两步，且**不写在"新建节点"分支里** ——
##   这是项目第四次踩「给已有节点套样式写进新建分支→静默失效」的坑后立的铁律。
func _build_window(pos: Vector2, size: Vector2) -> Control:
	var win := Control.new()
	win.position = pos
	win.size = size
	win.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(win)

	var bg := TextureRect.new()
	bg.texture = load(WINDOW_BG_PATH) as Texture2D
	bg.size = size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(bg)

	var frame := NinePatchRect.new()
	frame.texture = load(WINDOW_FRAME_PATH) as Texture2D
	frame.patch_margin_left = 20
	frame.patch_margin_top = 20
	frame.patch_margin_right = 20
	frame.patch_margin_bottom = 20
	frame.size = size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(frame)
	return win


func _build_cell(cell: Control, idx: int) -> void:
	var info: Dictionary = SAVE_MANAGER.slot_info(idx)

	var head := _make_label("档案 %d" % (idx + 1), FONT_ROW)
	head.position = Vector2(16, 6)
	head.size = Vector2(320, 46)
	head.modulate = Color(0.95, 0.92, 0.80)
	cell.add_child(head)
	## 记录「档案 N」标签位置，供光标框对齐（原作把白框套在这一行上）
	cell.set_meta("head_pos", head.position)
	cell.set_meta("head_w", _text_width(head.text, FONT_ROW))

	## 行分隔线（原作列表里每行之间一条细白线）
	var sep := ColorRect.new()
	sep.color = Color(0.78, 0.78, 0.72, 0.35)
	sep.position = Vector2(0.0, cell.size.y - 1.0)
	sep.size = Vector2(cell.size.x, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(sep)

	if info.is_empty():
		var empty := _make_label("— 空 —", FONT_ROW)
		empty.position = Vector2(16, 52)
		empty.size = Vector2(400, 46)
		empty.modulate = Color(0.55, 0.55, 0.50)
		cell.add_child(empty)
		return

	## 队伍全体：每名成员一格「名字 Lv? HP?」—— 2 列 × 2 行 = 一屏看全最多 4 人
	## （★用户 2026-10-03 要求"槽位要显示整支队伍"，2026-10-04 版式重做时保持：
	##   原作每格只画队长，这里按用户要求列整队。）
	## 排版：每行 2 人（列宽 = 可用宽 / 2）；超过 MAX_MEMBER_SLOTS 人时最后一格写「…等 N 人」。
	var members: Array = info.get("members", [])
	var text_w: float = cell.size.x - PORTRAIT - 40.0
	var col_w: float = text_w * 0.5
	for k: int in range(mini(members.size(), MAX_MEMBER_SLOTS)):
		var m: Dictionary = members[k]
		var line := _make_label("%s  Lv%d  HP%d" % [
			str(m.get("name", "?")), int(m.get("level", 1)), int(m.get("hp", 0))
		], FONT_ROW)
		line.position = Vector2(16.0 + (k % 2) * col_w, 52.0 + (k / 2) * 46.0)
		line.size = Vector2(col_w - 12.0, 46)
		line.clip_text = true
		line.modulate = Color(0.68, 0.78, 0.96)
		cell.add_child(line)
	if members.size() > MAX_MEMBER_SLOTS:
		var more := _make_label("…等 %d 人" % members.size(), FONT_HINT)
		more.position = Vector2(16.0 + col_w, 98.0)
		more.size = Vector2(col_w - 12.0, 32)
		more.modulate = Color(0.72, 0.76, 0.86)
		cell.add_child(more)

	## 队长立绘（右侧）
	var tex: Texture2D = _portrait_for(str(info.get("leader_path", "")))
	if tex != null:
		var pic := TextureRect.new()
		pic.texture = tex
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.size = Vector2(PORTRAIT, PORTRAIT)
		pic.position = Vector2(cell.size.x - PORTRAIT - 10.0, (cell.size.y - PORTRAIT) * 0.5)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(pic)


func _make_arrow(path: String) -> TextureRect:
	var tr := TextureRect.new()
	var tex: Texture2D = load(path) as Texture2D
	tr.texture = tex
	tr.size = Vector2(ARROW_W, ARROW_H)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


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


func _title_text() -> String:
	return "要储存在哪里" if mode == Mode.SAVE else "要读取哪一个存档"


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
	if event.is_action_pressed("上"):
		_cursor = _wrap(_cursor, -1)
		moved = true
	elif event.is_action_pressed("下"):
		_cursor = _wrap(_cursor, 1)
		moved = true
	elif event.is_action_pressed("左"):
		_cursor = _wrap(_cursor, -_visible)
		moved = true
	elif event.is_action_pressed("右"):
		_cursor = _wrap(_cursor, _visible)
		moved = true
	if moved:
		Global.play_ui_sfx("cursor")
		## 移动光标即取消「覆盖确认」待定态
		if _overwrite_armed != _cursor:
			_arm_overwrite(-1)
		_ensure_visible()
		_refresh_cursor()


func _wrap(idx: int, delta: int) -> int:
	return ((idx + delta) % _slot_count + _slot_count) % _slot_count


func _confirm() -> void:
	if mode == Mode.LOAD and not SAVE_MANAGER.has_slot(_cursor):
		## 空槽不可读取 —— 只提示，不触发读档失败
		Global.play_ui_sfx("cancel")
		if _hint != null:
			_hint.text = "档案 %d 是空槽，无法读取" % (_cursor + 1)
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
	if _hint != null:
		_hint.text = _hint_text()


func _hint_text() -> String:
	if mode == Mode.SAVE and _overwrite_armed >= 0:
		return "★ 档案 %d 已有内容 —— 再按一次确定覆盖（取消返回）" % (_overwrite_armed + 1)
	var action: String = "保存（空槽新建 / 已有需二次确认）" if mode == Mode.SAVE else "读取"
	return "方向键选择 · 确定=%s · 取消=返回" % action


# ═══════════════════════════════════════
# 光标 / 滚动
# ═══════════════════════════════════════

func _ensure_visible() -> void:
	if _cursor < _scroll_top:
		_scroll_top = _cursor
	elif _cursor >= _scroll_top + _visible:
		_scroll_top = _cursor - _visible + 1
	_scroll_top = clampi(_scroll_top, 0, maxi(0, _slot_count - _visible))
	if _rows_root != null:
		_rows_root.position.y = -_scroll_top * (ROW_H + ROW_GAP)
	_refresh_arrows()


func _refresh_arrows() -> void:
	var more_up: bool = _scroll_top > 0
	var more_down: bool = _scroll_top + _visible < _slot_count
	if _arrow_up != null:
		_arrow_up.modulate = Color(1, 1, 1, 0.95 if more_up else 0.20)
	if _arrow_down != null:
		_arrow_down.modulate = Color(1, 1, 1, 0.95 if more_down else 0.20)


func _refresh_cursor() -> void:
	if _cursor_box == null or _cursor >= _cells.size():
		return
	var c: Control = _cells[_cursor]
	var hp: Vector2 = c.get_meta("head_pos", Vector2(16, 6))
	var hw: float = float(c.get_meta("head_w", 160.0))
	_cursor_box.position = c.position + hp + Vector2(-8.0, -4.0)
	_cursor_box.size = Vector2(hw + 16.0, 54.0)


func _close() -> void:
	if pause_game and get_tree() != null:
		get_tree().paused = false
	closed.emit()
	queue_free()


# ═══════════════════════════════════════
# 工具
# ═══════════════════════════════════════

func _make_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 字体唯一入口（禁硬编码 .ttf / 字号必须是 12 的整倍）
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", l, size)
		if g.has_method("apply_text_shadow"):
			g.call("apply_text_shadow", l)
	else:
		l.add_theme_font_size_override("font_size", size)
	return l


## 实测文本宽度（字号固定 → 与 Global 的界面字体一致）。
## ★铁律：居中/留宽一律按**实测文本宽**，禁用 `Control.size.x` 反推。
func _text_width(text: String, size: int) -> float:
	var g: Node = get_node_or_null("/root/Global")
	var font: Font = null
	if g != null and g.has_method("get_ui_font"):
		font = g.call("get_ui_font") as Font
	if font == null:
		return float(text.length()) * float(size) * 0.5
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
