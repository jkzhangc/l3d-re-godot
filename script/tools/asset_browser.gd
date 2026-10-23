extends Control

## ── 架构定位 ──
## 系统：物品编辑器 / 资源浏览器 ｜ 层：工具（运行时场景，**不是 @tool**）
## 联机：不涉及
## 职责：给 `.tres` 可视化编辑器用的资源选择器：文件夹树 + 缩略图网格 + 大图缩放预览；
##       同一套 UI 支持图像 / 音频 / 场景 / 资源 四种模式。
## 依赖：无 autoload（编辑器场景独立运行）
##
## 【为什么不是 @tool / EditorPlugin】
## Godot 编辑器的 2D 视图不会把鼠标事件交给场景内的 Control（那边是编辑器的选择/拖拽工具），
## 所以「在编辑器里直接点按钮」必须做成 EditorPlugin。这里按用户要求做成**独立场景**：
## 在场景里按 F6 运行，就能得到完整的鼠标交互；保存仍写回 res:// 下的 .tres。

signal picked(path: String)
signal closed

enum Mode { TEXTURE, AUDIO, SCENE, RESOURCE }

const IMG_EXTS: Array[String] = ["png", "jpg", "jpeg", "svg", "webp"]
const AUDIO_EXTS: Array[String] = ["ogg", "wav", "mp3"]
const SCENE_EXTS: Array[String] = ["tscn"]
const RES_EXTS: Array[String] = ["tres"]

const ROOT_DIRS := {
	Mode.TEXTURE: ["res://art"],
	Mode.AUDIO: ["res://sound", "res://music"],
	Mode.SCENE: ["res://anim", "res://scene"],
	Mode.RESOURCE: ["res://object", "res://tres"],
}
const SKIP_DIRS: Array[String] = [
	".godot", "addons", "release", "android", "未使用素材", "未安装的插件",
	".workbuddy", "chm_extract", "tmpcheck_review",
]

# ── Godot 编辑器风格的配色 ──
const C_BG := Color("#1e1e1e")
const C_PANEL := Color("#252526")
const C_PANEL2 := Color("#2d2d30")
const C_BORDER := Color("#3f3f46")
const C_TEXT := Color("#d4d4d4")
const C_MUTED := Color("#9a9a9a")
const C_ACCENT := Color("#4a9eff")
const C_ACCENT_DIM := Color("#264f78")

const THUMB_SIZE: int = 96
const CELL_W: int = 112
const CELL_H: int = 136
const MAX_RESULTS: int = 400

var _mode: int = Mode.TEXTURE
var _selected: String = ""
var _filter_text: String = ""
var _current_dir: String = ""

var _files: Array[String] = []
var _dirs: Array[Dictionary] = []
var _dir_counts: Dictionary = {}
var _visible: Array[String] = []
var _item_by_path: Dictionary = {}     ## dir path -> TreeItem

var _font: SystemFont = null
var _thumb_cache: Dictionary = {}
var _thumb_order: Array[String] = []
var _audio_player: AudioStreamPlayer = null

var _panel: Panel = null
var _tree: Tree = null
var _search: LineEdit = null
var _status: Label = null
var _grid_scroll: ScrollContainer = null
var _grid_root: VBoxContainer = null
var _grid: GridContainer = null
var _list_box: VBoxContainer = null
var _hint_label: Label = null
var _confirm_btn: Button = null
var _play_btn: Button = null

var _preview_title: Label = null
var _preview_clip: Control = null
var _preview_checker: TextureRect = null
var _preview_tex: TextureRect = null
var _preview_placeholder: Label = null
var _preview_info: Label = null
var _zoom_label: Label = null
var _preview_texture: Texture2D = null
var _zoom: float = 1.0

var _cell_borders: Dictionary = {}
var _cell_nodes: Dictionary = {}
var _row_bgs: Dictionary = {}
var _row_nodes: Dictionary = {}


# ═══════════════════════════════════════
# 打开
# ═══════════════════════════════════════

