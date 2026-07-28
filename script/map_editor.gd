extends Node2D
## 运行时图块编辑器 — 无需回到编辑器即可选图块、放置、切换图层
##
## 操作：
##   左侧调色板：左键点击选择图块 | 滚轮缩放调色板
##   地图区域：   左键放置图块 | 右键擦除
##   顶栏：       切换图层 | 加载图块 | 清除
##   WASD/滚轮/中键：和平移缩放一样

# ═══════════════════════════════════════
# 场景子节点
# ═══════════════════════════════════════
@onready var camera: Camera2D = $Camera2D
@onready var ground_layer: TileMapLayer = $GroundLayer
@onready var decor_layer: TileMapLayer = $DecorLayer

# ═══════════════════════════════════════
# 预设图块纹理（编辑器设置，运行时也可动态加载）
# ═══════════════════════════════════════
@export var preset_textures: Array[Texture2D] = []
@export var tile_size: int = 32
@export var grid_size: Vector2i = Vector2i(40, 30)

# ═══════════════════════════════════════
# 运行时状态
# ═══════════════════════════════════════
var _current_tileset: TileSet = null
var _current_texture: Texture2D = null
var _selected_tile: Vector2i = Vector2i(0, 0)
var _active_layer: TileMapLayer = null
var _palette_cols: int = 0
var _palette_rows: int = 0
var _palette_zoom: float = 1.0
var _dragging_map: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _cam_start: Vector2 = Vector2.ZERO

# ═══════════════════════════════════════
# UI 节点引用（在 _ready 中创建）
# ═══════════════════════════════════════
var _ui_layer: CanvasLayer = null
var _palette_control: Control = null
var _status_label: Label = null
var _layer_btn_ground: Button = null
var _layer_btn_decor: Button = null
var _tile_info_label: Label = null


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════

func _ready() -> void:
	_active_layer = ground_layer
	_create_ui()
	if preset_textures.size() > 0:
		_load_tileset_from_texture(preset_textures[0])
	_refresh_layer_buttons()
	print("图块编辑器就绪 | 顶栏[加载...]选择素材 | 左键放置 | 右键擦除")


# ═══════════════════════════════════════
# UI 构建
# ═══════════════════════════════════════

func _create_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "EditorUI"
	add_child(_ui_layer)
	_create_toolbar()
	_create_palette()
	_create_status_bar()


func _create_toolbar() -> void:
	var bar: Panel = _make_panel("Toolbar", Vector2(380, 44), Vector2(8, 8))
	_ui_layer.add_child(bar)

	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.name = "ToolButtons"
	hbox.position = Vector2(6, 6)
	hbox.add_theme_constant_override("separation", 4)
	bar.add_child(hbox)

	_layer_btn_ground = _make_button("地面层", _on_ground_btn)
	_layer_btn_decor = _make_button("装饰层", _on_decor_btn)
	hbox.add_child(_layer_btn_ground)
	hbox.add_child(_layer_btn_decor)

	var sep: ColorRect = ColorRect.new()
	sep.size = Vector2(1, 28)
	sep.color = Color(1, 1, 1, 0.2)
	hbox.add_child(sep)

	hbox.add_child(_make_button("加载...", _on_load_btn))
	hbox.add_child(_make_button("清除", _on_clear_btn))
	hbox.add_child(_make_button("保存.tres", _on_save_btn))


func _create_palette() -> void:
	var panel: Panel = _make_panel("PalettePanel", Vector2(272, 520), Vector2(8, 58))
	_ui_layer.add_child(panel)

	var title: Label = Label.new()
	title.name = "PaletteTitle"
	title.text = "图块调色板"
	title.position = Vector2(8, 6)
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	title.add_theme_font_size_override("font_size", 13)
	panel.add_child(title)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "PaletteScroll"
	scroll.size = Vector2(256, 440)
	scroll.position = Vector2(8, 26)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	_palette_control = Control.new()
	_palette_control.name = "PaletteDraw"
	_palette_control.mouse_filter = Control.MOUSE_FILTER_STOP
	var pscript: Script = load("res://script/palette_drawer.gd") as Script
	_palette_control.set_script(pscript)
	_palette_control.set("editor_ref", self)
	scroll.add_child(_palette_control)

	_tile_info_label = Label.new()
	_tile_info_label.name = "TileInfo"
	_tile_info_label.position = Vector2(8, 472)
	_tile_info_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	_tile_info_label.add_theme_font_size_override("font_size", 12)
	panel.add_child(_tile_info_label)


