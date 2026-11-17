extends Control

## ── 架构定位 ──
## 系统：动画编辑器 ｜ 层：工具（**独立运行场景**，双击 bat 或 F6 启动）
## 联机：不涉及
## 职责：可视化编辑 `anim/*.tscn`（VXAnimSprite）—— 精灵表点选换帧、帧序列增删、
##       逐帧时长/偏移、实时播放预览，并写回 .tscn。
## 依赖：vx_anim_sprite.gd（数据结构）、anim_sheet_view.gd（格子视图）、
##       asset_browser.gd（贴图选择）；无自定义 autoload。
##
## 【为什么是独立场景而不是那个编辑器插件】
## 插件的面板在 3D/2D 编辑器停靠区里，预览要挤在 2D 视图、改一帧要来回切焦点；
## 独立场景可以把「精灵表 + 预览 + 帧列表」放在同一屏，像 RPG Maker VX Ace 的
## 动画编辑器那样点一格就换一帧、点播放立刻看到效果。
##
## 【操作】
##   左侧格子：左键 = 把**当前选中帧**换成这一格（滚轮缩放）
##   右侧：播放/暂停（空格）、上一帧/下一帧（← →）、循环、FPS
##   帧列表：点行选中；改「格」直接换该帧图案；「时长」0 = 用 1/FPS
##   Ctrl+S 保存，Ctrl+Shift+S 另存为
##
## ★本文件是开发工具，使用系统 UI 字体，不受游戏内像素字体 12 倍数规则约束。

const SHEET_VIEW_SCRIPT := preload("res://script/tools/anim_sheet_view.gd")
const FRAME_STRIP_SCRIPT := preload("res://script/tools/anim_frame_strip.gd")
const CELL_OVERLAY_SCRIPT := preload("res://script/tools/anim_cell_overlay.gd")
const ASSET_BROWSER := preload("res://script/tools/asset_browser.gd")
const SPRITE_SCRIPT := preload("res://script/vx_anim_sprite.gd")

const ANIM_DIR := "res://anim"

# ── 配色（Godot 编辑器风） ──
const C_BG := Color("#1e1e1e")
const C_PANEL := Color("#252526")
const C_PANEL2 := Color("#2d2d30")
const C_BORDER := Color("#3f3f46")
const C_TEXT := Color("#d4d4d4")
const C_MUTED := Color("#9a9a9a")
const C_ACCENT := Color("#4a9eff")
const C_WARN := Color("#ffb74d")
const C_OK := Color("#7bd88f")

## 预览画布尺寸（SubViewport 固定分辨率，容器拉伸显示）
const PREVIEW_SIZE := Vector2i(440, 210)

var _data: VXAnimSprite = null
var _file_path: String = ""
var _dirty: bool = false
var _playing: bool = false
var _sel_frame: int = 0
var _file_paths: Array[String] = []

# ── UI 引用 ──
var _file_option: OptionButton
var _status: Label
var _title: Label
## ⚠ 故意不加类型：格子视图是独立脚本（无 class_name），Godot 的静态检查看不到
## `pattern_clicked` / `zoom` / `total_cells()` 等成员，标成 Control 会编译失败。
var _sheet
var _preview_viewport: SubViewport
var _preview_root: Node2D
var _preview: VXAnimSprite
var _frame_label: Label
var _play_btn: Button
var _loop_check: CheckBox
var _fps_spin: SpinBox
var _h_spin: SpinBox
var _v_spin: SpinBox
var _off_x: SpinBox
var _off_y: SpinBox
var _scale_x: SpinBox
var _scale_y: SpinBox
var _rot_spin: SpinBox
var _tex_label: Label
var _strip
var _strip_scroll: ScrollContainer
var _pat_spin: SpinBox
var _fx_spin: SpinBox
var _fy_spin: SpinBox
var _dur_spin: SpinBox
var _overlay
var _multi_check: CheckBox
var _armed_pattern: int = 0
var _preview_dragging: bool = false
var _preview_drag_start: Vector2 = Vector2.ZERO
var _preview_drag_origin: Vector2 = Vector2.ZERO


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_scan_files()
	if not _file_paths.is_empty():
		_load_file(_file_paths[0])


func _process(_delta: float) -> void:
	## 帧条与数据保持同步：序列长度变了就整体刷新（否则会出现「只显示 1 帧」的陈旧状态）。
	if _data != null and _strip != null and _strip.sequence.size() != _data.frame_sequence.size():
		_refresh_strip()
	if _preview == null or not is_instance_valid(_preview):
		return
	if _playing:
		var idx: int = _preview.current_sequence_index()
		if idx != _sel_frame:
			_sel_frame = idx
			_sync_frame_display()
		if not _preview.is_playing():
			## 非循环播放到尾：计时器自己停了，按钮同步回「播放」。
			_playing = false
			_play_btn.text = "▶ 播放 (空格)"
			_sync_frame_display()


# ═══════════════════════════════════════
# UI 搭建
# ═══════════════════════════════════════
func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)
	root.add_child(_build_top_bar())

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 0
	root.add_child(split)
	split.add_child(_build_left())
	split.add_child(_build_right())


func _build_top_bar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _panel_style())
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	bar.add_child(h)

	_title = Label.new()
	_title.text = "动画编辑器"
	_title.add_theme_color_override("font_color", C_ACCENT)
	_title.add_theme_font_size_override("font_size", 20)
	_title.custom_minimum_size = Vector2(104, 0)
	h.add_child(_title)

	_file_option = OptionButton.new()
	_file_option.custom_minimum_size = Vector2(280, 0)
	_file_option.item_selected.connect(_on_file_option_selected)
	h.add_child(_file_option)

	h.add_child(_vsep())
	h.add_child(_button("新建", _on_new))
	h.add_child(_button("保存", _on_save))
	h.add_child(_button("另存为", _on_save_as))
	h.add_child(_button("重新加载", _on_reload))
	h.add_child(_button("重新扫描", _on_rescan))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(spacer)

	_status = Label.new()
	_status.add_theme_color_override("font_color", C_MUTED)
	_status.add_theme_font_size_override("font_size", 14)
	h.add_child(_status)
	return bar


func _build_left() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 0.40
	panel.custom_minimum_size = Vector2(360, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)

	var cap := Label.new()
	cap.text = "精灵表 · 左键把当前帧换成这一格（滚轮缩放）"
	cap.add_theme_color_override("font_color", C_MUTED)
	v.add_child(cap)

	_sheet = SHEET_VIEW_SCRIPT.new()
	_sheet.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sheet.pattern_clicked.connect(_on_sheet_pattern_clicked)
	v.add_child(_sheet)

	var zoom_row := HBoxContainer.new()
	zoom_row.add_theme_constant_override("separation", 6)
	zoom_row.add_child(_button("－", func() -> void: _set_zoom(_sheet.zoom / 1.15)))
	zoom_row.add_child(_button("＋", func() -> void: _set_zoom(_sheet.zoom * 1.15)))
	zoom_row.add_child(_button("适应", func() -> void: _set_zoom(1.0)))
	var zoom_hint := Label.new()
	zoom_hint.text = "当前帧＝黄 · 待放置＝青"
	zoom_hint.add_theme_color_override("font_color", C_MUTED)
	zoom_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoom_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	zoom_row.add_child(zoom_hint)
	v.add_child(zoom_row)

	v.add_child(_build_props())
	return panel


