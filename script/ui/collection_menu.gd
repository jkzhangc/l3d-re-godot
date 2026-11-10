extends Control

## ── 架构定位 ──
## 系统：收藏馆 ｜ 层：表现（Control，**代码构建、无 tscn**；由标题画面叠加打开）
## 联机：不涉及（纯本地查看）
## 职责：物品收藏馆 + 角色图鉴 + 状态图鉴 —— 分类页签 + 图标网格 + 右侧详情；
##       物品页未获得的条目显示「剪影 + ???」，角色/状态页是资料，恒为可见。
## 依赖：ItemCatalogData（物品总表）、CharacterCatalog / CharacterProfileData（角色）、
##       StatusCatalogData（状态）、Global（字体 / 音效 / collection_ids / 触摸层）
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
## 角色 / 状态的资料表同样用 preload：界面不依赖 global class 缓存，
## 新增数据脚本不必等编辑器重扫就能跑（与 CATALOG 同款）。
const STATUS_CATALOG := preload("res://script/status_catalog_data.gd")
const PROFILE_CATALOG := preload("res://script/character_profile_data.gd")

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
## ★2026-11-10：「角色」「状态」是**资料页**，不参与收藏进度（不是捡到才算的东西）。
## 页签从 5 个变 7 个后，单个页签宽度只剩约 167px —— 所以页签只写短名，
## 每个分类的「已收集 x/y」挪到网格下方的页码行，避免长标签互相挤成一片。
const CHARACTER_GROUP := "角色"
const STATUS_GROUP := "状态"
const GROUP_ORDER: Array[String] = [
	CHARACTER_GROUP, STATUS_GROUP,
	"主武器（远程）", "副武器 / 近战", "治疗品", "辅助品", "投掷物",
]
const GROUP_LABELS := {
	CHARACTER_GROUP: "角色",
	STATUS_GROUP: "状态",
	"主武器（远程）": "主武器",
	"副武器 / 近战": "近战",
	"治疗品": "治疗品",
	"辅助品": "辅助品",
	"投掷物": "投掷物",
}

## 角色页大立绘边长：`portrait_texture()` 裁出来是 96×96，×2 整数放大才是像素锐利。
const PORTRAIT_SIZE: float = 192.0
## 角色页正文行高。物品详情用 32（条目文字少、宽松好看）；角色页要塞下
## 简介 + 反击 + 武器 + 特性 + 技能五块，24px 字号配 30px 行高既不透风也不越界。
const CHAR_LINE_H: float = 30.0

## 详情区配色（与 HUD 状态栏同款语义：正面偏青、负面偏红）。
const COLOR_ACCENT := Color(0.98, 0.84, 0.42)
const COLOR_BODY := Color(0.86, 0.84, 0.78)
const COLOR_MUTED := Color(0.62, 0.60, 0.56)
const COLOR_POSITIVE := Color(0.62, 0.86, 1.0)
const COLOR_NEGATIVE := Color(1.0, 0.55, 0.5)

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

## 角色页数据（懒加载一次；`_char_by_key` 键 = CharacterData.get_character_key()）。
var _characters: Array[CharacterData] = []
var _char_by_key: Dictionary = {}


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
	_groups.clear()
	_entries.clear()
	_sel.clear()
	## 资料页排在物品前面：「收藏馆」打开时先看到角色与状态，再往下才是收集品。
	var chars: Array[Dictionary] = _character_entries()
	if not chars.is_empty():
		_groups.append(CHARACTER_GROUP)
		_entries[CHARACTER_GROUP] = chars
		_sel[CHARACTER_GROUP] = 0
	var statuses: Array[Dictionary] = STATUS_CATALOG.all_entries()
	if not statuses.is_empty():
		## 状态表本身不带 `group` 字段（它的分类写在 `kind` 里），这里补上页签名 ——
		## `_is_unlocked()` 按 group 判定「资料页恒可见」，缺了会全被当成未收集。
		for e: Dictionary in statuses:
			e["group"] = STATUS_GROUP
		_groups.append(STATUS_GROUP)
		_entries[STATUS_GROUP] = statuses
		_sel[STATUS_GROUP] = 0
	for g: String in GROUP_ORDER:
		if g == CHARACTER_GROUP or g == STATUS_GROUP:
			continue
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