func _create_status_bar() -> void:
	var bar: Panel = _make_panel("StatusBar", Vector2(500, 26), Vector2(8, 584))
	_ui_layer.add_child(bar)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.position = Vector2(8, 4)
	_status_label.size = Vector2(484, 20)
	_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	_status_label.add_theme_font_size_override("font_size", 11)
	bar.add_child(_status_label)


func _make_panel(pname: String, psize: Vector2, ppos: Vector2) -> Panel:
	var p: Panel = Panel.new()
	p.name = pname
	p.size = psize
	p.position = ppos
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.1, 0.1, 0.15, 0.9)
	s.set_corner_radius_all(6)
	p.add_theme_stylebox_override("panel", s)
	return p


func _make_button(text: String, callback: Callable) -> Button:
	var btn: Button = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(50, 28)
	btn.pressed.connect(callback)
	return btn


# ═══════════════════════════════════════
# 调色板回调 — 由 palette_drawer.gd 调用
# ═══════════════════════════════════════

func _on_palette_draw(ctrl: Control) -> void:
	if not _current_texture:
		var font: Font = ThemeDB.fallback_font
		ctrl.draw_string(font, Vector2(20, 60),
			"未加载图块\n点击顶栏 [加载...]",
			HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color(1, 0.5, 0.5, 0.8))
		return

	var tex_w: int = _current_texture.get_width()
	var tex_h: int = _current_texture.get_height()
	_palette_cols = tex_w / tile_size
	_palette_rows = tex_h / tile_size

	var dst_rect: Rect2 = Rect2(0, 0, tex_w * _palette_zoom, tex_h * _palette_zoom)
	ctrl.draw_texture_rect(_current_texture, dst_rect, false)
	ctrl.custom_minimum_size = dst_rect.size

	var grid_c: Color = Color(1, 1, 1, 0.12)
	for x: int in range(1, _palette_cols):
		var lx: float = x * tile_size * _palette_zoom
		ctrl.draw_line(Vector2(lx, 0), Vector2(lx, tex_h * _palette_zoom), grid_c, 1.0)
	for y: int in range(1, _palette_rows):
		var ly: float = y * tile_size * _palette_zoom
		ctrl.draw_line(Vector2(0, ly), Vector2(tex_w * _palette_zoom, ly), grid_c, 1.0)

	var hl_rect: Rect2 = Rect2(
		_selected_tile.x * tile_size * _palette_zoom,
		_selected_tile.y * tile_size * _palette_zoom,
		tile_size * _palette_zoom,
		tile_size * _palette_zoom
	)
	ctrl.draw_rect(hl_rect, Color(1, 1, 0, 0.3), true)
	ctrl.draw_rect(hl_rect, Color.YELLOW, false, 2.0)

	if _palette_zoom > 0.6:
		var font: Font = ThemeDB.fallback_font
		for y: int in _palette_rows:
			for x: int in _palette_cols:
				var label: String = "%d,%d" % [x, y]
				var pos: Vector2 = Vector2(x * tile_size * _palette_zoom + 2, y * tile_size * _palette_zoom + 12)
				ctrl.draw_string(font, pos, label,
					HORIZONTAL_ALIGNMENT_LEFT, -1, max(8, int(9 * _palette_zoom)),
					Color(1, 1, 1, 0.4))


func _on_palette_input(event: InputEvent, _ctrl: Control) -> void:
	var mev: InputEventMouseButton = event as InputEventMouseButton
	if mev and mev.button_index == MOUSE_BUTTON_LEFT and mev.pressed:
		_pick_tile_from_palette(mev.position)
	elif mev and mev.button_index == MOUSE_BUTTON_WHEEL_UP:
		_palette_zoom = clamp(_palette_zoom * 1.2, 0.2, 4.0)
		_palette_control.queue_redraw()
	elif mev and mev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_palette_zoom = clamp(_palette_zoom / 1.2, 0.2, 4.0)
		_palette_control.queue_redraw()


