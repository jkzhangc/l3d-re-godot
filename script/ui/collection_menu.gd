extends Control

## ── 架构定位 ──
## 系统：收藏馆 ｜ 层：表现（Control，**代码构建、无 tscn**；由标题画面叠加打开）
## 联机：不涉及（纯本地查看）
## 职责：物品收藏馆 —— 分类页签 + 图标网格 + 右侧详情；未获得的条目显示「剪影 + ???」。
## 依赖：ItemCatalogData（条目总表）、Global（字体 / 音效 / collection_ids / 触摸层）
##
## 【为什么代码构建】条目 52 项、分类数随数据变，手写 tscn 的锚点/字体/Theme 三处都易错；
## 与「成就一览」「存档槽位」同款做法：`add_child` 叠加、关闭即销毁。
##
## 【操作】
##   左右   → 网格内移动；在网格第一行按上 → 移到分类页签
##   页签内 左右 → 切换分类，下 → 回到网格
##   确定   → 网格内无额外动作（详情已实时显示）
##   取消 / Esc → 返回标题
##   鼠标 / 触摸：点页签切分类、点格子看详情、滚轮翻页
##
## ★字号铁律：像素字体只允许 12 的整倍（本文件 24 / 36）。

signal closed

const CATALOG := preload("res://script/item_catalog_data.gd")

# ── 窗口皮肤（与存档 / 成就窗口同一套）──
const WINDOW_BG_PATH := "res://art/System/Window background color.png"
const WINDOW_FRAME_PATH := "res://art/System/Window frame.png"

# ── 字号 ──
const FONT_TITLE: int = 36
const FONT_BODY: int = 24

# ── 版式 ──
const MARGIN: float = 32.0          ## 屏幕四周边距
const PAD: float = 24.0             ## 窗口内边距
const HEADER_H: float = 64.0        ## 标题区高度（分隔线 y）
const TAB_TOP: float = 76.0
const TAB_H: float = 44.0
const BODY_TOP: float = 134.0       ## = TAB_TOP + TAB_H + 14
const HINT_H: float = 56.0          ## 底部提示区高度

const CELL_W: float = 184.0
const CELL_H: float = 148.0
const CELL_GAP: float = 8.0
## 列数按实际网格宽计算（手机横屏画布会加宽到 1706，写死 4 列会留出大片空白）。
var _cols: int = 4
const ICON_W: float = 128.0
const ICON_H: float = 74.0
const DETAIL_W: float = 360.0
const DETAIL_GAP: float = 28.0
const LINE_H: float = 32.0          ## 详情正文行高（24px 字号）

## 分类顺序与页签短名（详情里仍显示完整分类名）。
const GROUP_ORDER: Array[String] = [
	"主武器（远程）", "副武器 / 近战", "治疗品", "辅助品", "投掷物",
]
const GROUP_LABELS := {
	"主武器（远程）": "主武器",
	"副武器 / 近战": "近战",
	"治疗品": "治疗品",
	"辅助品": "辅助品",
	"投掷物": "投掷物",
}

var _groups: Array[String] = []
var _entries: Dictionary = {}       ## group -> Array[Dictionary]
var _sel: Dictionary = {}           ## group -> 选中下标（切分类回来时保留）
var _tab_idx: int = 0
var _focus_tabs: bool = false
var _scroll_row: int = 0
var _rows_visible: int = 1

var _panel: Control = null
var _tab_nodes: Array[Control] = []
var _tab_labels: Array[Label] = []
var _tab_underlines: Array[ColorRect] = []
var _tab_focus_box: Panel = null

var _grid_clip: Control = null
var _rows_root: Control = null
var _cells: Array[Control] = []
var _cursor_box: Panel = null
var _page_label: Label = null

var _detail_root: Control = null
var _hint: Label = null

## .tres 缓存（path -> Resource）。条目只有 52 个，打开时懒加载一次即可。
var _res_cache: Dictionary = {}