func open(mode: int, current: String = "") -> void:
	_mode = mode
	_selected = current
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_theme()
	_build_ui()
	_scan()
	_build_tree(current)
	_show_preview(_selected)
	_refresh_files()
	_confirm_btn.disabled = _selected.is_empty()
	if not _selected.is_empty() and _visible.has(_selected):
		_select(_selected)


func _build_theme() -> void:
	_font = SystemFont.new()
	_font.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI", "Noto Sans CJK SC", "sans-serif",
	])
	_font.font_weight = 400
	var th := Theme.new()
	th.default_font = _font
	th.default_font_size = 14
	theme = th


# ═══════════════════════════════════════
# 构建 UI
# ═══════════════════════════════════════

func _build_ui() -> void:
	var vp: Vector2 = get_viewport_rect().size

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.66)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var pw: float = clampf(vp.x - 80.0, 900.0, 1240.0)
	var ph: float = clampf(vp.y - 80.0, 620.0, 840.0)
	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel", _panel_sb(C_PANEL, C_BORDER, 6))
	_panel.size = Vector2(pw, ph)
	_panel.position = ((vp - _panel.size) * 0.5).floor()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	# 标题栏
	var title := _label(_mode_title(), 18, C_TEXT)
	title.position = Vector2(18, 14)
	title.size = Vector2(pw - 120, 30)
	_panel.add_child(title)

	var close := _button("✕", false)
	close.position = Vector2(pw - 46, 12)
	close.size = Vector2(32, 30)
	close.pressed.connect(_close)
	_panel.add_child(close)

	var sep := ColorRect.new()
	sep.color = C_BORDER
	sep.position = Vector2(0, 54)
	sep.size = Vector2(pw, 1)
	_panel.add_child(sep)

	var body_h: float = ph - 54.0 - 54.0
	var left_w: float = 240.0
	var right_w: float = 330.0
	var center_w: float = pw - left_w - right_w

	# 左：文件夹树
	_tree = Tree.new()
	_tree.position = Vector2(10, 64)
	_tree.size = Vector2(left_w - 20, body_h - 10)
	_tree.hide_root = false
	_tree.allow_reselect = true
	_tree.item_selected.connect(_on_folder_selected)
	_tree.add_theme_font_size_override("font_size", 13)
	_panel.add_child(_tree)

	# 中：搜索 + 网格
	_search = LineEdit.new()
	_search.position = Vector2(left_w + 10, 64)
	_search.size = Vector2(center_w - 130, 30)
	_search.placeholder_text = "搜索文件名…（清空后按文件夹浏览）"
	_search.clear_button_enabled = true
	_search.text_changed.connect(_on_search_changed)
	_panel.add_child(_search)

	_status = _label("", 12, C_MUTED)
	_status.position = Vector2(left_w + 10 + center_w - 116, 70)
	_status.size = Vector2(106, 20)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_panel.add_child(_status)

	_grid_scroll = ScrollContainer.new()
	_grid_scroll.position = Vector2(left_w + 10, 102)
	_grid_scroll.size = Vector2(center_w - 20, body_h - 48)
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# ★ScrollContainer 里的内容必须自己撑宽，否则 GridContainer 会挤成一列。
	_grid_root = VBoxContainer.new()
	_grid_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_root.add_theme_constant_override("separation", 6)
	_grid_scroll.add_child(_grid_root)
	_panel.add_child(_grid_scroll)

	_hint_label = _label("", 14, C_MUTED)
	_hint_label.position = Vector2(left_w + 30, 120)
	_hint_label.size = Vector2(center_w - 60, 60)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_hint_label)

	# 右：预览
	var rx: float = left_w + center_w
	var vsep := ColorRect.new()
	vsep.color = C_BORDER
	vsep.position = Vector2(rx, 54)
	vsep.size = Vector2(1, body_h + 54)
	_panel.add_child(vsep)

	_preview_title = _label("预览", 14, C_TEXT)
	_preview_title.position = Vector2(rx + 14, 64)
	_preview_title.size = Vector2(right_w - 28, 22)
	_preview_title.clip_text = true
	_panel.add_child(_preview_title)

	_preview_clip = Control.new()
	_preview_clip.position = Vector2(rx + 14, 92)
	_preview_clip.size = Vector2(right_w - 28, 260)
	_preview_clip.clip_contents = true
	_preview_clip.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_clip.gui_input.connect(_on_preview_gui_input)
	_panel.add_child(_preview_clip)

	_preview_checker = TextureRect.new()
	_preview_checker.texture = _checker_texture()
	_preview_checker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_checker.stretch_mode = TextureRect.STRETCH_TILE
	_preview_checker.size = _preview_clip.size
	_preview_checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_clip.add_child(_preview_checker)

	_preview_tex = TextureRect.new()
	_preview_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_clip.add_child(_preview_tex)

	_preview_placeholder = _label("选择文件后在这里放大预览", 13, C_MUTED)
	_preview_placeholder.position = Vector2(10, 112)
	_preview_placeholder.size = Vector2(_preview_clip.size.x - 20, 40)
	_preview_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_placeholder.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_clip.add_child(_preview_placeholder)

	# 缩放行
	var zy: float = _preview_clip.position.y + _preview_clip.size.y + 8.0
	var zoom_out := _button("－", false)
	zoom_out.position = Vector2(rx + 14, zy)
	zoom_out.size = Vector2(34, 28)
	zoom_out.pressed.connect(func(): _zoom_by(0.8))
	_panel.add_child(zoom_out)

	_zoom_label = _label("100%", 12, C_MUTED)
	_zoom_label.position = Vector2(rx + 52, zy + 4)
	_zoom_label.size = Vector2(56, 20)
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_zoom_label)

	var zoom_in := _button("＋", false)
	zoom_in.position = Vector2(rx + 112, zy)
	zoom_in.size = Vector2(34, 28)
	zoom_in.pressed.connect(func(): _zoom_by(1.25))
	_panel.add_child(zoom_in)

	var fit := _button("适应", false)
	fit.position = Vector2(rx + 154, zy)
	fit.size = Vector2(52, 28)
	fit.pressed.connect(func(): _fit_zoom())
	_panel.add_child(fit)

	_play_btn = _button("▶ 试听", false)
	_play_btn.position = Vector2(rx + 214, zy)
	_play_btn.size = Vector2(76, 28)
	_play_btn.visible = false
	_play_btn.pressed.connect(_toggle_play)
	_panel.add_child(_play_btn)

	_preview_info = _label("", 12, C_MUTED)
	_preview_info.position = Vector2(rx + 14, zy + 36)
	_preview_info.size = Vector2(right_w - 28, body_h - (zy - 54.0) - 44.0)
	_preview_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_info.clip_text = true
	_panel.add_child(_preview_info)

	# 底栏
	var fsep := ColorRect.new()
	fsep.color = C_BORDER
	fsep.position = Vector2(0, ph - 54.0)
	fsep.size = Vector2(pw, 1)
	_panel.add_child(fsep)

	var hint := _label("双击文件直接确定 · Esc 取消", 12, C_MUTED)
	hint.position = Vector2(18, ph - 38.0)
	hint.size = Vector2(pw - 260, 24)
	_panel.add_child(hint)

	_confirm_btn = _button(_mode_confirm_text(), true)
	_confirm_btn.position = Vector2(pw - 150, ph - 42.0)
	_confirm_btn.size = Vector2(132, 32)
	_confirm_btn.disabled = true
	_confirm_btn.pressed.connect(_confirm)
	_panel.add_child(_confirm_btn)

	_audio_player = AudioStreamPlayer.new()
	add_child(_audio_player)