func _pick_tile_from_palette(local_pos: Vector2) -> void:
	if not _current_texture:
		return
	var tx: int = int(local_pos.x / (tile_size * _palette_zoom))
	var ty: int = int(local_pos.y / (tile_size * _palette_zoom))
	if tx < 0 or tx >= _palette_cols or ty < 0 or ty >= _palette_rows:
		return
	_selected_tile = Vector2i(tx, ty)
	_palette_control.queue_redraw()
	_update_tile_info()
	print("选中图块: Vector2i(%d, %d)" % [tx, ty])


func _update_tile_info() -> void:
	if _tile_info_label:
		_tile_info_label.text = "选中: (%d, %d)" % [_selected_tile.x, _selected_tile.y]


# ═══════════════════════════════════════
# 图块加载
# ═══════════════════════════════════════

func _load_tileset_from_texture(tex: Texture2D) -> void:
	if not tex:
		return

	_current_texture = tex
	var ts: TileSet = TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)

	var source: TileSetAtlasSource = TileSetAtlasSource.new()
	source.texture = tex
	source.texture_region_size = Vector2i(tile_size, tile_size)

	var cols: int = tex.get_width() / tile_size
	var rows: int = tex.get_height() / tile_size

	for y: int in rows:
		for x: int in cols:
			source.create_tile(Vector2i(x, y))

	var _sid: int = ts.add_source(source)
	_current_tileset = ts

	if _active_layer:
		_active_layer.tile_set = ts
	if ground_layer and ground_layer.tile_set == null:
		ground_layer.tile_set = ts
	if decor_layer and decor_layer.tile_set == null:
		decor_layer.tile_set = ts

	_palette_cols = cols
	_palette_rows = rows
	_palette_zoom = clamp(256.0 / float(tex.get_width()), 0.3, 2.0)
	_selected_tile = Vector2i(0, 0)
	_palette_control.queue_redraw()
	_update_tile_info()
	_update_status()
	print("已加载: %s (%d×%d tiles)" % [tex.resource_path, cols, rows])


# ═══════════════════════════════════════
# 工具栏回调
# ═══════════════════════════════════════

func _on_ground_btn() -> void:
	_active_layer = ground_layer
	if _current_tileset:
		ground_layer.tile_set = _current_tileset
	_refresh_layer_buttons()
	_update_status()
	print("切换到: 地面层")


func _on_decor_btn() -> void:
	_active_layer = decor_layer
	if _current_tileset:
		decor_layer.tile_set = _current_tileset
	_refresh_layer_buttons()
	_update_status()
	print("切换到: 装饰层")


var _browser_panel: Panel = null
var _browser_preview: TextureRect = null
var _browser_file_list: ItemList = null
var _browser_info_label: Label = null
var _browser_selected_path: String = ""


func _on_load_btn() -> void:
	_show_tileset_browser()


func _show_tileset_browser() -> void:
	# 如果已有打开的浏览器，先关掉
	if _browser_panel:
		_browser_panel.queue_free()
		_browser_panel = null

	var panel: Panel = _make_panel("TilesetBrowser", Vector2(700, 480), Vector2(100, 60))
	_ui_layer.add_child(panel)
	_browser_panel = panel

	# 标题栏
	var title: Label = Label.new()
	title.text = "图块素材浏览器 — res://art/Tilesets/"
	title.position = Vector2(12, 8)
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	title.add_theme_font_size_override("font_size", 14)
	panel.add_child(title)

	# 关闭按钮（右上角 ×）
	var close_btn: Button = Button.new()
	close_btn.text = "×"
	close_btn.position = Vector2(666, 4)
	close_btn.custom_minimum_size = Vector2(28, 24)
	close_btn.pressed.connect(_on_browser_cancel)
	panel.add_child(close_btn)

	# 左侧文件列表
	_browser_file_list = ItemList.new()
	_browser_file_list.name = "FileList"
	_browser_file_list.size = Vector2(250, 390)
	_browser_file_list.position = Vector2(10, 34)
	_browser_file_list.allow_reselect = true
	_browser_file_list.item_selected.connect(_on_browser_item_selected)
	panel.add_child(_browser_file_list)

	# 右侧预览区域
	var preview_bg: Panel = Panel.new()
	preview_bg.name = "PreviewBG"
	preview_bg.size = Vector2(420, 310)
	preview_bg.position = Vector2(268, 34)
	var pstyle: StyleBoxFlat = StyleBoxFlat.new()
	pstyle.bg_color = Color(0.05, 0.05, 0.08, 0.8)
	pstyle.set_corner_radius_all(4)
	preview_bg.add_theme_stylebox_override("panel", pstyle)
	panel.add_child(preview_bg)

	_browser_preview = TextureRect.new()
	_browser_preview.name = "Preview"
	_browser_preview.size = Vector2(420, 280)
	_browser_preview.position = Vector2(268, 34)
	_browser_preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_browser_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	panel.add_child(_browser_preview)

	# 预览文件名标签
	_browser_info_label = Label.new()
	_browser_info_label.name = "PreviewInfo"
	_browser_info_label.position = Vector2(268, 318)
	_browser_info_label.size = Vector2(420, 24)
	_browser_info_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_browser_info_label.add_theme_font_size_override("font_size", 11)
	_browser_info_label.text = "点击左侧文件名预览"
	panel.add_child(_browser_info_label)

	# 底部按钮
	var btn_load: Button = Button.new()
	btn_load.text = "加载选中图块"
	btn_load.position = Vector2(490, 440)
	btn_load.custom_minimum_size = Vector2(120, 30)
	btn_load.pressed.connect(_on_browser_confirm)
	panel.add_child(btn_load)

	var btn_cancel: Button = Button.new()
	btn_cancel.text = "取消"
	btn_cancel.position = Vector2(620, 440)
	btn_cancel.custom_minimum_size = Vector2(60, 30)
	btn_cancel.pressed.connect(_on_browser_cancel)
	panel.add_child(btn_cancel)

	# 扫描目录
	_scan_tilesets_dir()