func _ready() -> void:
	## ★必须用 set_anchors_**and_offsets**_preset：只设 anchors 会保留原 0 尺寸，
	## 叠出来的 dim 是 0×0（实测标题的 F1 角标没被压暗才发现的）。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 模态：吃掉鼠标/触摸，底下的标题菜单不该再收到点击
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_collect_entries()
	_push_touch_menu_mode()
	_build()
	if not _groups.is_empty():
		_select_tab(0)


func _exit_tree() -> void:
	_pop_touch_menu_mode()


## ★手机端：登记「菜单式叠加层」→ 触摸层切菜单按钮模式并抬到本层之上。
## 标题画面本身就是菜单场景，登记是幂等的（无害）；与 save_slot_menu 同款。
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
# 数据
# ═══════════════════════════════════════

func _collect_entries() -> void:
	for g: String in GROUP_ORDER:
		var list: Array = CATALOG.by_group(g)
		if list.is_empty():
			continue
		_groups.append(g)
		_entries[g] = list
		_sel[g] = 0
	## 未来若出现新分类（例如「消耗品」），追加在末尾，避免条目"消失"。
	for e: Dictionary in CATALOG.collection_entries():
		var g: String = str(e.get("group", ""))
		if g.is_empty() or _entries.has(g):
			continue
		_groups.append(g)
		_entries[g] = CATALOG.by_group(g)
		_sel[g] = 0


func _current_group() -> String:
	if _tab_idx < 0 or _tab_idx >= _groups.size():
		return ""
	return _groups[_tab_idx]


func _current_entries() -> Array:
	if _groups.is_empty():
		return []
	return _entries.get(_current_group(), [])


func _current_index() -> int:
	var g: String = _current_group()
	if g.is_empty():
		return 0
	return int(_sel.get(g, 0))


func _is_unlocked(e: Dictionary) -> bool:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("has_collected"):
		return bool(g.call("has_collected", str(e.get("id", ""))))
	return false


func _entry_res(e: Dictionary) -> Resource:
	var path: String = str(e.get("path", ""))
	if path.is_empty():
		return null
	if not _res_cache.has(path):
		_res_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _res_cache[path]


func _entry_icon(e: Dictionary) -> Texture2D:
	var res: Resource = _entry_res(e)
	if res == null:
		return null
	return res.get("icon") as Texture2D


# ═══════════════════════════════════════
# 构建
# ═══════════════════════════════════════