## 角色页条目：顺序与角色选择一致（CharacterCatalog 固定顺序）。
func _character_entries() -> Array[Dictionary]:
	_load_characters()
	var out: Array[Dictionary] = []
	for cd: CharacterData in _characters:
		out.append({
			"id": cd.get_character_key(),
			"name": cd.character_name,
			"group": CHARACTER_GROUP,
			"path": cd.resource_path,
		})
	return out


func _load_characters() -> void:
	if not _characters.is_empty():
		return
	_characters = CharacterCatalog.load_available_characters()
	for cd: CharacterData in _characters:
		_char_by_key[cd.get_character_key()] = cd


func _character_for(e: Dictionary) -> CharacterData:
	_load_characters()
	return _char_by_key.get(str(e.get("id", "")), null) as CharacterData


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


## 资料页（角色 / 状态）没有「未获得」这回事：角色本来就能选，状态是要写给玩家看的。
func _is_progress_group(g: String) -> bool:
	return g != CHARACTER_GROUP and g != STATUS_GROUP


func _is_unlocked(e: Dictionary) -> bool:
	if not _is_progress_group(str(e.get("group", ""))):
		return true
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
	var group: String = str(e.get("group", ""))
	if group == CHARACTER_GROUP:
		var cd: CharacterData = _character_for(e)
		return cd.portrait_texture() if cd != null else null
	if group == STATUS_GROUP:
		## 状态没有官方图标素材 → 格子里画「＋/－」符号块（见 _build_cell）。
		return null
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
	## 资料页（角色/状态）的文案长度由数据表决定，极端情况可能顶到窗口下沿；
	## 裁掉比让它画到底部提示行上要好（物品页本来就在这个高度内）。
	_detail_root.clip_contents = true
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
		## ★页签只写短名：7 个页签每个约 167px，带「x/y」会和邻居挤成一团；
		## 分类内的收集进度改到网格下方的页码行显示（见 _refresh_page_label）。
		var short_name: String = str(GROUP_LABELS.get(g, g))
		_tab_labels[i].text = short_name
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
	elif str(e.get("group", "")) == STATUS_GROUP:
		## 状态页没有图标素材：画一块正/负色的符号砖，和 HUD 的红青口径一致。
		cell.add_child(_make_glyph_box(e, Vector2(ICON_W, ICON_H),
			Vector2((CELL_W - ICON_W) * 0.5, 6.0)))
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
	if _is_progress_group(_current_group()):
		var got: int = 0
		for e: Dictionary in _current_entries():
			if _is_unlocked(e):
				got += 1
		_page_label.text = "共 %d 项 · 已收集 %d%s" % [total, got, suffix]
		return
	_page_label.text = "共 %d 项%s" % [total, suffix]


# ═══════════════════════════════════════
# 详情
# ═══════════════════════════════════════

## 详情区分派：角色 / 状态是资料页，走各自的版式；其余仍是物品详情。
func _refresh_detail() -> void:
	if _detail_root == null:
		return
	for old: Node in _detail_root.get_children():
		_detail_root.remove_child(old)
		old.queue_free()
	match _current_group():
		CHARACTER_GROUP:
			_refresh_character_detail()
			return
		STATUS_GROUP:
			_refresh_status_detail()
			return
	_refresh_item_detail()


func _refresh_item_detail() -> void:
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


# ═══════════════════════════════════════
# 详情 · 角色页
# ═══════════════════════════════════════