# ═══════════════════════════════════════
# 扫描
# ═══════════════════════════════════════

func _exts() -> Array:
	match _mode:
		Mode.AUDIO: return AUDIO_EXTS
		Mode.SCENE: return SCENE_EXTS
		Mode.RESOURCE: return RES_EXTS
	return IMG_EXTS


func _scan() -> void:
	_files.clear()
	_dirs.clear()
	_dir_counts.clear()
	for root: String in ROOT_DIRS.get(_mode, []):
		_walk(root, 0)
	_files.sort()
	_dirs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("path", "")) < str(b.get("path", "")))


## 返回该目录（含子目录）里的匹配文件数。
func _walk(dir_path: String, depth: int) -> int:
	if depth > 12:
		return 0
	var da := DirAccess.open(dir_path)
	if da == null:
		return 0
	var total: int = 0
	da.list_dir_begin()
	var name: String = da.get_next()
	while name != "":
		if name.begins_with("."):
			name = da.get_next()
			continue
		var full := dir_path.path_join(name)
		if da.current_is_dir():
			if name not in SKIP_DIRS:
				total += _walk(full, depth + 1)
		else:
			var ext: String = name.get_extension().to_lower()
			if ext in _exts():
				_files.append(full)
				total += 1
		name = da.get_next()
	da.list_dir_end()
	_dir_counts[dir_path] = total
	_dirs.append({"path": dir_path, "count": total, "depth": depth})
	return total