func _build() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var panel_w: float = vp.x - MARGIN * 2.0
	var panel_h: float = vp.y - MARGIN * 2.0

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	_panel = _build_window(Vector2(MARGIN, MARGIN), Vector2(panel_w, panel_h))
	var content_w: float = panel_w - PAD * 2.0

	# ── 标题 + 总进度 ──
	var title := _make_label("收 藏 馆", FONT_TITLE)
	title.position = Vector2(PAD, 12)
	title.size = Vector2(content_w, 44)
	title.modulate = Color(0.98, 0.96, 0.88)
	_panel.add_child(title)

	var progress := _make_label(_progress_text(), FONT_BODY)
	progress.position = Vector2(PAD, 20)
	progress.size = Vector2(content_w, 32)
	progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	progress.modulate = Color(0.98, 0.84, 0.42)
	_panel.add_child(progress)

	var sep := ColorRect.new()
	sep.color = Color(0.55, 0.50, 0.42, 0.7)
	sep.position = Vector2(PAD, HEADER_H)
	sep.size = Vector2(content_w, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(sep)

	# ── 分类页签 ──
	var tab_w: float = content_w / maxf(1.0, float(_groups.size()))
	for i: int in range(_groups.size()):
		var tab := Control.new()
		tab.position = Vector2(PAD + i * tab_w, TAB_TOP)
		tab.size = Vector2(tab_w, TAB_H)
		tab.mouse_filter = Control.MOUSE_FILTER_STOP
		tab.gui_input.connect(_on_tab_gui_input.bind(i))
		_panel.add_child(tab)
		_tab_nodes.append(tab)

		var lbl := _make_label("", FONT_BODY)
		lbl.position = Vector2(0, 4)
		lbl.size = Vector2(tab_w, 32)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tab.add_child(lbl)
		_tab_labels.append(lbl)

		var line := ColorRect.new()
		line.color = Color(1, 1, 1, 0.0)
		line.position = Vector2(18, TAB_H - 4)
		line.size = Vector2(tab_w - 36, 3)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tab.add_child(line)
		_tab_underlines.append(line)

	## 键盘焦点框（在页签上时显示，提示"左右可切分类"）
	_tab_focus_box = Panel.new()
	var focus_sb := StyleBoxFlat.new()
	focus_sb.bg_color = Color(0, 0, 0, 0)
	focus_sb.border_color = Color(1, 1, 1, 0.95)
	focus_sb.set_border_width_all(2)
	focus_sb.corner_radius_top_left = 3
	focus_sb.corner_radius_top_right = 3
	focus_sb.corner_radius_bottom_left = 3
	focus_sb.corner_radius_bottom_right = 3
	_tab_focus_box.add_theme_stylebox_override("panel", focus_sb)
	_tab_focus_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_focus_box.visible = false
	_panel.add_child(_tab_focus_box)

	# ── 网格区 ──
	var grid_w: float = content_w - DETAIL_W - DETAIL_GAP
	var body_h: float = panel_h - BODY_TOP - HINT_H
	_cols = clampi(int((grid_w + CELL_GAP) / (CELL_W + CELL_GAP)), 1, 8)
	_rows_visible = maxi(1, int((body_h + CELL_GAP) / (CELL_H + CELL_GAP)))
	var grid_h: float = _rows_visible * CELL_H + (_rows_visible - 1) * CELL_GAP

	## 页码放在网格**下方**（放在网格上方会和页签行重叠 —— 第一版实拍就撞了）。
	_page_label = _make_label("", FONT_BODY)
	_page_label.position = Vector2(PAD, BODY_TOP + grid_h + 8.0)
	_page_label.size = Vector2(grid_w, 28)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_page_label.modulate = Color(0.72, 0.70, 0.64)
	_panel.add_child(_page_label)

	_grid_clip = Control.new()
	_grid_clip.position = Vector2(PAD, BODY_TOP)
	_grid_clip.size = Vector2(grid_w, grid_h)
	_grid_clip.clip_contents = true
	_grid_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_grid_clip)

	_rows_root = Control.new()
	_rows_root.size = _grid_clip.size
	_rows_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid_clip.add_child(_rows_root)

	## 选中框：白色描边套在格子上（与存档槽位同款视觉）
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
	_rows_root.add_child(_cursor_box)

	# ── 右侧详情 ──
	var detail_x: float = PAD + grid_w + DETAIL_GAP
	_detail_root = Control.new()
	_detail_root.position = Vector2(detail_x, BODY_TOP)
	_detail_root.size = Vector2(DETAIL_W, body_h)
	_detail_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_detail_root)

	# 详情与网格之间的竖线
	var vline := ColorRect.new()
	vline.color = Color(0.55, 0.50, 0.42, 0.45)
	vline.position = Vector2(detail_x - DETAIL_GAP * 0.5, BODY_TOP)
	vline.size = Vector2(1, body_h)
	vline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(vline)

	# ── 底部提示 ──
	_hint = _make_label(_hint_text(), FONT_BODY)
	_hint.position = Vector2(PAD, panel_h - 46.0)
	_hint.size = Vector2(content_w, 32)
	_hint.modulate = Color(0.86, 0.85, 0.78)
	_panel.add_child(_hint)


## 一块 RM 风格窗口：Window background 打底 + Window frame 九宫描边。
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

func _progress_text() -> String:
	var total: int = CATALOG.collection_entries().size()
	var got: int = 0
	for e: Dictionary in CATALOG.collection_entries():
		if _is_unlocked(e):
			got += 1
	var pct: int = 0 if total == 0 else int(round(got * 100.0 / total))
	return "已收集 %d / %d（%d%%）" % [got, total, pct]


func _hint_text() -> String:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("is_mobile_platform") and bool(g.call("is_mobile_platform")):
		return "摇杆 移动 · ↑ 分类 · %s 返回" % str(g.call("key_hint", &"取消键"))
	return "←→ 移动 · ↑ 分类 · 滚轮 翻页 · Esc 返回（鼠标可直接点选）"