## 角色页版式：左上大立绘 + 右栏名号/定位/基础值，下面依次是简介、见切反击、
## 可装备武器、特性（被动）与技能（SA / 特技 / 觉醒）。
## 数值与武器全部实时取 `CharacterData`，不手抄 —— .tres 一改这里立刻跟上。
func _refresh_character_detail() -> void:
	var list: Array = _current_entries()
	var idx: int = _current_index()
	if idx < 0 or idx >= list.size():
		return
	var cd: CharacterData = _character_for(list[idx])
	if cd == null:
		return

	var y: float = 0.0
	var portrait: Texture2D = cd.portrait_texture()
	if portrait != null:
		var pic := TextureRect.new()
		pic.texture = portrait
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		## 96px 的头像格 ×2 = 192px：整数倍 + 最近邻采样才不糊。
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.size = Vector2(PORTRAIT_SIZE, PORTRAIT_SIZE)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_detail_root.add_child(pic)
		y = PORTRAIT_SIZE + 8.0

	# ── 右栏：名号 / 定位 / 基础值 ──
	var col_x: float = PORTRAIT_SIZE + 12.0
	var col_w: float = DETAIL_W - col_x
	## 主名用**中文短名**（大雄/胖虎/小夫/静香/安雄）：右栏只有 156px，
	## 日文全名（「ジャイ」）用 36 号必然顶出窗口，「大雄」四个字刚好放得下。
	## 原文名放在下面那行（与安全屋台词同一套短名口径），两边都交代清楚。
	var short_name: String = str(Global.CHARACTER_NAME_SHORT.get(cd.character_name, cd.character_name))
	_put_detail_label("「%s」" % short_name, Vector2(col_x, 0), Vector2(col_w, 44),
		FONT_TITLE, Color(0.98, 0.96, 0.88))

	var profile: Dictionary = PROFILE_CATALOG.profile_for(cd.get_character_key())
	var tagline: String = str(profile.get("tagline", "")).strip_edges()
	## 副标题逐行给：原文名与定位各自成行 —— 拼成「のび太 · 万能型」会在
	## 156px 的窄栏里把「万能型」拆成「万 / 能型」，很难看。
	var subs: Array[String] = []
	if short_name != cd.character_name:
		subs.append(cd.character_name)
	if not tagline.is_empty():
		subs.append(tagline)
	var ty: float = 46.0
	for sub: String in subs:
		for line: String in _wrap_text(sub, col_w, FONT_BODY):
			_put_detail_label(line, Vector2(col_x, ty), Vector2(col_w, 26), FONT_BODY, COLOR_ACCENT)
			ty += 26.0

	var stats: Array[String] = [
		"HP %d" % cd.get_effective_max_hp(),
		"攻击 %d" % cd.get_effective_attack(),
		"防御 %d" % cd.get_effective_defense(),
	]
	if absf(cd.base_speed - 1.0) > 0.001:
		stats.append("移速 ×%.2f" % cd.base_speed)
	var sy: float = maxf(ty + 4.0, 84.0)
	for s: String in stats:
		_put_detail_label(s, Vector2(col_x, sy), Vector2(col_w, 26), FONT_BODY, COLOR_BODY)
		sy += 26.0

	# ── 简介 ──
	var bio: String = str(profile.get("bio", "")).strip_edges()
	if bio.is_empty():
		bio = "（暂无介绍）"
	y = _put_detail_paragraph(bio, COLOR_BODY, y, FONT_BODY, CHAR_LINE_H)

	# ── 见切反击 / 可用武器 / 特性（合成一段，特性为空时整行不出现）──
	y += 2.0
	y = _put_detail_paragraph(_counter_line(cd), COLOR_BODY, y, FONT_BODY, CHAR_LINE_H)
	y += 2.0
	y = _put_detail_paragraph(_weapon_line(cd), COLOR_BODY, y, FONT_BODY, CHAR_LINE_H)
	var trait_text: String = _trait_line(cd)
	if not trait_text.is_empty():
		y += 2.0
		y = _put_detail_paragraph(trait_text, COLOR_POSITIVE, y, FONT_BODY, CHAR_LINE_H)

	# ── 技能（SA / 特技 / 觉醒）──
	for line: String in _skill_lines(cd):
		y += 2.0
		y = _put_detail_paragraph(line, COLOR_ACCENT, y, FONT_BODY, CHAR_LINE_H)


func _counter_line(cd: CharacterData) -> String:
	match String(cd.counter_type):
		"punch":
			return "见切反击：拳打（×2 + 推开）"
		"heavy":
			return "见切反击：强打（×3 + 大推）"
		"issen":
			return "见切反击：一闪（×6 + 超推，50% 秒杀）"
		_:
			return "见切反击：无（仍可免伤）"