func _build_tree(current: String) -> void:
	_tree.clear()
	_item_by_path.clear()
	var root_item := _tree.create_item()
	root_item.set_text(0, "全部（%d）" % _files.size())
	root_item.set_metadata(0, "")
	_item_by_path[""] = root_item

	for d: Dictionary in _dirs:
		var p: String = str(d.get("path", ""))
		if p.is_empty():
			continue
		var parent_path: String = p.get_base_dir()
		var parent: TreeItem = _item_by_path.get(parent_path, root_item)
		var it := _tree.create_item(parent)
		it.set_text(0, "%s（%d）" % [p.get_file(), int(d.get("count", 0))])
		it.set_metadata(0, p)
		it.set_tooltip_text(0, p)
		_item_by_path[p] = it

	var target: String = current.get_base_dir() if not current.is_empty() else ""
	if not _item_by_path.has(target):
		target = ""
	if _mode == Mode.TEXTURE and target == "":
		target = str(ROOT_DIRS[Mode.TEXTURE][0])
		if not _item_by_path.has(target):
			target = ""
	_current_dir = target
	var item: TreeItem = _item_by_path.get(target, root_item)
	_tree.set_selected(item, 0)


func _on_folder_selected() -> void:
	var item: TreeItem = _tree.get_selected()
	if item == null:
		return
	_current_dir = str(item.get_metadata(0))
	_refresh_files()


func _on_search_changed(text: String) -> void:
	_filter_text = text.strip_edges().to_lower()
	_refresh_files()


# ═══════════════════════════════════════
# 文件网格 / 列表
# ═══════════════════════════════════════

func _refresh_files() -> void:
	_visible.clear()
	var q: String = _filter_text
	var all_mode: bool = _current_dir.is_empty()
	var capped: bool = false
	if all_mode and q.is_empty() and _mode == Mode.TEXTURE:
		_show_hint("选择左侧文件夹，或在上方输入关键词搜索全部图像。")
		_status.text = "共 %d 个图像" % _files.size()
		return
	for f: String in _files:
		if not all_mode and f.get_base_dir() != _current_dir:
			continue
		if not q.is_empty() and not f.to_lower().contains(q):
			continue
		_visible.append(f)
		if _visible.size() >= MAX_RESULTS:
			capped = true
			break
	_hint_label.visible = false
	_status.text = "显示 %d%s / %d" % [
		_visible.size(), "+" if capped else "", _files.size()]
	if _visible.is_empty():
		_show_hint("这里没有匹配的文件。\n试试子文件夹、清空搜索，或选择左上角「全部」。")
		return
	if _mode == Mode.TEXTURE:
		_rebuild_grid()
	else:
		_rebuild_rows()