func _select_tab(idx: int) -> void:
	if _groups.is_empty():
		return
	_tab_idx = clampi(idx, 0, _groups.size() - 1)
	_scroll_row = 0
	## 切分类后把记住的选中项夹进新列表范围（各分类条目数不同）。
	var g: String = _current_group()
	_sel[g] = clampi(int(_sel.get(g, 0)), 0, maxi(0, _current_entries().size() - 1))
	_rebuild_grid()
	_refresh_tabs()
	_refresh_cursor()
	_refresh_detail()
	_ensure_visible()


func _refresh_tabs() -> void:
	for i: int in range(_tab_labels.size()):
		if i >= _groups.size():
			continue
		var g: String = _groups[i]
		var list: Array = _entries.get(g, [])
		var got: int = 0
		for e: Dictionary in list:
			if _is_unlocked(e):
				got += 1
		var short_name: String = str(GROUP_LABELS.get(g, g))
		_tab_labels[i].text = "%s %d/%d" % [short_name, got, list.size()]
		var active: bool = (i == _tab_idx)
		_tab_labels[i].modulate = Color(1, 0.97, 0.88) if active else Color(0.60, 0.58, 0.54)
		_tab_underlines[i].color = Color(1, 1, 1, 0.85) if active else Color(1, 1, 1, 0.0)

	var tab_w: float = _tab_nodes[0].size.x if not _tab_nodes.is_empty() else 0.0
	if _tab_focus_box != null:
		_tab_focus_box.visible = _focus_tabs
		if _focus_tabs and _tab_idx < _tab_nodes.size():
			_tab_focus_box.position = _tab_nodes[_tab_idx].position + Vector2(-2, -2)
			_tab_focus_box.size = Vector2(tab_w + 4, TAB_H + 4)


func _rebuild_grid() -> void:
	for old: Node in _cells:
		## 先摘出树再 queue_free：否则旧格子会和新格子同帧叠在一起（白框/图标闪一下）。
		if old.get_parent() != null:
			old.get_parent().remove_child(old)
		old.queue_free()
	_cells.clear()
	if _rows_root == null:
		return
	var list: Array = _current_entries()
	for i: int in range(list.size()):
		var cell := _build_cell(list[i], i)
		_rows_root.add_child(cell)
		_cells.append(cell)
	## 选中框永远最后画
	if _cursor_box != null:
		_rows_root.move_child(_cursor_box, _rows_root.get_child_count() - 1)


func _build_cell(e: Dictionary, idx: int) -> Control:
	var cell := Control.new()
	cell.size = Vector2(CELL_W, CELL_H)
	cell.position = Vector2((idx % _cols) * (CELL_W + CELL_GAP), (idx / _cols) * (CELL_H + CELL_GAP))
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.gui_input.connect(_on_cell_gui_input.bind(idx))

	var got: bool = _is_unlocked(e)

	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.15, 0.18, 0.80)
	bg.size = cell.size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(bg)

	var icon := _entry_icon(e)
	if icon != null:
		var pic := TextureRect.new()
		pic.texture = icon
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.size = Vector2(ICON_W, ICON_H)
		pic.position = Vector2((CELL_W - ICON_W) * 0.5, 6.0)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if not got:
			## 剪影：纯黑乘算（透明度保留 → 只剩形状）
			pic.modulate = Color(0.05, 0.05, 0.07, 1.0)
		cell.add_child(pic)
	else:
		var q := _make_label("?", FONT_TITLE)
		q.position = Vector2(0, 16)
		q.size = Vector2(CELL_W, 44)
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		q.modulate = Color(0.35, 0.35, 0.38)
		cell.add_child(q)

	var name_label := _make_label(
		str(e.get("name", "?")) if got else "???", FONT_BODY)
	name_label.position = Vector2(6, 82)
	name_label.size = Vector2(CELL_W - 12, 56)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	name_label.max_lines_visible = 2
	name_label.clip_text = true
	name_label.modulate = Color(0.96, 0.94, 0.86) if got else Color(0.42, 0.41, 0.44)
	cell.add_child(name_label)
	return cell