## 可装备武器。真判据是 `CharacterData.can_use_weapon()`（白名单 **且** 画过持枪行走图），
## 所以不能只抄 `allowed_*_weapons` —— 安雄两个白名单都是空的，实际只拿得了
## 他画过动作的那几类；反过来，白名单里列了的武器也未必真有图。
## 展示按「类别」归并（二十多把枪逐个列会把详情撑爆），顺序跟随物品总表。
func _weapon_line(cd: CharacterData) -> String:
	var primary: Array[String] = []
	var secondary: Array[String] = []
	for e: Dictionary in CATALOG.collection_entries():
		var group: String = str(e.get("group", ""))
		if group != "主武器（远程）" and group != "副武器 / 近战":
			continue
		var wd: WeaponData = _entry_res(e) as WeaponData
		if wd == null or not cd.can_use_weapon(wd):
			continue
		## ★按武器自身的 slot 归并，不按目录分组：手枪/马格南在收藏馆里算「远程」，
		## 但 `weapon_slot = SECONDARY`，只能进副武器格（`can_use_weapon` 也按 slot 查白名单）。
		var cat: String = _weapon_category(wd)
		var bucket: Array[String] = primary if wd.weapon_slot == WeaponData.WeaponSlot.PRIMARY else secondary
		if cat not in bucket:
			bucket.append(cat)
	var parts: Array[String] = []
	if not primary.is_empty():
		parts.append("主武器 %s" % "·".join(primary))
	if not secondary.is_empty():
		parts.append("副武器 %s" % "·".join(secondary))
	if parts.is_empty():
		return "可装备武器：无"
	return "可装备武器：%s" % " ｜ ".join(parts)


## 武器分类：先按 item_id 前缀（比 weapon_state_name 更贴玩家认知 ——
## mg_01 / at_rifle_01 与步枪共用同一张持枪图，但玩家看到的仍是机枪与反器材枪），
## 没匹配到再按武器状态名归到近战大类。
const WEAPON_ID_PREFIX_ZH: Array[Dictionary] = [
	{"prefix": "at_rifle_", "name": "反器材枪"},
	{"prefix": "launcher_", "name": "榴弹"},
	{"prefix": "magnum_", "name": "马格南"},
	{"prefix": "pistol_", "name": "手枪"},
	{"prefix": "shotgun_", "name": "霰弹枪"},
	{"prefix": "sniper_", "name": "狙击枪"},
	{"prefix": "rocket_", "name": "火箭"},
	{"prefix": "bowgun_", "name": "弩"},
	{"prefix": "rifle_", "name": "步枪"},
	{"prefix": "smg_", "name": "冲锋枪"},
	{"prefix": "mg_", "name": "机枪"},
]

func _weapon_category(wd: WeaponData) -> String:
	for row: Dictionary in WEAPON_ID_PREFIX_ZH:
		if wd.item_id.begins_with(str(row["prefix"])):
			return str(row["name"])
	match wd.weapon_state_name:
		"Knife", "CombatKnife", "Uchigatana":
			return "刀"
		"Bat", "Pipe", "Shovel":
			return "钝器"
		"Sledgehammer", "FireAxe":
			return "重击"
		"Frypan":
			return "平底锅"
		"Knuckles":
			return "拳套"
	return wd.item_name


## 已实装的被动/体质，**合成一段**（每条独立成段会把详情区顶穿）。
## 故意只列真正接进玩法的字段 —— `demolition`（投掷无硬直）目前只有数据、
## 没有结算点，写进图鉴等于骗玩家。
func _trait_line(cd: CharacterData) -> String:
	var parts: Array[String] = []
	if cd.backpack_count >= 2:
		parts.append("双背包（SA 切背包）")
	if cd.nursing:
		parts.append("看护（治疗品全队回血）")
	if cd.spray_plus_one:
		parts.append("スプレー+1（喷雾上限 +1）")
	if cd.commando:
		parts.append("コマンドー（机枪/霰弹/马格南 打完不播收枪动作）")
	if cd.kairiki:
		parts.append("怪力（近战无硬直）")
	if cd.self_blast_immune:
		parts.append("自爆无效（自己的爆炸不伤自己）")
	if parts.is_empty():
		return ""
	return "特性：%s" % "｜".join(parts)