func _scan_tilesets_dir() -> void:
	var dir: DirAccess = DirAccess.open("res://art/Tilesets/")
	if not dir:
		print("[错误] 无法打开 art/Tilesets/ 目录")
		return

	var files: Array[String] = []
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".png"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	files.sort()
	for f: String in files:
		_browser_file_list.add_item(f)

	print("找到 %d 个图块文件" % files.size())


func _on_browser_item_selected(idx: int) -> void:
	var fname: String = _browser_file_list.get_item_text(idx)
	var path: String = "res://art/Tilesets/%s" % fname
	_browser_selected_path = path

	# 加载并显示预览
	var tex: Texture2D = load(path) as Texture2D
	if tex:
		_browser_preview.texture = tex
		var tw: int = tex.get_width()
		var th: int = tex.get_height()
		var tcols: int = tw / tile_size
		var trows: int = th / tile_size
		_browser_info_label.text = "%s  —  %d×%d px  |  %d×%d tiles" % [fname, tw, th, tcols, trows]
	else:
		_browser_preview.texture = null
		_browser_info_label.text = "%s  —  [加载失败]" % fname
		print("[错误] 无法加载预览: %s" % path)


func _on_browser_confirm() -> void:
	if _browser_selected_path.is_empty():
		print("[提示] 请先在左侧列表中选择一个文件")
		return
	var tex: Texture2D = load(_browser_selected_path) as Texture2D
	if tex:
		_load_tileset_from_texture(tex)
	_on_browser_cancel()


func _on_browser_cancel() -> void:
	if _browser_panel:
		_browser_panel.queue_free()
		_browser_panel = null
	_browser_file_list = null
	_browser_preview = null
	_browser_info_label = null
	_browser_selected_path = ""


func _on_clear_btn() -> void:
	if ground_layer:
		ground_layer.clear()
	if decor_layer:
		decor_layer.clear()
	_update_status()
	print("地图已清除")


func _on_save_btn() -> void:
	if not _current_tileset:
		print("[提示] 请先加载图块素材再保存")
		return

	var fd: FileDialog = FileDialog.new()
	fd.name = "SaveTilesetDialog"
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_RESOURCES
	fd.title = "保存 TileSet .tres"
	fd.set_filters(PackedStringArray(["*.tres ; Godot TileSet 资源"]))
	fd.current_file = "my_tileset.tres"
	fd.file_selected.connect(_on_save_path_selected.bind(fd))
	fd.canceled.connect(_on_save_dialog_cancel.bind(fd))
	add_child(fd)
	fd.popup_centered_ratio()


func _on_save_path_selected(path: String, dialog: FileDialog) -> void:
	dialog.queue_free()
	var err: int = ResourceSaver.save(_current_tileset, path)
	if err == OK:
		print("TileSet 已保存: %s" % path)
	else:
		push_error("保存失败: %s (error %d)" % [path, err])