func _refresh_cursor() -> void:
	if _cursor_box == null or _cells.is_empty():
		return
	## 焦点在页签上时收起格子选中框，避免两个白框同时出现。
	_cursor_box.visible = not _focus_tabs
	var idx: int = _current_index()
	if idx >= _cells.size():
		idx = 0
	_cursor_box.position = Vector2((idx % _cols) * (CELL_W + CELL_GAP), (idx / _cols) * (CELL_H + CELL_GAP))
	_cursor_box.size = Vector2(CELL_W, CELL_H)


func _ensure_visible() -> void:
	if _rows_root == null:
		return
	var row: int = _current_index() / _cols
	var total_rows: int = int(ceil(float(_current_entries().size()) / float(_cols)))
	if row < _scroll_row:
		_scroll_row = row
	elif row >= _scroll_row + _rows_visible:
		_scroll_row = row - _rows_visible + 1
	_scroll_row = clampi(_scroll_row, 0, maxi(0, total_rows - _rows_visible))
	_rows_root.position.y = -_scroll_row * (CELL_H + CELL_GAP)
	_refresh_page_label()


func _refresh_page_label() -> void:
	if _page_label == null:
		return
	var total: int = _current_entries().size()
	if total <= 0:
		_page_label.text = ""
		return
	var total_rows: int = int(ceil(float(total) / float(_cols)))
	var suffix: String = ""
	if _scroll_row > 0:
		suffix += " ▲"
	if _scroll_row + _rows_visible < total_rows:
		suffix += " ▼"
	_page_label.text = "共 %d 项%s" % [total, suffix]


# ═══════════════════════════════════════
# 详情
# ═══════════════════════════════════════