## 技能：SA 技能 / 其他主动技（安雄魂挂在觉醒键上）/ 觉醒，一条一句。
func _skill_lines(cd: CharacterData) -> Array[String]:
	var out: Array[String] = []
	for skill: SkillData in cd.skills:
		if skill == null:
			continue
		var sname: String = skill.skill_name.strip_edges()
		if sname.is_empty() or sname.contains("测试"):
			continue
		var kind: String = "SA" if String(skill.command_trigger).strip_edges() == "SA键" else "特技"
		## 描述里可能直接写了「觉醒键」（数据表是静态文本）：按当前平台换成实际键名，
		## 手机没有这颗键时 _awaken_key_name() 原样返回「觉醒键」，替换等于没发生。
		var desc: String = _resolve_key_hint(skill.description.strip_edges()).replace(
			"觉醒键", _awaken_key_name())
		var split: Dictionary = _split_skill_prefix(desc)
		var cost: String = str(split.get("cost", ""))
		var body: String = str(split.get("body", desc))
		var head: String = "%s·%s%s" % [kind, sname, cost]
		if body.is_empty():
			out.append(head)
		else:
			out.append("%s —— %s" % [head, body])
	if String(cd.awaken_type) == "concentrated_fire":
		out.append("觉醒·集中射击 —— 举枪中按%s：威力 ×1.5，子弹即死（Boss 免疫），每秒 -5 TP。" % _awaken_key_name())
	## 没有觉醒的角色不写「觉醒：无」—— 资料页高度很紧，这句话对角色的卖点没有增量。
	return out


## 技能描述开头的「（のび太 SA，TP10）」是给选人界面看的（那里要立刻知道是谁的技能）。
## 收藏馆里角色名就写在标题上，这段既冗余又长 —— 只把 TP 消耗摘出来挂到技能名后面，
## 剩下的正文照旧。没有这种前缀时原样返回。
func _split_skill_prefix(desc: String) -> Dictionary:
	if not desc.begins_with("（"):
		return {}
	var close: int = desc.find("）")
	if close < 0 or close > 24:
		return {}
	var inner: String = desc.substr(1, close - 1)
	var body: String = desc.substr(close + 1).strip_edges()
	var cost: String = ""
	var at: int = inner.find("TP")
	if at >= 0:
		var digits: String = ""
		for i: int in range(at + 2, inner.length()):
			var ch: String = inner[i]
			if ch < "0" or ch > "9":
				break
			digits += ch
		if not digits.is_empty():
			cost = "（TP%s）" % digits
	return {"cost": cost, "body": body}


func _awaken_key_name() -> String:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("has_key_hint") and bool(g.call("has_key_hint", &"覚醒键")):
		return str(g.call("key_hint", &"覚醒键"))
	return "觉醒键"


# ═══════════════════════════════════════
# 详情 · 状态页
# ═══════════════════════════════════════

## 状态页版式：顶部符号砖 + 名称 + 分类 + 效果 / 获得方式 / 备注。
func _refresh_status_detail() -> void:
	var list: Array = _current_entries()
	var idx: int = _current_index()
	if idx < 0 or idx >= list.size():
		return
	var e: Dictionary = list[idx]
	var debuff: bool = bool(e.get("debuff", false))
	var accent: Color = COLOR_NEGATIVE if debuff else COLOR_POSITIVE

	_detail_root.add_child(_make_glyph_box(e, Vector2(ICON_W, ICON_H),
		Vector2((DETAIL_W - ICON_W) * 0.5, 0)))
	var y: float = ICON_H + 12.0
	_put_detail_label(str(e.get("name", "?")), Vector2(0, y), Vector2(DETAIL_W, 44),
		FONT_TITLE, Color(0.98, 0.96, 0.88))
	y += 48.0
	var hud_text: String = "状态栏显示" if bool(e.get("hud", false)) else "不占状态栏"
	_put_detail_label("%s ｜ %s" % [str(e.get("kind", "")), hud_text],
		Vector2(0, y), Vector2(DETAIL_W, 30), FONT_BODY, accent)
	y += 38.0

	var sep := ColorRect.new()
	sep.color = Color(0.55, 0.50, 0.42, 0.55)
	sep.position = Vector2(0, y)
	sep.size = Vector2(DETAIL_W, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_root.add_child(sep)
	y += 12.0

	y = _put_detail_paragraph("效果：%s" % _resolve_key_hint(str(e.get("effect", ""))), COLOR_BODY, y)
	y += 8.0
	y = _put_detail_paragraph("获得：%s" % _resolve_key_hint(str(e.get("obtain", ""))), COLOR_ACCENT, y)
	var remark: String = _resolve_key_hint(str(e.get("remark", ""))).strip_edges()
	if not remark.is_empty():
		y += 8.0
		y = _put_detail_paragraph("备注：%s" % remark, COLOR_MUTED, y)


## 数据表里的 `{觉醒键}` 占位符 → 当前平台的实际键名。
## 手机触摸层没有这颗键时退化为「觉醒键」三个字，不教玩家按一个不存在的键。
func _resolve_key_hint(text: String) -> String:
	if not text.contains("{觉醒键}"):
		return text
	return text.replace("{觉醒键}", _awaken_key_name())


## 详情区一行文字（不折行；宽度由调用方保证）。
func _put_detail_label(text: String, pos: Vector2, box: Vector2, size: int, color: Color) -> void:
	var lbl := _make_label(text, size)
	lbl.position = pos
	lbl.size = box
	lbl.modulate = color
	_detail_root.add_child(lbl)


## 详情区一段自动折行的文字，返回下一行的起点 y。
func _put_detail_paragraph(text: String, color: Color, y: float,
		size: int = FONT_BODY, line_h: float = LINE_H) -> float:
	for line: String in _wrap_text(text, DETAIL_W - 4.0, size):
		_put_detail_label(line, Vector2(0, y), Vector2(DETAIL_W, line_h), size, color)
		y += line_h
	return y


## 状态页的「符号砖」：没有官方图标素材，就用 + / - / = 配正负面配色（与 HUD 红/青同源）。
## 被动用 `=`：既不是增益也不是负效果，写成 `+` 会让人以为能吃到 buff。
func _make_glyph_box(e: Dictionary, box_size: Vector2, pos: Vector2) -> Control:
	var debuff: bool = bool(e.get("debuff", false))
	var accent: Color = COLOR_NEGATIVE if debuff else COLOR_POSITIVE
	## 被动（毅力）既不是增益也不是负效果 → 用「=」，别和正面状态的「+」混淆。
	var passive: bool = str(e.get("kind", "")) == "被动"
	var box := Panel.new()
	box.position = pos
	box.size = box_size
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(accent.r, accent.g, accent.b, 0.12)
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.65)
	sb.set_border_width_all(1)
	box.add_theme_stylebox_override("panel", sb)
	var mark: String = "=" if passive else ("-" if debuff else "+")
	var glyph := _make_label(mark, FONT_TITLE)
	glyph.position = Vector2.ZERO
	glyph.size = box_size
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.modulate = accent
	box.add_child(glyph)
	return box


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