func _on_save_dialog_cancel(dialog: FileDialog) -> void:
	dialog.queue_free()


func _refresh_layer_buttons() -> void:
	if _layer_btn_ground:
		_layer_btn_ground.button_pressed = (_active_layer == ground_layer)
	if _layer_btn_decor:
		_layer_btn_decor.button_pressed = (_active_layer == decor_layer)


func _update_status() -> void:
	if not _status_label:
		return
	var layer_name: String = "地面层" if _active_layer == ground_layer else "装饰层"
	var tile_count: int = _active_layer.get_used_cells().size() if _active_layer else 0
	_status_label.text = "图层: %s | 图块数: %d | 选中: (%d,%d) | WASD平移 滚轮缩放 左键放置 右键擦除" % [
		layer_name, tile_count, _selected_tile.x, _selected_tile.y
	]


# ═══════════════════════════════════════
# 地图交互
# ═══════════════════════════════════════

func _input(event: InputEvent) -> void:
	var mev: InputEventMouseButton = event as InputEventMouseButton
	if mev:
		if _is_mouse_in_palette(mev.position):
			return
		if _browser_panel and _browser_panel.is_visible_in_tree():
			return

		if mev.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_map(-0.1, mev.position)
		elif mev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_map(0.1, mev.position)
		elif mev.button_index == MOUSE_BUTTON_MIDDLE:
			if mev.pressed:
				_dragging_map = true
				_drag_start = mev.position
				_cam_start = camera.position
			else:
				_dragging_map = false
		elif mev.button_index == MOUSE_BUTTON_LEFT and mev.pressed:
			_place_tile_at_mouse(mev.position)
		elif mev.button_index == MOUSE_BUTTON_RIGHT and mev.pressed:
			_erase_tile_at_mouse(mev.position)

	if event is InputEventMouseMotion and _dragging_map:
		var delta: Vector2 = (event as InputEventMouseMotion).position - _drag_start
		camera.position = _cam_start - delta / camera.zoom


func _process(delta: float) -> void:
	var move_dir: Vector2 = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if move_dir != Vector2.ZERO:
		camera.position += move_dir * 600.0 * delta / camera.zoom


func _is_mouse_in_palette(screen_pos: Vector2) -> bool:
	if not _palette_control or not _palette_control.is_visible_in_tree():
		return false
	var pal_rect: Rect2 = _palette_control.get_global_rect()
	return pal_rect.has_point(screen_pos)


func _mouse_to_map(screen_pos: Vector2) -> Vector2i:
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var world: Vector2 = camera.global_position + (screen_pos - vs / 2) / camera.zoom
	return Vector2i(int(world.x / tile_size), int(world.y / tile_size))


func _place_tile_at_mouse(screen_pos: Vector2) -> void:
	if not _active_layer or not _current_tileset:
		print("[提示] 请先加载图块素材")
		return
	var cell: Vector2i = _mouse_to_map(screen_pos)
	_active_layer.set_cell(cell, 0, _selected_tile)
	_update_status()


func _erase_tile_at_mouse(screen_pos: Vector2) -> void:
	if not _active_layer:
		return
	var cell: Vector2i = _mouse_to_map(screen_pos)
	_active_layer.erase_cell(cell)
	_update_status()


func _zoom_map(amount: float, screen_pos: Vector2) -> void:
	var old_zoom: Vector2 = camera.zoom
	var new_zoom: Vector2 = Vector2(
		clamp(old_zoom.x + amount, 0.25, 4.0),
		clamp(old_zoom.y + amount, 0.25, 4.0),
	)
	if new_zoom == old_zoom:
		return
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var before: Vector2 = camera.global_position + (screen_pos - vs / 2) / old_zoom
	camera.zoom = new_zoom
	var after: Vector2 = camera.global_position + (screen_pos - vs / 2) / new_zoom
	camera.position += before - after


# ═══════════════════════════════════════
# 快捷 API
# ═══════════════════════════════════════

func switch_layer(layer_name: String) -> void:
	if layer_name == "ground":
		_on_ground_btn()
	elif layer_name == "decor":
		_on_decor_btn()


func set_tile(tx: int, ty: int) -> void:
	_selected_tile = Vector2i(tx, ty)
	_palette_control.queue_redraw()
	_update_tile_info()