func _refresh_detail() -> void:
	if _detail_root == null:
		return
	for old: Node in _detail_root.get_children():
		_detail_root.remove_child(old)
		old.queue_free()

	var list: Array = _current_entries()
	var idx: int = _current_index()
	if idx < 0 or idx >= list.size():
		return
	var e: Dictionary = list[idx]
	var res: Resource = _entry_res(e)
	var got: bool = _is_unlocked(e)
	var y: float = 0.0

	# 大图（未获得 = 纯黑剪影）
	var icon := _entry_icon(e)
	if icon != null:
		var pic := TextureRect.new()
		pic.texture = icon
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.size = Vector2(320, 184)
		pic.position = Vector2((DETAIL_W - 320.0) * 0.5, y)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if not got:
			pic.modulate = Color(0.05, 0.05, 0.07, 1.0)
		_detail_root.add_child(pic)
	y += 192.0

	# 名称
	var name_label := _make_label(str(e.get("name", "?")) if got else "???", FONT_TITLE)
	name_label.position = Vector2(0, y)
	name_label.size = Vector2(DETAIL_W, 44)
	name_label.modulate = Color(0.98, 0.96, 0.88) if got else Color(0.45, 0.44, 0.47)
	_detail_root.add_child(name_label)
	y += 48.0

	# 分类 + 状态
	var state_text: String = "已收集" if got else "未收集"
	var group_label := _make_label("%s ｜ %s" % [_current_group(), state_text], FONT_BODY)
	group_label.position = Vector2(0, y)
	group_label.size = Vector2(DETAIL_W, 30)
	group_label.modulate = Color(0.98, 0.84, 0.42) if got else Color(0.52, 0.51, 0.48)
	_detail_root.add_child(group_label)
	y += 38.0

	var sep := ColorRect.new()
	sep.color = Color(0.55, 0.50, 0.42, 0.55)
	sep.position = Vector2(0, y)
	sep.size = Vector2(DETAIL_W, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_root.add_child(sep)
	y += 10.0

	# 说明（未获得时只给一句提示）
	var desc: String = ""
	if got and res != null:
		desc = str(res.get("description"))
	if desc.strip_edges().is_empty():
		desc = "尚未获得 —— 在游戏中捡到它就会记录在这里。" if not got else "（暂无说明）"
	for line: String in _wrap_text(desc, DETAIL_W - 4.0, FONT_BODY):
		var lbl := _make_label(line, FONT_BODY)
		lbl.position = Vector2(0, y)
		lbl.size = Vector2(DETAIL_W, LINE_H)
		lbl.modulate = Color(0.86, 0.84, 0.78) if got else Color(0.56, 0.55, 0.52)
		_detail_root.add_child(lbl)
		y += LINE_H
	y += 8.0

	# 数值（只有已获得才展示）
	if got and res != null:
		for line: String in _stat_lines(_current_group(), res):
			var lbl := _make_label(line, FONT_BODY)
			lbl.position = Vector2(0, y)
			lbl.size = Vector2(DETAIL_W, 30)
			lbl.modulate = Color(0.96, 0.90, 0.70)
			_detail_root.add_child(lbl)
			y += LINE_H


## 按分类挑可读的数值（全部走 `Resource.get()` 鸭子读取，不依赖具体子类）。
func _stat_lines(group: String, res: Resource) -> Array[String]:
	var out: Array[String] = []
	match group:
		"主武器（远程）", "副武器 / 近战":
			var attack: Variant = res.get("attack_power")
			if attack != null:
				out.append("攻击力 %d" % int(attack))
			var speed: Variant = res.get("attack_speed")
			if speed != null and float(speed) != 1.0:
				out.append("攻击速度 ×%.2f" % float(speed))
			var mag: Variant = res.get("magazine_capacity")
			if mag != null and int(mag) > 0:
				out.append("弹匣容量 %d 发" % int(mag))
			var crit: Variant = res.get("critical_rate")
			if crit != null and float(crit) > 0.0:
				out.append("暴击率 %d%%" % int(round(float(crit))))
			var ranged: Variant = res.get("is_ranged")
			if ranged != null:
				out.append("武器类型：%s" % ("远程" if bool(ranged) else "近战"))
		"治疗品":
			var hp: Variant = res.get("hp_restore")
			if hp != null and int(hp) > 0:
				out.append("回复 HP +%d" % int(hp))
			var tp: Variant = res.get("tp_restore")
			if tp != null and int(tp) > 0:
				out.append("回复 TP +%d" % int(tp))
		"辅助品":
			var pain: Variant = res.get("painkiller_seconds")
			if pain != null and float(pain) > 0.0:
				out.append("镇痛：%.0f 秒内伤害归零" % float(pain))
			var adr: Variant = res.get("adrenaline_seconds")
			if adr != null and float(adr) > 0.0:
				out.append("肾上腺素：%.0f 秒内攻击 ×2" % float(adr))
		"投掷物":
			var dmg: Variant = res.get("damage")
			if dmg != null and float(dmg) > 0.0:
				out.append("伤害 %d" % int(round(float(dmg))))
			var radius: Variant = res.get("explosion_radius")
			if radius != null and int(radius) > 0:
				out.append("爆炸范围 %d 格" % int(radius))
			var fire_r: Variant = res.get("fire_radius")
			if fire_r != null and int(fire_r) > 0:
				out.append("燃烧范围 %d 格" % int(fire_r))
			var fire_t: Variant = res.get("fire_duration")
			if fire_t != null and float(fire_t) > 0.0:
				out.append("燃烧持续 %.0f 秒" % float(fire_t))
			var throw_max: Variant = res.get("throw_range_max")
			if throw_max != null and int(throw_max) > 0:
				out.append("最远投掷 %d 格" % int(throw_max))
			var element: Variant = res.get("element")
			if element != null and int(element) > 0:
				var names: Array[String] = ["无", "炎", "雷", "氷", "酸"]
				var ei: int = int(element)
				if ei < names.size():
					out.append("属性：%s" % names[ei])
	return out


# ═══════════════════════════════════════
# 输入
# ═══════════════════════════════════════

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		get_viewport().set_input_as_handled()
		Global.play_ui_sfx("cancel")
		_close()
		return

	# 滚轮翻页（鼠标/触摸板）
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_by(-_rows_visible)
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_by(_rows_visible)
			get_viewport().set_input_as_handled()
			return

	if _groups.is_empty():
		return

	if _focus_tabs:
		if event.is_action_pressed("左"):
			Global.play_ui_sfx("cursor")
			_select_tab(posmod(_tab_idx - 1, _groups.size()))
			return
		if event.is_action_pressed("右"):
			Global.play_ui_sfx("cursor")
			_select_tab(posmod(_tab_idx + 1, _groups.size()))
			return
		if event.is_action_pressed("下") or event.is_action_pressed("确定键"):
			Global.play_ui_sfx("cursor")
			_focus_tabs = false
			_refresh_tabs()
			_refresh_cursor()
			get_viewport().set_input_as_handled()
			return
		return

	var list: Array = _current_entries()
	if list.is_empty():
		return
	var idx: int = _current_index()
	var col: int = idx % _cols
	var moved: bool = false
	if event.is_action_pressed("左"):
		if col > 0:
			idx -= 1
			moved = true
	elif event.is_action_pressed("右"):
		if col < _cols - 1 and idx + 1 < list.size():
			idx += 1
			moved = true
	elif event.is_action_pressed("上"):
		if idx >= _cols:
			idx -= _cols
			moved = true
		else:
			## 第一行再按上 → 焦点移到分类页签
			_focus_tabs = true
			Global.play_ui_sfx("cursor")
			_refresh_tabs()
			_refresh_cursor()
			get_viewport().set_input_as_handled()
			return
	elif event.is_action_pressed("下"):
		if idx + _cols < list.size():
			idx += _cols
			moved = true
	if not moved:
		return

	_sel[_current_group()] = idx
	Global.play_ui_sfx("cursor")
	_ensure_visible()
	_refresh_cursor()
	_refresh_detail()
	get_viewport().set_input_as_handled()


func _scroll_by(rows: int) -> void:
	if _rows_root == null:
		return
	var list: Array = _current_entries()
	if list.is_empty():
		return
	var total_rows: int = int(ceil(float(list.size()) / float(_cols)))
	var max_scroll: int = maxi(0, total_rows - _rows_visible)
	_scroll_row = clampi(_scroll_row + rows, 0, max_scroll)
	_rows_root.position.y = -_scroll_row * (CELL_H + CELL_GAP)
	## 选中项跟着滚到可视区第一行 —— 否则滚一页后白框还留在已裁掉的旧格子上，
	## 屏幕上根本看不到"当前选的是哪一项"。
	var col: int = _current_index() % _cols
	var idx: int = mini(_scroll_row * _cols + col, list.size() - 1)
	_sel[_current_group()] = idx
	_refresh_cursor()
	_refresh_detail()
	_refresh_page_label()


func _on_tab_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Global.play_ui_sfx("cursor")
		_focus_tabs = false
		_select_tab(idx)
		accept_event()


func _on_cell_gui_input(event: InputEvent, idx: int) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if _focus_tabs:
		_focus_tabs = false
		_refresh_tabs()
	_sel[_current_group()] = idx
	Global.play_ui_sfx("cursor")
	_ensure_visible()
	_refresh_cursor()
	_refresh_detail()
	accept_event()


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
	## 字体唯一入口（禁硬编码 .ttf / 字号必须是 12 的整倍）
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", l, size)
		if g.has_method("apply_text_shadow"):
			g.call("apply_text_shadow", l)
	else:
		l.add_theme_font_size_override("font_size", size)
	return l


## 按像素宽逐字折行（与 title_screen 的折行同款；像素字体宽度必须实测，不能按字数估）。
func _wrap_text(text: String, max_w: float, size: int) -> Array[String]:
	var out: Array[String] = []
	var font: Font = null
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("get_ui_font"):
		font = g.call("get_ui_font") as Font
	if font == null:
		font = ThemeDB.fallback_font
	var current: String = ""
	for i: int in text.length():
		var ch: String = text[i]
		if ch == "\n":
			out.append(current)
			current = ""
			continue
		if current.is_empty() or font.get_string_size(current + ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
			current += ch
		else:
			out.append(current)
			current = ch
	if not current.is_empty():
		out.append(current)
	return out