## 按像素宽折行（像素字体宽度必须实测，不能按字数估）。
## ★2026-11-10：从「逐字折」升级为「ASCII 单词整块 + 行首禁则」——
##   逐字折会把 TP10 / Boss / M82 拦腰截断（「TP1」/「0）」），窄栏里特别难看。
##   `NO_LINE_START` 里的闭合标点不单独起行，宁可让上一行略微超宽一个字。
const NO_LINE_START := "）】》」』〕］｝、，。！？；：,.!?;:%％"

func _wrap_text(text: String, max_w: float, size: int) -> Array[String]:
	var out: Array[String] = []
	var font := _ui_font()
	var current: String = ""
	for chunk: String in _wrap_chunks(text):
		if chunk == "\n":
			out.append(current)
			current = ""
			continue
		if current.is_empty():
			if chunk == " ":
				continue
			current = chunk
			continue
		if font.get_string_size(current + chunk, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
			current += chunk
			continue
		if chunk.length() == 1 and NO_LINE_START.contains(chunk):
			current += chunk
			continue
		out.append(current)
		current = chunk
	if not current.is_empty():
		out.append(current)
	return out


func _ui_font() -> Font:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("get_ui_font"):
		var f: Font = g.call("get_ui_font") as Font
		if f != null:
			return f
	return ThemeDB.fallback_font


## 切块：连续 ASCII 字母/数字（含 + - . / _ ×）算一个整块，其余逐字。
## 这样「TP10」「×1.5」「M82」「スプレー+1」不会被拆到两行。
func _wrap_chunks(text: String) -> Array[String]:
	var out: Array[String] = []
	var i: int = 0
	var n: int = text.length()
	while i < n:
		var ch: String = text[i]
		if ch == "\n":
			out.append("\n")
			i += 1
			continue
		if _is_word_char(ch):
			var start: int = i
			while i < n and _is_word_char(text[i]):
				i += 1
			out.append(text.substr(start, i - start))
			continue
		out.append(ch)
		i += 1
	return out


func _is_word_char(ch: String) -> bool:
	if ch.length() != 1:
		return false
	var c: int = ch.unicode_at(0)
	if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
		return true
	return ch in ["+", "-", ".", "/", "_", "×"]