func _show_hint(text: String) -> void:
	_clear_grid()
	_hint_label.text = text
	_hint_label.visible = true


func _clear_grid() -> void:
	for c: Node in _grid_root.get_children():
		c.queue_free()
	_cell_borders.clear()
	_cell_nodes.clear()
	_row_bgs.clear()
	_row_nodes.clear()
	_grid = null
	_list_box = null


func _rebuild_grid() -> void:
	_clear_grid()
	var scroll_w: float = _grid_scroll.size.x
	var cols: int = clampi(int((scroll_w - 8.0) / (CELL_W + 8.0)), 2, 10)
	_grid = GridContainer.new()
	_grid.columns = cols
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_root.add_child(_grid)
	_grid_root.custom_minimum_size.x = scroll_w - 12.0

	for path: String in _visible:
		var cell := _make_texture_cell(path)
		_grid.add_child(cell)


func _make_texture_cell(path: String) -> Control:
	var cell := Control.new()
	cell.custom_minimum_size = Vector2(CELL_W, CELL_H)
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.gui_input.connect(_on_item_gui_input.bind(path))

	var bg := ColorRect.new()
	bg.color = C_PANEL2
	bg.size = Vector2(CELL_W, CELL_H)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(bg)

	var checker := TextureRect.new()
	checker.texture = _checker_texture()
	checker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	checker.stretch_mode = TextureRect.STRETCH_TILE
	checker.position = Vector2((CELL_W - THUMB_SIZE) * 0.5, 6)
	checker.size = Vector2(THUMB_SIZE, THUMB_SIZE)
	checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(checker)

	var thumb := TextureRect.new()
	thumb.texture = _thumb(path)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.position = checker.position
	thumb.size = checker.size
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(thumb)

	var name_label := _label(path.get_file(), 12, C_TEXT)
	name_label.position = Vector2(4, CELL_H - 30)
	name_label.size = Vector2(CELL_W - 8, 26)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	name_label.max_lines_visible = 2
	name_label.clip_text = true
	name_label.tooltip_text = path.get_file()
	cell.add_child(name_label)

	var border := Panel.new()
	border.add_theme_stylebox_override("panel", _border_sb(C_ACCENT, 0))
	border.position = Vector2.ZERO
	border.size = Vector2(CELL_W, CELL_H)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	border.visible = path == _selected
	cell.add_child(border)
	_cell_borders[path] = border
	_cell_nodes[path] = cell
	return cell


func _rebuild_rows() -> void:
	_clear_grid()
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 2)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_root.add_child(_list_box)
	_grid_root.custom_minimum_size.x = _grid_scroll.size.x - 12.0

	for path: String in _visible:
		var row := Control.new()
		row.custom_minimum_size = Vector2(0, 40)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_on_item_gui_input.bind(path))

		var bg := ColorRect.new()
		bg.color = C_PANEL2 if path != _selected else C_ACCENT_DIM
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(bg)

		var icon := _label(_mode_icon(), 14, C_MUTED)
		icon.position = Vector2(10, 8)
		icon.size = Vector2(24, 24)
		row.add_child(icon)

		var text := _label(path.replace("res://", ""), 13, C_TEXT)
		text.position = Vector2(38, 9)
		text.size = Vector2(_grid_scroll.size.x - 70, 22)
		text.clip_text = true
		text.tooltip_text = path
		row.add_child(text)

		_list_box.add_child(row)
		_row_bgs[path] = bg
		_row_nodes[path] = row


func _on_item_gui_input(event: InputEvent, path: String) -> void:
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	_select(path)
	if event.double_click:
		_confirm()