## 全局属性（列/行/整体偏移/缩放/旋转/贴图）。放在左栏底部，把右侧让给预览。
func _build_props() -> Control:
	var prop_panel := PanelContainer.new()
	prop_panel.add_theme_stylebox_override("panel", _panel_style())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	prop_panel.add_child(v)
	v.add_child(_label("整体属性"))
	var pgrid := GridContainer.new()
	pgrid.columns = 4
	pgrid.add_theme_constant_override("h_separation", 6)
	pgrid.add_theme_constant_override("v_separation", 2)
	v.add_child(pgrid)

	pgrid.add_child(_label("列数"))
	_h_spin = _spin(1, 64, 1, 5)
	_h_spin.value_changed.connect(func(v2: float) -> void: _on_shape_changed(int(v2), -1))
	pgrid.add_child(_h_spin)
	pgrid.add_child(_label("行数(0=自动)"))
	_v_spin = _spin(0, 64, 1, 0)
	_v_spin.value_changed.connect(func(v2: float) -> void: _on_shape_changed(-1, int(v2)))
	pgrid.add_child(_v_spin)

	pgrid.add_child(_label("偏移 X"))
	_off_x = _spin(-512, 512, 1, 0)
	_off_x.value_changed.connect(func(_v: float) -> void: _on_offset_changed())
	pgrid.add_child(_off_x)
	pgrid.add_child(_label("偏移 Y"))
	_off_y = _spin(-512, 512, 1, 0)
	_off_y.value_changed.connect(func(_v: float) -> void: _on_offset_changed())
	pgrid.add_child(_off_y)

	pgrid.add_child(_label("缩放 X"))
	_scale_x = _spin(0.05, 8.0, 0.05, 1.0)
	_scale_x.value_changed.connect(func(_v: float) -> void: _on_scale_changed())
	pgrid.add_child(_scale_x)
	pgrid.add_child(_label("缩放 Y"))
	_scale_y = _spin(0.05, 8.0, 0.05, 1.0)
	_scale_y.value_changed.connect(func(_v: float) -> void: _on_scale_changed())
	pgrid.add_child(_scale_y)

	pgrid.add_child(_label("旋转"))
	_rot_spin = _spin(-360, 360, 1, 0)
	_rot_spin.value_changed.connect(func(_v: float) -> void: _on_rotation_changed())
	pgrid.add_child(_rot_spin)

	_tex_label = Label.new()
	_tex_label.text = "—"
	_tex_label.add_theme_color_override("font_color", C_MUTED)
	_tex_label.clip_text = true
	_tex_label.custom_minimum_size = Vector2(110, 0)
	pgrid.add_child(_label("贴图"))
	pgrid.add_child(_tex_label)
	pgrid.add_child(_button("选择贴图…", _on_pick_texture))
	pgrid.add_child(_label(""))
	return prop_panel


func _build_right() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 0.60
	col.custom_minimum_size = Vector2(520, 0)
	col.add_theme_constant_override("separation", 8)

	# ── 预览：占满右侧剩余高度（用户要求「预览要大」）──
	var preview_panel := PanelContainer.new()
	preview_panel.add_theme_stylebox_override("panel", _panel_style())
	preview_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var pv := VBoxContainer.new()
	preview_panel.add_child(pv)
	var pv_cap := Label.new()
	pv_cap.text = "预览（左键拖动 = 移动当前帧 / 右键 = 帧菜单）"
	pv_cap.add_theme_color_override("font_color", C_MUTED)
	pv.add_child(pv_cap)

	var vp_container := SubViewportContainer.new()
	vp_container.custom_minimum_size = Vector2(520, 360)
	vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	## stretch=true：SubViewport 跟随容器尺寸（像素 1:1，不会拉伸变形），
	## 这样窗口多大预览就多大，而不是固定一小块。
	vp_container.stretch = true
	pv.add_child(vp_container)

	_preview_viewport = SubViewport.new()
	_preview_viewport.size = PREVIEW_SIZE
	_preview_viewport.transparent_bg = false
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp_container.add_child(_preview_viewport)

	var bg := ColorRect.new()
	bg.color = Color("#101014")
	bg.size = Vector2(PREVIEW_SIZE)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_viewport.add_child(bg)

	_preview_viewport.size_changed.connect(func() -> void:
		if bg != null:
			bg.size = Vector2(_preview_viewport.size))

	_preview_root = Node2D.new()
	_preview_viewport.add_child(_preview_root)
	## 视口尺寸随窗口变化 → 动画始终居中。
	vp_container.resized.connect(func() -> void:
		if _preview_root != null:
			_preview_root.position = Vector2(_preview_viewport.size) * 0.5
		_sync_overlay())
	_preview_root.position = Vector2(PREVIEW_SIZE) * 0.5

	## 帧视图覆盖层：画 cell 边框/序号，处理摆放、拖动、右击（对齐 VX Ace 的帧视图）。
	_overlay = CELL_OVERLAY_SCRIPT.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_overlay.cell_selected.connect(func(_i: int) -> void: pass)
	_overlay.cell_moved.connect(_on_cell_moved)
	_overlay.cell_menu_requested.connect(_on_cell_menu_requested)
	_overlay.empty_clicked.connect(_on_overlay_empty_clicked)
	_overlay.empty_menu_requested.connect(_on_overlay_empty_menu)
	vp_container.add_child(_overlay)
	col.add_child(preview_panel)

	# ── 播放控制 ──
	var play_row := HBoxContainer.new()
	play_row.add_theme_constant_override("separation", 6)
	play_row.add_child(_button("◀ 上帧", func() -> void: _step(-1)))
	_play_btn = _button("▶ 播放 (空格)", _toggle_play)
	play_row.add_child(_play_btn)
	play_row.add_child(_button("下帧 ▶", func() -> void: _step(1)))
	_loop_check = CheckBox.new()
	_loop_check.text = "循环"
	_loop_check.button_pressed = true
	_loop_check.toggled.connect(func(_on: bool) -> void: _rebuild_preview())
	play_row.add_child(_loop_check)

	_multi_check = CheckBox.new()
	_multi_check.text = "多格"
	_multi_check.tooltip_text = "开启后可在帧视图里摆放多个图案（最多 16 个），对应 VX 的 cell"
	_multi_check.toggled.connect(_on_multi_toggled)
	play_row.add_child(_multi_check)

	var fps_cap := Label.new()
	fps_cap.text = "FPS"
	fps_cap.add_theme_color_override("font_color", C_MUTED)
	play_row.add_child(fps_cap)
	_fps_spin = _spin(0.1, 120.0, 0.1, 10.0)
	_fps_spin.value_changed.connect(func(v: float) -> void: _on_fps_changed(v))
	play_row.add_child(_fps_spin)

	_frame_label = Label.new()
	_frame_label.add_theme_color_override("font_color", C_ACCENT)
	play_row.add_child(_frame_label)
	col.add_child(play_row)

	# ── 帧条（RMVXA 风格：一排缩略图，可选中 / 拖动排序 / 右击） ──
	var seq_panel := PanelContainer.new()
	seq_panel.add_theme_stylebox_override("panel", _panel_style())
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 4)
	seq_panel.add_child(sv)
	var seq_cap := Label.new()
	seq_cap.text = "帧条 · 点击选中 / 左右拖动排序 / 右击出菜单"
	seq_cap.add_theme_color_override("font_color", C_MUTED)
	sv.add_child(seq_cap)

	_strip_scroll = ScrollContainer.new()
	_strip_scroll.custom_minimum_size = Vector2(0, 74)
	_strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sv.add_child(_strip_scroll)
	_strip = FRAME_STRIP_SCRIPT.new()
	_strip.frame_selected.connect(_on_strip_selected)
	_strip.frame_reordered.connect(_on_strip_reordered)
	_strip.frame_menu_requested.connect(_on_frame_menu_requested)
	_strip_scroll.add_child(_strip)

	var seq_btns := HBoxContainer.new()
	seq_btns.add_theme_constant_override("separation", 6)
	seq_btns.add_child(_button("＋ 添加帧", _on_add_frame))
	seq_btns.add_child(_button("复制当前帧", _on_duplicate_frame))
	seq_btns.add_child(_button("删除当前帧", _on_delete_frame))
	seq_btns.add_child(_button("按格子重建序列", _on_rebuild_sequence))
	sv.add_child(seq_btns)
	col.add_child(seq_panel)

	# ── 当前帧参数（等同 RMVXA 里对单帧做的微调）──
	var param_panel := PanelContainer.new()
	param_panel.add_theme_stylebox_override("panel", _panel_style())
	var ppv2 := VBoxContainer.new()
	ppv2.add_theme_constant_override("separation", 2)
	param_panel.add_child(ppv2)
	var pcap := Label.new()
	pcap.text = "当前帧参数（即时生效；也可在预览里直接拖动画）"
	pcap.add_theme_color_override("font_color", C_MUTED)
	ppv2.add_child(pcap)
	var ppgrid := GridContainer.new()
	ppgrid.columns = 4
	ppgrid.add_theme_constant_override("h_separation", 8)
	ppgrid.add_child(_label("图片索引"))
	_pat_spin = _spin(0, 9999, 1, 0)
	_pat_spin.value_changed.connect(func(v: float) -> void: _set_pattern_of_current(int(v)))
	ppgrid.add_child(_pat_spin)
	ppgrid.add_child(_label("时长(0=FPS)"))
	_dur_spin = _spin(0.0, 5.0, 0.01, 0.0)
	_dur_spin.value_changed.connect(func(v: float) -> void: _set_duration_of_current(v))
	ppgrid.add_child(_dur_spin)
	ppgrid.add_child(_label("偏移 X"))
	_fx_spin = _spin(-512, 512, 1, 0)
	_fx_spin.value_changed.connect(func(_v: float) -> void: _set_offset_of_current())
	ppgrid.add_child(_fx_spin)
	ppgrid.add_child(_label("偏移 Y"))
	_fy_spin = _spin(-512, 512, 1, 0)
	_fy_spin.value_changed.connect(func(_v: float) -> void: _set_offset_of_current())
	ppgrid.add_child(_fy_spin)
	ppv2.add_child(ppgrid)
	col.add_child(param_panel)
	return col