func _select(path: String) -> void:
	_selected = path
	_confirm_btn.disabled = path.is_empty()
	for p: String in _cell_borders.keys():
		var b: Panel = _cell_borders[p]
		if is_instance_valid(b):
			b.visible = p == path
	for p: String in _row_bgs.keys():
		var bg: ColorRect = _row_bgs[p]
		if is_instance_valid(bg):
			bg.color = C_ACCENT_DIM if p == path else C_PANEL2
	_show_preview(path)
	## 选中项可能在滚动区外（例如文件夹里第 5 行）：延后一帧等布局完成再滚过去。
	call_deferred("_ensure_visible_path", path)


func _ensure_visible_path(path: String) -> void:
	## 不用 ensure_control_visible：首次布局尚未完成时它会把滚动条推到最底部。
	## 直接按行号算目标偏移，结果稳定。
	var idx: int = _visible.find(path)
	if idx < 0:
		return
	var bar: VScrollBar = _grid_scroll.get_v_scroll_bar()
	var max_scroll: int = maxi(0, int(bar.max_value - bar.page))
	var target: int = 0
	if _mode == Mode.TEXTURE and _grid != null:
		var row: int = idx / maxi(1, _grid.columns)
		target = row * (CELL_H + 8) - 4
	elif _list_box != null:
		target = idx * 42
	_grid_scroll.scroll_vertical = clampi(target, 0, max_scroll)


# ═══════════════════════════════════════
# 预览
# ═══════════════════════════════════════

func _show_preview(path: String) -> void:
	_preview_texture = null
	_preview_tex.texture = null
	_play_btn.visible = false
	_preview_placeholder.visible = true
	_preview_info.text = ""
	if path.is_empty():
		_preview_title.text = "预览"
		_preview_placeholder.text = "选择文件后在这里放大预览"
		_zoom_label.text = "100%"
		return

	_preview_title.text = path.get_file()
	if _mode == Mode.TEXTURE:
		var tex: Texture2D = load(path) as Texture2D
		if tex == null:
			_preview_placeholder.text = "无法加载图像"
			return
		_preview_texture = tex
		_preview_tex.texture = tex
		_preview_placeholder.visible = false
		_fit_zoom()
		_preview_info.text = "%d × %d\n%s" % [tex.get_width(), tex.get_height(), path]
	elif _mode == Mode.AUDIO:
		_preview_placeholder.text = "♪ 音频文件"
		_play_btn.visible = true
		var stream: AudioStream = load(path) as AudioStream
		if stream != null:
			_preview_info.text = "时长 %.1f 秒\n%s" % [stream.get_length(), path]
		else:
			_preview_info.text = path
		_zoom_label.text = "—"
	elif _mode == Mode.SCENE:
		_preview_placeholder.text = "场景文件\n（选中后双击或点右下角使用）"
		_preview_info.text = path
		_zoom_label.text = "—"
	else:
		_preview_placeholder.text = "资源文件\n（选中后双击或点右下角使用）"
		_preview_info.text = path
		_zoom_label.text = "—"


func _fit_zoom() -> void:
	if _preview_texture == null:
		return
	var s: Vector2 = _preview_texture.get_size()
	if s.x <= 0.0 or s.y <= 0.0:
		return
	var fit: float = minf((_preview_clip.size.x - 12.0) / s.x, (_preview_clip.size.y - 12.0) / s.y)
	_zoom = clampf(minf(fit, 1.0), 0.05, 8.0)
	_apply_zoom()


func _zoom_by(f: float) -> void:
	if _preview_texture == null:
		return
	_zoom = clampf(_zoom * f, 0.05, 8.0)
	_apply_zoom()


func _apply_zoom() -> void:
	if _preview_texture == null:
		return
	var s: Vector2 = _preview_texture.get_size() * _zoom
	_preview_tex.size = s
	_preview_tex.position = ((_preview_clip.size - s) * 0.5).floor()
	_zoom_label.text = "%d%%" % int(round(_zoom * 100.0))


func _on_preview_gui_input(event: InputEvent) -> void:
	if _mode != Mode.TEXTURE:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(1.15)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(0.87)