func _scan_files() -> void:
	_file_paths.clear()
	var dir := DirAccess.open(ANIM_DIR)
	if dir != null:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while not fn.is_empty():
			if fn.ends_with(".tscn") and not dir.current_is_dir():
				_file_paths.append("%s/%s" % [ANIM_DIR, fn])
			fn = dir.get_next()
		dir.list_dir_end()
	_file_paths.sort()
	_file_option.clear()
	for p: String in _file_paths:
		_file_option.add_item(p.get_file())
	_select_file_in_option()


func _on_rescan() -> void:
	_scan_files()
	_select_file_in_option()
	_set_status("已扫描 %d 个动画" % _file_paths.size())


func _select_file_in_option() -> void:
	if _file_path.is_empty():
		return
	for i: int in range(_file_paths.size()):
		if _file_paths[i] == _file_path:
			_file_option.select(i)
			return


func _on_file_option_selected(idx: int) -> void:
	if idx < 0 or idx >= _file_paths.size():
		return
	_load_file(_file_paths[idx])


func _load_file(path: String) -> void:
	if not ResourceLoader.exists(path):
		_set_status("文件不存在：%s" % path, true)
		return
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		_set_status("不是场景文件：%s" % path, true)
		return
	var node: Node = packed.instantiate()
	var sprite: VXAnimSprite = _find_sprite(node)
	if sprite == null:
		node.queue_free()
		_set_status("场景里没有 VXAnimSprite：%s" % path, true)
		return
	if sprite != node:
		node.queue_free()
	_free_preview()
	if _data != null and is_instance_valid(_data):
		_data.queue_free()
	_data = sprite
	_file_path = path
	_dirty = false
	_sel_frame = 0
	_playing = false
	_play_btn.text = "▶ 播放 (空格)"
	_pull_data_to_ui()
	_refresh_strip()
	_rebuild_preview()
	_select_file_in_option()
	_set_status("已打开 %s" % path.get_file())


## 从场景根或其后代里找出第一个 VXAnimSprite。
func _find_sprite(node: Node) -> VXAnimSprite:
	if node is VXAnimSprite:
		return node as VXAnimSprite
	for child: Node in node.get_children():
		var found: VXAnimSprite = _find_sprite(child)
		if found != null:
			return found
	return null