func _toggle_play() -> void:
	if _selected.is_empty():
		return
	var stream: AudioStream = load(_selected) as AudioStream
	if stream == null:
		return
	if _audio_player.stream == stream and _audio_player.playing:
		_audio_player.stop()
		_play_btn.text = "▶ 试听"
		return
	_audio_player.stream = stream
	_audio_player.play()
	_play_btn.text = "■ 停止"


# ═══════════════════════════════════════
# 确定 / 关闭
# ═══════════════════════════════════════

func _confirm() -> void:
	if _selected.is_empty():
		return
	picked.emit(_selected)
	_close()


func _close() -> void:
	if _audio_player != null and _audio_player.playing:
		_audio_player.stop()
	closed.emit()
	queue_free()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.pressed
			and not event.echo and (event as InputEventKey).keycode == KEY_ESCAPE):
		get_viewport().set_input_as_handled()
		_close()


# ═══════════════════════════════════════
# 工具
# ═══════════════════════════════════════

func _mode_title() -> String:
	match _mode:
		Mode.AUDIO: return "选择音频"
		Mode.SCENE: return "选择场景"
		Mode.RESOURCE: return "选择资源"
	return "选择图像"


func _mode_confirm_text() -> String:
	match _mode:
		Mode.AUDIO: return "使用此音频"
		Mode.SCENE: return "使用此场景"
		Mode.RESOURCE: return "使用此资源"
	return "使用此图像"


func _mode_icon() -> String:
	match _mode:
		Mode.AUDIO: return "♪"
		Mode.SCENE: return "◇"
		Mode.RESOURCE: return "◈"
	return "▣"


func _thumb(path: String) -> Texture2D:
	if _thumb_cache.has(path):
		return _thumb_cache[path] as Texture2D
	var img: Image = null
	if FileAccess.file_exists(path):
		img = Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		var tex: Texture2D = load(path) as Texture2D
		if tex != null:
			img = tex.get_image()
	if img == null:
		return null
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w > 0 and h > 0:
		var s: float = float(THUMB_SIZE) / float(maxi(w, h))
		if s < 1.0:
			img.resize(maxi(1, int(round(w * s))), maxi(1, int(round(h * s))),
				Image.INTERPOLATE_BILINEAR)
	var out := ImageTexture.create_from_image(img)
	_thumb_cache[path] = out
	_thumb_order.append(path)
	if _thumb_order.size() > 700:
		_thumb_cache.clear()
		_thumb_order.clear()
	return out


func _checker_texture() -> Texture2D:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color("#2a2a2c"))
	for y: int in range(0, 32, 8):
		for x: int in range(0, 32, 8):
			if ((x / 8) + (y / 8)) % 2 == 0:
				img.fill_rect(Rect2i(x, y, 8, 8), Color("#343437"))
	return ImageTexture.create_from_image(img)


func _panel_sb(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	return sb


func _border_sb(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = color
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(radius)
	return sb


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", 13)
	if primary:
		var normal := _panel_sb(Color("#0e639c"), Color("#1177bb"), 3)
		var hover := _panel_sb(Color("#1177bb"), Color("#1a8ad4"), 3)
		var pressed := _panel_sb(Color("#0a4d78"), Color("#1177bb"), 3)
		var disabled := _panel_sb(Color("#2a2a2c"), Color("#3a3a3a"), 3)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", pressed)
		b.add_theme_stylebox_override("disabled", disabled)
		b.add_theme_color_override("font_color", Color("#ffffff"))
		b.add_theme_color_override("font_disabled_color", Color("#777777"))
	else:
		var normal2 := _panel_sb(Color("#333333"), Color("#454545"), 3)
		var hover2 := _panel_sb(Color("#3d3d3d"), Color("#505050"), 3)
		var pressed2 := _panel_sb(Color("#2a2a2a"), Color("#454545"), 3)
		b.add_theme_stylebox_override("normal", normal2)
		b.add_theme_stylebox_override("hover", hover2)
		b.add_theme_stylebox_override("pressed", pressed2)
	return b