func _on_new() -> void:
	## 用户要求：新建时先给名字 → 立刻保存成 anim/<名字>.tscn → 直接编辑这个新场景。
	var dlg := ConfirmationDialog.new()
	dlg.title = "新建动画"
	dlg.ok_button_text = "创建并编辑"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	dlg.add_child(box)
	box.add_child(_label("动画名（保存为 res://anim/<名字>.tscn）"))
	var name_edit := LineEdit.new()
	name_edit.text = "anim_effect_new"
	name_edit.custom_minimum_size = Vector2(340, 0)
	name_edit.select_all_on_focus = true
	box.add_child(name_edit)
	var hint := Label.new()
	hint.text = "创建后会先落盘再进入编辑；贴图随后在左下「整体属性 → 选择贴图」里选。"
	hint.add_theme_color_override("font_color", C_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(340, 0)
	box.add_child(hint)
	dlg.confirmed.connect(func() -> void:
		_create_new(name_edit.text)
		dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()
	name_edit.grab_focus()


## 按名字创建空动画并立即保存，随后绑定为当前文件。
func _create_new(raw_name: String) -> void:
	var nm: String = raw_name.strip_edges()
	if nm.is_empty():
		nm = "anim_effect_new"
	if nm.ends_with(".tscn"):
		nm = nm.substr(0, nm.length() - 5)
	nm = nm.replace("/", "_").replace("\\", "_")
	var path: String = "%s/%s.tscn" % [ANIM_DIR, nm]
	if FileAccess.file_exists(path):
		_set_status("%s 已存在 —— 换个名字，或直接用下拉框打开它" % path, true)
		return

	_free_preview()
	if _data != null and is_instance_valid(_data):
		_data.queue_free()
	_data = VXAnimSprite.new()
	_data.h_frames = 5
	_data.fps = 20.0
	_data.auto_free = false
	_data.frame_sequence = []
	_data.cell_data = []
	_file_path = path
	_sel_frame = 0
	_playing = false
	_dirty = false
	_play_btn.text = "▶ 播放 (空格)"
	_pull_data_to_ui()
	_refresh_strip()
	_rebuild_preview()
	_save_to(path)
	_scan_files()
	_select_file_in_option()
	_set_status("已创建 %s —— 先选贴图，再点格子组帧" % path.get_file())
func _on_save() -> void:
	if _file_path.is_empty():
		_on_save_as()
		return
	_save_to(_file_path)


func _on_save_as() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_RESOURCES
	fd.add_filter("*.tscn", "动画场景")
	fd.current_dir = ANIM_DIR
	fd.current_file = _file_path.get_file() if not _file_path.is_empty() else "anim_effect_new.tscn"
	fd.file_selected.connect(func(path: String) -> void:
		_save_to(path)
		fd.queue_free())
	fd.canceled.connect(func() -> void: fd.queue_free())
	add_child(fd)
	fd.popup_centered_ratio(0.65)


func _save_to(path: String) -> void:
	if _data == null:
		return
	_pull_ui_to_data()
	var packed := PackedScene.new()
	var err: int = packed.pack(_data)
	if err != OK:
		_set_status("打包失败：%d" % err, true)
		return
	err = ResourceSaver.save(packed, path)
	if err != OK:
		_set_status("保存失败：%d（%s）" % [err, path], true)
		return
	_file_path = path
	_dirty = false
	_set_status("已保存 %s" % path.get_file())
	_update_title()


func _on_reload() -> void:
	if _file_path.is_empty():
		return
	_load_file(_file_path)


# ═══════════════════════════════════════
# 数据 ↔ UI
# ═══════════════════════════════════════
func _pull_data_to_ui() -> void:
	if _data == null:
		return
	_h_spin.set_value_no_signal(maxi(1, _data.h_frames))
	_v_spin.set_value_no_signal(maxi(0, _data.v_frames))
	_off_x.set_value_no_signal(_data.position_offset.x)
	_off_y.set_value_no_signal(_data.position_offset.y)
	_scale_x.set_value_no_signal(_data.animation_scale.x)
	_scale_y.set_value_no_signal(_data.animation_scale.y)
	_rot_spin.set_value_no_signal(_data.animation_rotation)
	_fps_spin.set_value_no_signal(clampf(_data.fps, 0.1, 120.0))
	_tex_label.text = _data.texture.resource_path.get_file() if _data.texture != null else "（未设置）"
	_sheet.texture = _data.texture
	_sheet.h_frames = maxi(1, _data.h_frames)
	_sheet.v_frames = maxi(0, _data.v_frames)
	_sheet.zoom = 1.0
	if not _data.frame_sequence.is_empty():
		_armed_pattern = _data.frame_sequence[0]
	_sheet.refresh()
	if _multi_check != null:
		_multi_check.set_pressed_no_signal(not _data.cell_data.is_empty())
	_update_title()
	_sync_frame_display()


func _pull_ui_to_data() -> void:
	if _data == null:
		return
	_data.h_frames = maxi(1, int(_h_spin.value))
	_data.v_frames = maxi(0, int(_v_spin.value))
	_data.position_offset = Vector2(_off_x.value, _off_y.value)
	_data.animation_scale = Vector2(_scale_x.value, _scale_y.value)
	_data.animation_rotation = _rot_spin.value
	_data.fps = _fps_spin.value


func _update_title() -> void:
	var name_txt: String = _file_path.get_file() if not _file_path.is_empty() else "未命名"
	var mark: String = " *" if _dirty else ""
	_title.text = "动画编辑器" + mark
	get_window().title = "动画编辑器 — %s%s" % [name_txt, mark]


func _sync_frame_display() -> void:
	if _data == null:
		_frame_label.text = ""
		return
	var total: int = _data.frame_sequence.size()
	_frame_label.text = "帧 %d/%d" % [_sel_frame + 1, maxi(1, total)]
	var active: int = -1
	if _sel_frame >= 0 and _sel_frame < total:
		active = _data.frame_sequence[_sel_frame]
	var multi: bool = _multi_check != null and _multi_check.button_pressed
	## 多格模式下「这一帧」是若干 cell 的组合，没有单一图案可高亮 → 只亮待放置图案。
	_sheet.active_pattern = -1 if multi else active
	_sheet.armed_pattern = _armed_pattern if multi else -1
	_sheet.refresh()
	_refresh_strip()
	_sync_frame_params_ui()
	_sync_overlay()


# ═══════════════════════════════════════
# 精灵表交互
# ═══════════════════════════════════════
func _set_zoom(z: float) -> void:
	_sheet.zoom = clampf(z, 0.25, 6.0)
	_sheet.refresh()


func _on_sheet_pattern_clicked(pattern: int) -> void:
	if _data == null:
		return
	if _data.frame_sequence.is_empty():
		_on_rebuild_sequence()
		if _data.frame_sequence.is_empty():
			return
	_armed_pattern = pattern
	_sheet.armed_pattern = pattern
	_sheet.refresh()
	if _multi_check != null and _multi_check.button_pressed:
		if _cells_of_frame().is_empty():
			_on_overlay_empty_clicked(Vector2(_preview_viewport.size) * 0.5)
		else:
			_set_status("已选中图案 %d：在预览里点空白处放置（右键可放置/取消）" % pattern)
		return
	_set_pattern_of_current(pattern)
	_sync_frame_params_ui()


## 只改序列里某一帧的图案：字面量数组要整体赋值才会触发 setter/序列化。
func _set_sequence_at(idx: int, pattern: int) -> void:
	if _data == null or idx < 0 or idx >= _data.frame_sequence.size():
		return
	var seq: Array[int] = _data.frame_sequence.duplicate()
	seq[idx] = pattern
	_data.frame_sequence = seq


func _on_shape_changed(h: int, v: int) -> void:
	if _data == null:
		return
	if h >= 0:
		_data.h_frames = maxi(1, h)
	if v >= 0:
		_data.v_frames = maxi(0, v)
	_dirty = true
	_sheet.h_frames = _data.h_frames
	_sheet.v_frames = _data.v_frames
	_sheet.refresh()
	_rebuild_preview()


func _on_offset_changed() -> void:
	if _data == null:
		return
	_data.position_offset = Vector2(_off_x.value, _off_y.value)
	_dirty = true
	_rebuild_preview()


func _on_scale_changed() -> void:
	if _data == null:
		return
	_data.animation_scale = Vector2(_scale_x.value, _scale_y.value)
	_dirty = true
	_rebuild_preview()


func _on_rotation_changed() -> void:
	if _data == null:
		return
	_data.animation_rotation = _rot_spin.value
	_dirty = true
	_rebuild_preview()


func _on_fps_changed(v: float) -> void:
	if _data == null:
		return
	_data.fps = maxf(0.1, v)
	_dirty = true
	_rebuild_preview()


# ═══════════════════════════════════════
# 帧条 / 帧参数
# ═══════════════════════════════════════
## 让 frame_offsets / frame_durations 与 frame_sequence 等长（缺的补 0）。
func _ensure_frame_arrays() -> void:
	if _data == null:
		return
	var n: int = _data.frame_sequence.size()
	var fallback: float = 1.0 / maxf(0.1, _data.fps)
	var offs: Array[Vector2] = _data.frame_offsets.duplicate()
	var durs: Array[float] = _data.frame_durations.duplicate()
	while offs.size() < n:
		offs.append(Vector2.ZERO)
	while durs.size() < n:
		durs.append(fallback)
	if offs.size() > n:
		offs.resize(n)
	if durs.size() > n:
		durs.resize(n)
	## ★0 时长会让 VXAnimSprite 的 Timer 报 "Time should be greater than zero"
	##   （历史文件里若已有 0，这里顺手抹平）。
	for i: int in range(durs.size()):
		if durs[i] <= 0.0:
			durs[i] = fallback
	_data.frame_offsets = offs
	_data.frame_durations = durs
func _refresh_strip() -> void:
	if _strip == null:
		return
	_strip.sheet = _data.texture if _data != null else null
	_strip.h_frames = maxi(1, _data.h_frames) if _data != null else 5
	_strip.v_frames = maxi(0, _data.v_frames) if _data != null else 0
	_strip.sequence = _data.frame_sequence.duplicate() if _data != null else []
	_strip.selected = _sel_frame
	_strip.playing = _playing
	_strip.playing_index = _sel_frame if _playing else -1
	_strip.refresh()


func _on_strip_selected(idx: int) -> void:
	_select_frame(idx)


func _on_strip_reordered(from_idx: int, to_idx: int) -> void:
	if _data == null:
		return
	var seq: Array[int] = _data.frame_sequence.duplicate()
	var offs: Array[Vector2] = _data.frame_offsets.duplicate()
	var durs: Array[float] = _data.frame_durations.duplicate()
	var old_n: int = seq.size()
	_move_entry(seq, from_idx, to_idx)
	## 只有本来就与序列等长的数组才跟着搬（空数组 = 全用默认值，别凭空烘数据）。
	if offs.size() == old_n:
		_move_entry(offs, from_idx, to_idx)
		_data.frame_offsets = offs
	if durs.size() == old_n:
		_move_entry(durs, from_idx, to_idx)
		_data.frame_durations = durs
	_data.frame_sequence = seq
	_sel_frame = clampi(to_idx, 0, seq.size() - 1)
	_dirty = true
	_refresh_strip()
	_rebuild_preview()


func _move_entry(arr: Array, from_idx: int, to_idx: int) -> void:
	if from_idx < 0 or from_idx >= arr.size():
		return
	var v: Variant = arr[from_idx]
	arr.remove_at(from_idx)
	arr.insert(clampi(to_idx, 0, arr.size()), v)


## ── 帧剪贴板 / 粘贴 / 清空 / 补间 ──
var _frame_clip: Dictionary = {}


func _cells_of_index(i: int) -> Array:
	var out: Array = []
	if _data == null or i < 0 or i >= _data.frame_sequence.size():
		return out
	var key: int = _data.frame_sequence[i]
	for cd in _data.cell_data:
		if cd.frame_idx == key:
			out.append(cd)
	return out


func _copy_frame_at(idx: int) -> void:
	if _data == null or idx < 0 or idx >= _data.frame_sequence.size():
		return
	var cells: Array = []
	for cd in _cells_of_index(idx):
		cells.append({
			"pattern": cd.pattern, "offset": cd.offset, "scale": cd.scale,
			"rotation": cd.rotation_deg, "opacity": cd.opacity,
			"blend": cd.blend_mode, "flip": cd.flip_h,
		})
	_frame_clip = {
		"pattern": _data.frame_sequence[idx],
		"offset": _data.frame_offsets[idx] if idx < _data.frame_offsets.size() else Vector2.ZERO,
		"duration": _data.frame_durations[idx] if idx < _data.frame_durations.size() else 0.0,
		"cells": cells,
	}
	_set_status("已复制第 %d 帧（%d 个 cell）—— 到目标帧右键「粘贴到本帧」" % [idx + 1, cells.size()])


func _paste_frame_at(idx: int) -> void:
	if _data == null:
		return
	if _frame_clip.is_empty():
		_set_status("剪贴板是空的：先在某一帧右键「复制本帧」", true)
		return
	_apply_clip_to(idx)
	_set_status("已粘贴到第 %d 帧" % (idx + 1))


func _apply_clip_to(idx: int) -> void:
	var seq: Array[int] = _data.frame_sequence.duplicate()
	var new_key: int = int(_frame_clip.get("pattern", seq[idx]))
	seq[idx] = new_key
	_data.frame_sequence = seq

	## 先摘掉该帧原有 cell，再把剪贴板里的逐个还原（frame_idx 用新 key）。
	var kept: Array[VXAnimCellData] = []
	for cd in _data.cell_data:
		if cd.frame_idx != new_key:
			kept.append(cd)
	for spec in _frame_clip.get("cells", []):
		var c := VXAnimCellData.new()
		c.frame_idx = new_key
		c.pattern = int(spec.get("pattern", 0))
		c.offset = spec.get("offset", Vector2.ZERO)
		c.scale = spec.get("scale", Vector2.ONE)
		c.rotation_deg = float(spec.get("rotation", 0.0))
		c.opacity = float(spec.get("opacity", 1.0))
		c.blend_mode = int(spec.get("blend", 0))
		c.flip_h = bool(spec.get("flip", false))
		kept.append(c)
	_data.cell_data = kept

	_ensure_frame_arrays()
	var offs: Array[Vector2] = _data.frame_offsets.duplicate()
	var durs: Array[float] = _data.frame_durations.duplicate()
	offs[idx] = _frame_clip.get("offset", Vector2.ZERO)
	durs[idx] = _frame_clip.get("duration", 0.0)
	_data.frame_offsets = offs
	_data.frame_durations = durs
	_dirty = true
	_sync_frame_display()
	_rebuild_preview()


## VA 的 Paste Last：把上一帧的 cell 原样贴到当前帧。
func _paste_last_at(idx: int) -> void:
	if _data == null or idx <= 0:
		_set_status("第 1 帧没有「上一帧」可贴", true)
		return
	var src: Array = _cells_of_index(idx - 1)
	if src.is_empty():
		_set_status("上一帧没有 cell 可贴（先打开「多格」并放置）", true)
		return
	var key: int = _data.frame_sequence[idx]
	var kept: Array[VXAnimCellData] = []
	for cd in _data.cell_data:
		if cd.frame_idx != key:
			kept.append(cd)
	for cd in src:
		var c: VXAnimCellData = cd.duplicate()
		c.frame_idx = key
		kept.append(c)
	_data.cell_data = kept
	_dirty = true
	_sync_frame_display()
	_rebuild_preview()
	_set_status("已把第 %d 帧的 %d 个 cell 贴到第 %d 帧" % [idx, src.size(), idx + 1])


func _clear_frame_at(idx: int) -> void:
	if _data == null:
		return
	var key: int = _data.frame_sequence[idx]
	var kept: Array[VXAnimCellData] = []
	for cd in _data.cell_data:
		if cd.frame_idx != key:
			kept.append(cd)
	_data.cell_data = kept
	_ensure_frame_arrays()
	var offs: Array[Vector2] = _data.frame_offsets.duplicate()
	var durs: Array[float] = _data.frame_durations.duplicate()
	offs[idx] = Vector2.ZERO
	durs[idx] = 0.0
	_data.frame_offsets = offs
	_data.frame_durations = durs
	_dirty = true
	_sync_frame_display()
	_rebuild_preview()
	_set_status("已清空第 %d 帧" % (idx + 1))


## VA 的 Tweening：在两帧之间对 cell 的位置/缩放/不透明度/角度做线性补间。
func _open_tween_dialog() -> void:
	if _data == null:
		return
	var n: int = _data.frame_sequence.size()
	if n < 3:
		_set_status("至少 3 帧才能补间（首尾是关键帧）", true)
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "补间 Tweening"
	dlg.ok_button_text = "执行"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	dlg.add_child(box)
	box.add_child(_label("在起始帧与结束帧之间自动补间（两端是关键帧，中间的帧会被覆盖）"))
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	grid.add_child(_label("起始帧"))
	var a_spin := _spin(1, n, 1, clampi(_sel_frame + 1, 1, n))
	grid.add_child(a_spin)
	grid.add_child(_label("结束帧"))
	var b_spin := _spin(1, n, 1, clampi(_sel_frame + 2, 1, n))
	grid.add_child(b_spin)
	var cb_pos := CheckBox.new()
	cb_pos.text = "位置"
	cb_pos.button_pressed = true
	box.add_child(cb_pos)
	var cb_scale := CheckBox.new()
	cb_scale.text = "缩放"
	box.add_child(cb_scale)
	var cb_op := CheckBox.new()
	cb_op.text = "不透明度"
	box.add_child(cb_op)
	var cb_rot := CheckBox.new()
	cb_rot.text = "角度"
	box.add_child(cb_rot)
	dlg.confirmed.connect(func() -> void:
		_tween_frames(int(a_spin.value) - 1, int(b_spin.value) - 1,
			cb_pos.button_pressed, cb_scale.button_pressed, cb_op.button_pressed, cb_rot.button_pressed)
		dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


func _tween_frames(a: int, b: int, do_pos: bool, do_scale: bool, do_op: bool, do_rot: bool) -> void:
	if _data == null or b - a < 2:
		_set_status("补间需要至少 3 帧的区间", true)
		return
	var ca: Array = _cells_of_index(a)
	var cb: Array = _cells_of_index(b)
	if ca.is_empty() or cb.is_empty():
		_set_status("首尾帧都得有 cell（先开多格并放置）", true)
		return
	var count: int = mini(ca.size(), cb.size())
	for f: int in range(a + 1, b):
		var key: int = _data.frame_sequence[f]
		var kept: Array[VXAnimCellData] = []
		for cd in _data.cell_data:
			if cd.frame_idx != key:
				kept.append(cd)
		var t: float = float(f - a) / float(b - a)
		for j: int in range(count):
			var c := VXAnimCellData.new()
			c.frame_idx = key
			c.pattern = ca[j].pattern
			c.offset = ca[j].offset.lerp(cb[j].offset, t) if do_pos else ca[j].offset
			c.scale = ca[j].scale.lerp(cb[j].scale, t) if do_scale else ca[j].scale
			c.rotation_deg = lerpf(ca[j].rotation_deg, cb[j].rotation_deg, t) if do_rot else ca[j].rotation_deg
			c.opacity = lerpf(ca[j].opacity, cb[j].opacity, t) if do_op else ca[j].opacity
			c.blend_mode = ca[j].blend_mode
			c.flip_h = ca[j].flip_h
			kept.append(c)
		_data.cell_data = kept
	_dirty = true
	_sync_frame_display()
	_rebuild_preview()
	_set_status("已补间第 %d~%d 帧（%d 个 cell/帧）" % [a + 1, b + 1, count])


## 右键帧（帧条或预览里）→ 弹 RMVXA 式帧菜单。
func _on_frame_menu_requested(idx: int, screen_pos: Vector2) -> void:
	if _data == null or _data.frame_sequence.is_empty():
		return
	_sel_frame = clampi(idx, 0, _data.frame_sequence.size() - 1)
	_sync_frame_display()
	var menu := PopupMenu.new()
	menu.add_item("帧参数…", 0)
	menu.add_separator()
	menu.add_item("在前面插入一帧", 1)
	menu.add_item("复制本帧", 2)
	menu.add_item("粘贴到本帧", 5)
	menu.add_item("贴上一帧的 cell（Paste Last）", 6)
	menu.add_item("清空本帧", 7)
	menu.add_item("补间 Tweening…", 8)
	menu.add_separator()
	menu.add_item("删除本帧", 3)
	menu.id_pressed.connect(func(id: int) -> void: _on_frame_menu_id(id, idx))
	menu.close_requested.connect(func() -> void: menu.queue_free())
	add_child(menu)
	menu.popup(Rect2i(Vector2i(screen_pos), Vector2i.ZERO))


func _on_frame_menu_id(id: int, idx: int) -> void:
	match id:
		0, 4:
			_open_frame_params_dialog(idx)
		1:
			_insert_frame_at(idx)
		2:
			_copy_frame_at(idx)
		3:
			_delete_frame_at(idx)
		5:
			_paste_frame_at(idx)
		6:
			_paste_last_at(idx)
		7:
			_clear_frame_at(idx)
		8:
			_open_tween_dialog()


## 帧参数对话框：图片索引 / 偏移 / 时长（= RMVXA 右击帧里的「设置」）。
func _open_frame_params_dialog(idx: int) -> void:
	if _data == null or idx < 0 or idx >= _data.frame_sequence.size():
		return
	_ensure_frame_arrays()
	var dlg := ConfirmationDialog.new()
	dlg.title = "帧参数 · 第 %d 帧" % (idx + 1)
	dlg.ok_button_text = "应用"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	dlg.add_child(box)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	box.add_child(grid)

	grid.add_child(_label("图片索引（精灵表格子）"))
	var pat := _spin(0, 9999, 1, _data.frame_sequence[idx])
	pat.custom_minimum_size = Vector2(140, 0)
	grid.add_child(pat)

	grid.add_child(_label("偏移 X"))
	var fx := _spin(-512, 512, 1, _data.frame_offsets[idx].x)
	fx.custom_minimum_size = Vector2(140, 0)
	grid.add_child(fx)

	grid.add_child(_label("偏移 Y"))
	var fy := _spin(-512, 512, 1, _data.frame_offsets[idx].y)
	fy.custom_minimum_size = Vector2(140, 0)
	grid.add_child(fy)

	grid.add_child(_label("时长（0 = 用 FPS）"))
	var dur := _spin(0.0, 5.0, 0.01, _data.frame_durations[idx])
	dur.custom_minimum_size = Vector2(140, 0)
	grid.add_child(dur)

	dlg.confirmed.connect(func() -> void:
		_set_pattern_at(idx, int(pat.value))
		_set_offset_at(idx, Vector2(fx.value, fy.value))
		_set_duration_at(idx, dur.value)
		_refresh_strip()
		_apply_preview_seek()
		_sync_frame_display()
		dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


func _insert_frame_at(idx: int) -> void:
	if _data == null:
		return
	_ensure_frame_arrays()
	var seq: Array[int] = _data.frame_sequence.duplicate()
	var offs: Array[Vector2] = _data.frame_offsets.duplicate()
	var durs: Array[float] = _data.frame_durations.duplicate()
	var pattern: int = seq[clampi(idx, 0, seq.size() - 1)]
	seq.insert(idx, pattern)
	offs.insert(idx, Vector2.ZERO)
	durs.insert(idx, 0.0)
	_data.frame_sequence = seq
	_data.frame_offsets = offs
	_data.frame_durations = durs
	_sel_frame = idx
	_dirty = true
	_refresh_strip()
	_rebuild_preview()
	_update_title()


func _duplicate_frame_at(idx: int) -> void:
	if _data == null:
		return
	_ensure_frame_arrays()
	var seq: Array[int] = _data.frame_sequence.duplicate()
	var offs: Array[Vector2] = _data.frame_offsets.duplicate()
	var durs: Array[float] = _data.frame_durations.duplicate()
	var at: int = clampi(idx, 0, seq.size() - 1)
	seq.insert(at + 1, seq[at])
	offs.insert(at + 1, offs[at])
	durs.insert(at + 1, durs[at])
	_data.frame_sequence = seq
	_data.frame_offsets = offs
	_data.frame_durations = durs
	_sel_frame = at + 1
	_dirty = true
	_refresh_strip()
	_rebuild_preview()
	_update_title()


func _delete_frame_at(idx: int) -> void:
	if _data == null or _data.frame_sequence.size() <= 1:
		return
	_ensure_frame_arrays()
	var seq: Array[int] = _data.frame_sequence.duplicate()
	var offs: Array[Vector2] = _data.frame_offsets.duplicate()
	var durs: Array[float] = _data.frame_durations.duplicate()
	var at: int = clampi(idx, 0, seq.size() - 1)
	seq.remove_at(at)
	offs.remove_at(at)
	durs.remove_at(at)
	_data.frame_sequence = seq
	_data.frame_offsets = offs
	_data.frame_durations = durs
	_sel_frame = clampi(at, 0, seq.size() - 1)
	_dirty = true
	_refresh_strip()
	_rebuild_preview()
	_update_title()


## 当前帧参数 → 数据（供内联 SpinBox 与预览拖动共用）。
func _set_pattern_of_current(p: int) -> void:
	_set_pattern_at(_sel_frame, p)
	_refresh_strip()
	_apply_preview_seek()


func _set_pattern_at(idx: int, p: int) -> void:
	if _data == null or idx < 0 or idx >= _data.frame_sequence.size():
		return
	var seq: Array[int] = _data.frame_sequence.duplicate()
	seq[idx] = p
	_data.frame_sequence = seq
	_dirty = true
	_preview.frame_sequence = seq.duplicate() if _preview != null and is_instance_valid(_preview) else _preview.frame_sequence
	if _preview != null and is_instance_valid(_preview):
		if not _playing:
			_preview.seek_sequence(idx)
	_sheet.active_pattern = p
	_sheet.refresh()
	_update_title()


func _set_offset_of_current() -> void:
	_set_offset_at(_sel_frame, Vector2(_fx_spin.value, _fy_spin.value))


func _set_offset_at(idx: int, v: Vector2) -> void:
	if _data == null or idx < 0 or idx >= _data.frame_sequence.size():
		return
	_ensure_frame_arrays()
	var offs: Array[Vector2] = _data.frame_offsets.duplicate()
	offs[idx] = v
	_data.frame_offsets = offs
	_dirty = true
	if _preview != null and is_instance_valid(_preview):
		_preview.frame_offsets = offs.duplicate()
		if not _playing:
			_preview.seek_sequence(idx)
	_sync_frame_params_ui()
	_update_title()


func _set_duration_of_current(d: float) -> void:
	_set_duration_at(_sel_frame, d)


func _set_duration_at(idx: int, d: float) -> void:
	if _data == null or idx < 0 or idx >= _data.frame_sequence.size():
		return
	_ensure_frame_arrays()
	var durs: Array[float] = _data.frame_durations.duplicate()
	## 0 / 负数一律落成 1/FPS：运行时 Timer 不接受 0 时长的帧。
	durs[idx] = d if d > 0.0 else 1.0 / maxf(0.1, _data.fps)
	_data.frame_durations = durs
	_dirty = true
	if _preview != null and is_instance_valid(_preview):
		_preview.frame_durations = durs.duplicate()
		if not _playing:
			_preview.seek_sequence(idx)
	_update_title()


func _select_frame(i: int) -> void:
	if _data == null:
		return
	_sel_frame = clampi(i, 0, maxi(0, _data.frame_sequence.size() - 1))
	_playing = false
	_play_btn.text = "▶ 播放 (空格)"
	_sync_frame_display()
	_apply_preview_seek()


func _step(delta: int) -> void:
	if _data == null or _data.frame_sequence.is_empty():
		return
	var total: int = _data.frame_sequence.size()
	_sel_frame = posmod(_sel_frame + delta, total)
	_playing = false
	_play_btn.text = "▶ 播放 (空格)"
	_sync_frame_display()
	_apply_preview_seek()


func _on_add_frame() -> void:
	if _data == null:
		return
	var seq: Array[int] = _data.frame_sequence.duplicate()
	var pattern: int = 0
	if not seq.is_empty():
		pattern = (seq[seq.size() - 1] + 1) % maxi(1, _sheet.total_cells())
	seq.append(pattern)
	_data.frame_sequence = seq
	_sel_frame = seq.size() - 1
	_dirty = true
	_ensure_frame_arrays()
	_refresh_strip()
	_rebuild_preview()
	_update_title()


func _on_duplicate_frame() -> void:
	_duplicate_frame_at(_sel_frame)


func _on_delete_frame() -> void:
	_delete_frame_at(_sel_frame)


func _on_rebuild_sequence() -> void:
	if _data == null or _data.texture == null:
		_set_status("先选贴图，才能按格子重建序列", true)
		return
	var cells: int = _sheet.total_cells()
	var seq: Array[int] = []
	for i: int in range(cells):
		seq.append(i)
	_data.frame_sequence = seq
	_data.frame_offsets = []
	_data.frame_durations = []
	_sel_frame = 0
	_dirty = true
	_ensure_frame_arrays()
	_refresh_strip()
	_rebuild_preview()
	_update_title()
	_set_status("已按格子重建序列：%d 帧" % cells)


## 把当前帧的数据回填到参数 SpinBox（不回发信号）。
func _sync_frame_params_ui() -> void:
	if _data == null or _pat_spin == null:
		return
	var n: int = _data.frame_sequence.size()
	if _sel_frame < 0 or _sel_frame >= n:
		return
	_pat_spin.set_value_no_signal(_data.frame_sequence[_sel_frame])
	var offs: Array[Vector2] = _data.frame_offsets
	_fx_spin.set_value_no_signal(offs[_sel_frame].x if _sel_frame < offs.size() else 0.0)
	_fy_spin.set_value_no_signal(offs[_sel_frame].y if _sel_frame < offs.size() else 0.0)
	var durs: Array[float] = _data.frame_durations
	_dur_spin.set_value_no_signal(durs[_sel_frame] if _sel_frame < durs.size() else 0.0)
# ═══════════════════════════════════════
# 多格（cell）——对齐 VX Ace 帧视图
# ═══════════════════════════════════════
## 当前帧对应的 cell.frame_idx（运行时用 frame_sequence 的值匹配 cell，见 VXAnimSprite）。
func _frame_key() -> int:
	if _data == null or _data.frame_sequence.is_empty():
		return -1
	return _data.frame_sequence[clampi(_sel_frame, 0, _data.frame_sequence.size() - 1)]


func _cells_of_frame() -> Array:
	var out: Array = []
	if _data == null:
		return out
	var key: int = _frame_key()
	for cd in _data.cell_data:
		if cd.frame_idx == key:
			out.append(cd)
	return out


func _sync_overlay() -> void:
	if _overlay == null:
		return
	_overlay.center = Vector2(_preview_viewport.size) * 0.5
	_overlay.cell_size = _cell_size_px()
	_overlay.placing = _multi_check != null and _multi_check.button_pressed
	_overlay.cells = _cells_of_frame()
	if _overlay.selected >= _overlay.cells.size():
		_overlay.selected = -1
	_overlay.refresh()


func _cell_size_px() -> Vector2:
	if _data == null or _data.texture == null:
		return Vector2(192, 192)
	var tex := Vector2(_data.texture.get_size())
	var cols: int = maxi(1, _data.h_frames)
	var rows: int = _data.v_frames if _data.v_frames > 0 else maxi(1, int(ceil(tex.y / 192.0)))
	return Vector2(tex.x / float(cols), tex.y / float(rows))


func _on_multi_toggled(on: bool) -> void:
	if _data == null:
		return
	if on:
		_convert_to_multi()
	_sync_overlay()
	_rebuild_preview()
	_set_status("多格编辑：%s" % ("开（帧视图里点空白=放置当前图案，拖动=移动，右键=菜单）"
		if on else "关（只编辑每帧一个图案）"))


## 打开多格时，给还没有 cell 的帧补一个「图案=该帧图案、偏移=该帧偏移」的 cell，
## 保证画面与单格模式一致，不会突然空掉。
func _convert_to_multi() -> void:
	## 【为什么要把序列改成 0..N-1】运行时的 cell 是按 `frame_sequence[_seq_idx]` 的值
	## 匹配 `cell_data.frame_idx` 的。若两帧图案相同就会共用同一组 cell；改成 identity
	## 序列后「第 i 帧 = 第 i 组 cell」，与原图案的对应关系由 cell.pattern 保留，画面不变。
	var n: int = _data.frame_sequence.size()
	if n == 0:
		return
	if not _data.cell_data.is_empty():
		var seq_keep: Array[int] = []
		for i: int in range(n):
			seq_keep.append(i)
		_data.frame_sequence = seq_keep
		return
	var old_seq: Array[int] = _data.frame_sequence.duplicate()
	var old_offs: Array[Vector2] = _data.frame_offsets.duplicate()
	var cells: Array[VXAnimCellData] = []
	for i: int in range(n):
		var c := VXAnimCellData.new()
		c.frame_idx = i
		c.pattern = old_seq[i]
		c.offset = old_offs[i] if i < old_offs.size() else Vector2.ZERO
		cells.append(c)
	_data.cell_data = cells
	var seq: Array[int] = []
	for i: int in range(n):
		seq.append(i)
	_data.frame_sequence = seq
	_data.frame_offsets = []
	_dirty = true
func _on_overlay_empty_clicked(local_pos: Vector2) -> void:
	if _data == null or _multi_check == null or not _multi_check.button_pressed:
		return
	if _cells_of_frame().size() >= 16:
		_set_status("这一帧已经有 16 个 cell（VX 上限）", true)
		return
	var c := VXAnimCellData.new()
	c.frame_idx = _frame_key()
	c.pattern = _armed_pattern
	c.offset = (local_pos - Vector2(_preview_viewport.size) * 0.5).round()
	_data.cell_data.append(c)
	_dirty = true
	_sync_overlay()
	_rebuild_preview()
	_set_status("已放置 cell：图案 %d（最多 16 个）" % _armed_pattern)


func _on_overlay_empty_menu(_local_pos: Vector2, screen_pos: Vector2) -> void:
	if _multi_check == null or not _multi_check.button_pressed:
		return
	var menu := PopupMenu.new()
	menu.add_item("放置当前图案（%d）" % _armed_pattern, 0)
	menu.id_pressed.connect(func(_id: int) -> void:
		_on_overlay_empty_clicked(Vector2(_preview_viewport.size) * 0.5))
	menu.close_requested.connect(func() -> void: menu.queue_free())
	add_child(menu)
	menu.popup(Rect2i(Vector2i(screen_pos), Vector2i.ZERO))


func _on_cell_moved(_idx: int) -> void:
	_dirty = true
	## 拖动只需重画当前帧，不重建预览（重建会闪）。
	if _preview != null and is_instance_valid(_preview):
		_preview.call("_update_frame")
	_sync_overlay()


func _on_cell_menu_requested(idx: int, screen_pos: Vector2) -> void:
	var menu := PopupMenu.new()
	menu.add_item("cell 设置…", 0)
	menu.add_separator()
	menu.add_item("上移一层", 1)
	menu.add_item("下移一层", 2)
	menu.add_separator()
	menu.add_item("删除 cell", 3)
	var on_id := func(id: int) -> void:
		match id:
			0:
				_open_cell_settings(idx)
			1:
				_move_cell_priority(idx, 1)
			2:
				_move_cell_priority(idx, -1)
			3:
				_delete_cell(idx)
	menu.id_pressed.connect(on_id)
	menu.close_requested.connect(func() -> void: menu.queue_free())
	add_child(menu)
	menu.popup(Rect2i(Vector2i(screen_pos), Vector2i.ZERO))


func _open_cell_settings(idx: int) -> void:
	var list: Array = _cells_of_frame()
	if idx < 0 or idx >= list.size():
		return
	var cell: VXAnimCellData = list[idx]
	var dlg := ConfirmationDialog.new()
	dlg.title = "cell 设置 · 第 %d 个（层级 %d）" % [idx + 1, idx + 1]
	dlg.ok_button_text = "应用"
	var box := VBoxContainer.new()
	dlg.add_child(box)
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)

	grid.add_child(_label("图案（Pattern）"))
	var pat := _spin(0, 9999, 1, cell.pattern)
	pat.custom_minimum_size = Vector2(150, 0)
	grid.add_child(pat)
	grid.add_child(_label("X"))
	var px := _spin(-512, 512, 1, cell.offset.x)
	grid.add_child(px)
	grid.add_child(_label("Y"))
	var py := _spin(-512, 512, 1, cell.offset.y)
	grid.add_child(py)
	grid.add_child(_label("缩放 %（20~800）"))
	var zoom_spin := _spin(20, 800, 5, cell.scale.x * 100.0)
	grid.add_child(zoom_spin)
	grid.add_child(_label("角度（顺时针）"))
	var ang := _spin(0, 360, 1, cell.rotation_deg)
	grid.add_child(ang)
	grid.add_child(_label("不透明度（0~255）"))
	var op := _spin(0, 255, 1, cell.opacity * 255.0)
	grid.add_child(op)
	grid.add_child(_label("水平翻转"))
	var flip := CheckBox.new()
	flip.button_pressed = cell.flip_h
	grid.add_child(flip)
	grid.add_child(_label("合成方式"))
	var blend := OptionButton.new()
	blend.add_item("通常")
	blend.add_item("加算")
	blend.add_item("减算")
	blend.selected = clampi(cell.blend_mode, 0, 2)
	grid.add_child(blend)

	dlg.confirmed.connect(func() -> void:
		cell.pattern = int(pat.value)
		cell.offset = Vector2(px.value, py.value)
		var z: float = zoom_spin.value / 100.0
		cell.scale = Vector2(z, z)
		cell.rotation_deg = ang.value
		cell.opacity = op.value / 255.0
		cell.flip_h = flip.button_pressed
		cell.blend_mode = blend.selected
		_dirty = true
		_sync_overlay()
		_rebuild_preview()
		dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


func _delete_cell(idx: int) -> void:
	var list: Array = _cells_of_frame()
	if idx < 0 or idx >= list.size():
		return
	_data.cell_data.erase(list[idx])
	_dirty = true
	_sync_overlay()
	_rebuild_preview()


func _move_cell_priority(idx: int, delta: int) -> void:
	var list: Array = _cells_of_frame()
	var to: int = idx + delta
	if idx < 0 or idx >= list.size() or to < 0 or to >= list.size():
		return
	var a: int = _data.cell_data.find(list[idx])
	var c: int = _data.cell_data.find(list[to])
	if a < 0 or c < 0:
		return
	var tmp = _data.cell_data[a]
	_data.cell_data[a] = _data.cell_data[c]
	_data.cell_data[c] = tmp
	_dirty = true
	_overlay.selected = to
	_sync_overlay()
	_rebuild_preview()


# ═══════════════════════════════════════
# 预览
# ═══════════════════════════════════════
func _apply_preview_seek() -> void:
	if _preview != null and is_instance_valid(_preview) and not _playing:
		_preview.seek_sequence(_sel_frame)


func _rebuild_preview_if_needed() -> void:
	## 只改图案/序列不改变网格，可原地 seek；网格/贴图变化才重建。
	if _preview == null or not is_instance_valid(_preview):
		_rebuild_preview()


## 序列长度不变（只换某一帧的图案）时，把新数组灌进预览并跳到该帧。
## 预览实例的 `_total_frames` 是 `_ready` 时算的，**长度变化必须重建**（见调用处）。
func _sync_preview_sequence() -> void:
	if _data == null:
		return
	if _preview == null or not is_instance_valid(_preview):
		_rebuild_preview()
		return
	_preview.frame_sequence = _data.frame_sequence.duplicate()
	_preview.frame_durations = _data.frame_durations.duplicate()
	if not _playing:
		_preview.seek_sequence(_sel_frame)


func _free_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null


func _rebuild_preview() -> void:
	_free_preview()
	if _data == null or _data.texture == null:
		return
	var s := VXAnimSprite.new()
	s.texture = _data.texture
	s.h_frames = maxi(1, _data.h_frames)
	s.v_frames = maxi(0, _data.v_frames)
	s.fps = maxf(0.1, _fps_spin.value if _fps_spin != null else _data.fps)
	s.looping = _loop_check.button_pressed
	s.auto_free = false
	s.visible = true
	s.centered = _data.centered
	s.tone = _data.tone
	s.position = Vector2.ZERO
	s.position_offset = _data.position_offset
	s.animation_scale = _data.animation_scale
	s.animation_rotation = _data.animation_rotation
	s.frame_sequence = _data.frame_sequence.duplicate()
	var safe_durs: Array[float] = _data.frame_durations.duplicate()
	var fallback_dur: float = 1.0 / maxf(0.1, s.fps)
	for di: int in range(safe_durs.size()):
		if safe_durs[di] <= 0.0:
			safe_durs[di] = fallback_dur
	s.frame_durations = safe_durs
	s.frame_offsets = _data.frame_offsets.duplicate()
	s.cell_data = _data.cell_data.duplicate()
	_preview_root.add_child(s)
	s.visible = true
	_preview = s
	if _playing:
		s.restart_playback()
	else:
		s.set_playing(false)
		s.seek_sequence(_sel_frame)


## 预览区输入：拖动改当前帧偏移；右键弹帧菜单。
func _on_preview_gui_input(event: InputEvent) -> void:
	if _data == null or _data.frame_sequence.is_empty():
		return
	_ensure_frame_arrays()
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_on_frame_menu_requested(_sel_frame, Vector2(DisplayServer.mouse_get_position()))
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_preview_dragging = true
				_preview_drag_start = mb.position
				_preview_drag_origin = _data.frame_offsets[clampi(_sel_frame, 0, _data.frame_offsets.size() - 1)]
			else:
				_preview_dragging = false
		return
	if event is InputEventMouseMotion and _preview_dragging:
		var delta: Vector2 = (event as InputEventMouseMotion).position - _preview_drag_start
		_set_offset_at(_sel_frame, (_preview_drag_origin + delta).round())
		_sync_frame_params_ui()


func _toggle_play() -> void:
	if _preview == null or not is_instance_valid(_preview):
		_rebuild_preview()
		if _preview == null:
			return
	if _playing:
		_playing = false
		_preview.set_playing(false)
		_play_btn.text = "▶ 播放 (空格)"
	else:
		_playing = true
		_preview.restart_playback()
		_play_btn.text = "⏸ 暂停 (空格)"


# ═══════════════════════════════════════
# 贴图
# ═══════════════════════════════════════
func _on_pick_texture() -> void:
	if _data == null:
		return
	## 无类型：asset_browser 没有 class_name，静态检查看不到 picked/closed 信号。
	var browser = ASSET_BROWSER.new()
	add_child(browser)
	browser.picked.connect(func(path: String) -> void:
		var tex := load(path) as Texture2D
		if tex != null:
			_data.texture = tex
			_tex_label.text = path.get_file()
			_dirty = true
			## 只换贴图，**不**自动按格子建帧（用户要求）；帧由用户自己点格子或按「按格子重建序列」。
			_sheet.texture = tex
			_sheet.refresh()
			_set_status("已设置贴图 %s —— 点格子组帧，或按「按格子重建序列」" % path.get_file())
			_rebuild_preview()
			_update_title()
		browser.queue_free())
	browser.closed.connect(func() -> void: browser.queue_free())
	var current: String = _data.texture.resource_path if _data.texture != null else ""
	browser.open(0, current)


# ═══════════════════════════════════════
# 输入
# ═══════════════════════════════════════
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := event as InputEventKey
	if k.keycode == KEY_SPACE:
		_toggle_play()
		accept_event()
	elif k.keycode == KEY_LEFT:
		_step(-1)
		accept_event()
	elif k.keycode == KEY_RIGHT:
		_step(1)
		accept_event()
	elif k.keycode == KEY_S and k.ctrl_pressed:
		if k.shift_pressed:
			_on_save_as()
		else:
			_on_save()
		accept_event()


# ═══════════════════════════════════════
# 小工具
# ═══════════════════════════════════════
func _set_status(msg: String, warn: bool = false) -> void:
	if _status == null:
		return
	_status.text = msg
	_status.add_theme_color_override("font_color", C_WARN if warn else C_MUTED)


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _spin(min_v: float, max_v: float, step: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.update_on_text_changed = false
	s.custom_minimum_size = Vector2(72, 0)
	return s


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", C_MUTED)
	return l


func _vsep() -> VSeparator:
	return VSeparator.new()


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _flat_style(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(3)
	return sb
