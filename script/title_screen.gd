extends Control
## 标题画面控制器 — RM2K3 风格窗口
##
## 文字颜色：TextGradientRenderer 通过 SubViewport 预渲染文字，
## CPU 端逐像素应用色表纵向渐变（上亮下暗）+ 可选描边。
## 支持阴影（暗色偏移）和粗体（1px 偏移叠加）。
##
## 操作：
##   上/下   → 移动光标
##   确定键  → 确认


const MENU_ITEMS: Array[String] = ["开始游戏", "联机游戏", "设置", "退出游戏"]
const WINDOW_TITLE: String = "のび太的求生之路"

# ═══════════════════════════════════════
# 布局参数
# ═══════════════════════════════════════

@export_group("窗口布局")
@export var window_size: Vector2 = Vector2(220, 158)
@export var window_y_offset: float = 130.0
@export var show_title: bool = false
@export var title_position: Vector2 = Vector2(14, 8)
@export var separator_y: float = 30.0
@export var panel_margin: float = 6.0

@export_group("选项布局")
@export var title_font_size: int = 16
@export var item_font_size: int = 16
@export var item_start_y: float = 20.0
@export var item_height: float = 28.0
@export var item_spacing: float = 16.0
@export var item_margin_bottom: float = 0.0
@export var item_title_gap: float = 12.0
@export var item_text_x: float = 3.0
@export var item_width: float = 0.0
@export var item_centered: bool = false

@export_group("文字颜色")
@export var text_color_index: int = 1:
	set(v):
		text_color_index = clampi(v, 0, 19)
@export var text_color_row: int = 0:
	set(v):
		text_color_row = clampi(v, 0, 3)
@export var text_title_color_index: int = 1:
	set(v):
		text_title_color_index = clampi(v, 0, 19)

@export_group("文字效果")
@export var text_bold: bool = true
@export var text_outline: bool = false
@export var text_outline_color: Color = Color.BLACK
@export var text_shadow: bool = true
@export var text_shadow_color: Color = Color(0, 0, 0, 0.6)
@export var text_shadow_offset: Vector2 = Vector2(2, 2)

@export_group("光标框")
@export var cursor_base_height: float = 32.0
@export var cursor_scale_y: float = 1.0:
	set(v):
		cursor_scale_y = maxf(0.5, snapped(v, 0.5))
@export var cursor_snap_to_item: bool = false
@export var cursor_padding_x: float = 24.0
@export var cursor_offset_x: float = 10.0
@export var cursor_offset_y: float = -3.0
@export var cursor_min_width: float = 64.0
@export var cursor_override_width: float = 94.0

@export_group("资源路径")
@export var font_path: String = "res://art/System/DotGothic16-Regular.ttf"
@export var bg_pattern_path: String = "res://art/System/Background pattern for menu screens (16 x 16).png"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"
@export var arrow_down_path: String = "res://art/System/arrow_down.png"
@export var arrow_up_path: String = "res://art/System/arrow_up.png"
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var color_shader_path: String = "res://shader/text_color.gdshader"
@export var campaign_select_scene: String = "res://scene/campaign_select.tscn"
@export var lobby_scene: String = "res://scene/lobby.tscn"


var _cursor_idx: int = 0
var _scroll_offset: int = 0
var _visible_items: int = 0

var _cursor_frame: NinePatchRect = null
var _scroll_arrow_down: TextureRect = null
var _scroll_arrow_up: TextureRect = null
var _gradient_labels: Array[GradientLabel] = []
var _title_gradient_label: GradientLabel = null

var _cursor_atlas: Array[AtlasTexture] = []
var _cursor_frame_idx: int = 0

var _color_img: Image = null

## 设置面板状态
var _in_settings: bool = false
var _settings_cursor_idx: int = 0
var _settings_labels: Array[GradientLabel] = []
var _settings_value_labels: Array[GradientLabel] = []
var _settings_bar_bg: Array[ColorRect] = []
var _settings_bar_fill: Array[ColorRect] = []
const SETTINGS_ITEMS: Array[String] = ["音乐音量", "音效音量", "固定朝向", "返回"]


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════

func _ready() -> void:
	_load_defaults_from_global()
	_color_img = Image.load_from_file(color_sheet_path)
	if _color_img:
		print("[标题画面] 色表已加载 %d×%d" % [_color_img.get_width(), _color_img.get_height()])
	else:
		printerr("[标题画面] 色表加载失败: %s" % color_sheet_path)
	# 将背景音乐路由到 Music 总线
	var bgm: AudioStreamPlayer = get_node_or_null("AudioStreamPlayer")
	if bgm:
		bgm.bus = "Music"
	_create_cursor_frames()
	_create_menu_window()
	_refresh_all()
	_start_cursor_blink()


func _load_defaults_from_global() -> void:
	var g = get_node_or_null("/root/Global")
	if not g:
		return
	if g.text_font_path != "":
		font_path = g.text_font_path
	if g.text_color_sheet_path != "":
		color_sheet_path = g.text_color_sheet_path
	if g.text_color_shader_path != "":
		color_shader_path = g.text_color_shader_path
	text_color_index = g.text_color_index
	text_color_row = g.text_color_row
	text_bold = g.text_bold
	text_outline = g.text_outline
	text_outline_color = g.text_outline_color
	text_shadow = g.text_shadow
	text_shadow_color = g.text_shadow_color
	text_shadow_offset = g.text_shadow_offset
	print("[标题画面] Global 同步 — 色表索引=%d 粗体=%s 描边=%s 阴影=%s" % [text_color_index, text_bold, text_outline, text_shadow])




func _input(event: InputEvent) -> void:
	if _in_settings:
		_handle_settings_input(event)
		return

	if event.is_action_pressed("确定键"):
		_confirm()
		return

	var item_count: int = MENU_ITEMS.size()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
	else:
		return

	if _cursor_idx < _scroll_offset:
		_scroll_offset = _cursor_idx
		_rebuild_menu_items()
	elif _cursor_idx >= _scroll_offset + _visible_items:
		_scroll_offset = _cursor_idx - _visible_items + 1
		_rebuild_menu_items()

	_refresh_all()


# ═══════════════════════════════════════
# 色表采样（CPU）
# ═══════════════════════════════════════

func _load_pixel_font(_base_size: int = 16) -> Font:
	var font_file: FontFile = load(font_path) as FontFile
	if not font_file:
		printerr("[标题画面] 无法加载字体: %s" % font_path)
		return ThemeDB.fallback_font
	return font_file


func _measure_text(text: String, font_size: int) -> Vector2:
	var font := _load_pixel_font(font_size)
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)


# ═══════════════════════════════════════
# 光标框
# ═══════════════════════════════════════

func _create_cursor_frames() -> void:
	var src: Texture2D = load(cursor_frame_path) as Texture2D
	if not src:
		return
	for i: int in range(2):
		var at := AtlasTexture.new()
		at.atlas = src
		at.region = Rect2(i * 64, 0, 64, 64)
		at.filter_clip = true
		_cursor_atlas.append(at)


func _start_cursor_blink() -> void:
	var timer := Timer.new()
	timer.name = "CursorBlinkTimer"
	timer.wait_time = 0.3
	timer.timeout.connect(_on_cursor_blink)
	add_child(timer)
	timer.start()


func _on_cursor_blink() -> void:
	if _cursor_atlas.is_empty() or not _cursor_frame:
		return
	_cursor_frame_idx = 1 - _cursor_frame_idx
	_cursor_frame.texture = _cursor_atlas[_cursor_frame_idx]


func _get_cursor_height() -> float:
	return cursor_base_height * cursor_scale_y


func _calc_cursor_width() -> float:
	if cursor_override_width > 0.0:
		return cursor_override_width
	var max_w: float = maxf(cursor_min_width, item_width)
	max_w = maxf(max_w, _calc_max_text_width())
	return max_w + cursor_padding_x


func _calc_max_text_width() -> float:
	var max_w: float = 0.0
	for item: String in MENU_ITEMS:
		var ts := _measure_text("  %s" % item, item_font_size)
		max_w = maxf(max_w, ts.x)
	return max_w


func _get_item_area_width() -> float:
	if item_width > 0.0:
		return item_width
	return _calc_max_text_width()


func _get_item_x() -> float:
	if not item_centered:
		return item_text_x
	return (window_size.x - _get_item_area_width()) / 2.0


# ═══════════════════════════════════════
# 窗口构建
# ═══════════════════════════════════════

func _create_menu_window() -> void:
	var win: Control = $MenuWindow

	win.position = Vector2(
		(1280.0 - window_size.x) / 2.0,
		(960.0 - window_size.y) / 2.0 + window_y_offset
	)
	win.size = window_size

	# 面板
	win.add_child(_make_window_panel())

	# 背景纹样
	var bg_pattern: Texture2D = load(bg_pattern_path) as Texture2D
	if bg_pattern:
		var bg_rect := TextureRect.new()
		bg_rect.name = "BgPattern"
		bg_rect.texture = bg_pattern
		bg_rect.stretch_mode = TextureRect.STRETCH_TILE
		bg_rect.size = window_size - Vector2(panel_margin * 2, panel_margin * 2)
		bg_rect.position = Vector2(panel_margin, panel_margin)
		bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bg_rect.modulate = Color(1, 1, 1, 0.12)
		win.add_child(bg_rect)

	# 标题（可选）
	if show_title:
		_title_gradient_label = _make_menu_gradient_label(WINDOW_TITLE, title_position, title_font_size, text_title_color_index)
		win.add_child(_title_gradient_label)

		var sep := ColorRect.new()
		sep.name = "Separator"
		sep.color = Color(0.5, 0.5, 0.7, 0.5)
		sep.size = Vector2(window_size.x - 32, 1)
		sep.position = Vector2(16, separator_y)
		win.add_child(sep)

	# 可见区域
	var start_y: float = separator_y + item_title_gap if show_title else item_start_y
	var avail_h: float = window_size.y - start_y - item_margin_bottom
	var row_step: float = item_height + item_spacing
	_visible_items = clampi(int(avail_h / row_step), 1, MENU_ITEMS.size())

	# 光标框
	if not _cursor_atlas.is_empty():
		var cur_w: float
		var cur_x: float
		if cursor_snap_to_item:
			cur_w = _get_item_area_width()
			cur_x = _get_item_x()
		else:
			cur_w = _calc_cursor_width()
			cur_x = item_text_x + cursor_offset_x
		var cur_h := _get_cursor_height()
		_cursor_frame = NinePatchRect.new()
		_cursor_frame.name = "CursorFrame"
		_cursor_frame.texture = _cursor_atlas[0]
		_cursor_frame.patch_margin_left = 20
		_cursor_frame.patch_margin_right = 20
		_cursor_frame.patch_margin_top = 20
		_cursor_frame.patch_margin_bottom = 20
		_cursor_frame.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_STRETCH
		_cursor_frame.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_STRETCH
		_cursor_frame.size = Vector2(cur_w, cur_h)
		_cursor_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_cursor_frame.position = Vector2(
			cur_x,
			item_start_y + (item_height - cur_h) / 2.0 + cursor_offset_y
		)
		win.add_child(_cursor_frame)

	# 菜单项
	_rebuild_menu_items()

	# 滚动箭头
	_create_scroll_arrow(win, arrow_down_path, "ScrollArrowDown",
		item_start_y + _visible_items * row_step + 4)
	_create_scroll_arrow(win, arrow_up_path, "ScrollArrowUp",
		item_start_y - 16)


func _create_scroll_arrow(parent: Control, path: String, pname: String, pos_y: float) -> void:
	var tex: Texture2D = load(path) as Texture2D
	if not tex:
		return
	var arrow := TextureRect.new()
	arrow.name = pname
	arrow.texture = tex
	arrow.size = tex.get_size()
	arrow.position = Vector2((window_size.x - tex.get_size().x) / 2.0, pos_y)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.hide()
	parent.add_child(arrow)
	if pname == "ScrollArrowDown":
		_scroll_arrow_down = arrow
	else:
		_scroll_arrow_up = arrow


func _rebuild_menu_items() -> void:
	_clear_gradient_labels()

	var win := get_node("MenuWindow")
	var end_idx: int = mini(_scroll_offset + _visible_items, MENU_ITEMS.size())
	for i: int in range(_scroll_offset, end_idx):
		var display_idx: int = i - _scroll_offset
		var text := "  %s" % MENU_ITEMS[i]
		var pos := Vector2(_get_item_x(), item_start_y + display_idx * (item_height + item_spacing))
		var gl := _make_menu_gradient_label(text, pos, item_font_size, text_color_index)
		if item_width > 0.0:
			gl.size.x = item_width
		win.add_child(gl)
		_gradient_labels.append(gl)

	_update_scroll_arrows()


func _make_menu_gradient_label(label_text: String, pos: Vector2, font_size: int, color_idx: int) -> GradientLabel:
	var gl := GradientLabel.new()
	gl.text = label_text
	gl.position = pos
	gl.text_font_size = font_size
	gl.color_index = color_idx
	gl.color_row = text_color_row
	gl.use_gradient = true
	gl.bold = text_bold
	gl.shadow = text_shadow
	gl.shadow_color = text_shadow_color
	gl.shadow_offset = text_shadow_offset
	gl.outline = text_outline
	gl.outline_color = text_outline_color
	gl.font_path_override = font_path
	gl.color_sheet_path_override = color_sheet_path
	gl.color_shader_path_override = color_shader_path
	if _color_img:
		gl.set_color_image(_color_img)
	return gl


func _clear_gradient_labels() -> void:
	for gl in _gradient_labels:
		if is_instance_valid(gl):
			gl.queue_free()
	_gradient_labels.clear()


func _update_scroll_arrows() -> void:
	if _scroll_arrow_down:
		_scroll_arrow_down.visible = (_scroll_offset + _visible_items < MENU_ITEMS.size())
	if _scroll_arrow_up:
		_scroll_arrow_up.visible = (_scroll_offset > 0)


func _make_window_panel() -> Panel:
	var p := Panel.new()
	p.name = "WindowPanel"
	p.size = window_size
	p.position = Vector2.ZERO

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.02, 0.08, 0.90)
	style.border_width_left = 3
	style.border_width_right = 3
	style.border_width_top = 3
	style.border_width_bottom = 3
	style.border_color = Color(0.30, 0.30, 0.50, 0.85)

	p.add_theme_stylebox_override("panel", style)
	return p


# ═══════════════════════════════════════
# 交互
# ═══════════════════════════════════════

func _refresh_all() -> void:
	_refresh_cursor_frame()
	_update_scroll_arrows()


func _refresh_cursor_frame() -> void:
	if not _cursor_frame:
		return
	var display_idx: int = _cursor_idx - _scroll_offset
	var cur_h := _cursor_frame.size.y
	_cursor_frame.position.y = item_start_y + display_idx * (item_height + item_spacing) + (item_height - cur_h) / 2.0 + cursor_offset_y


func _confirm() -> void:
	match MENU_ITEMS[_cursor_idx]:
		"开始游戏":
			_go_to_campaign_select()
		"联机游戏":
			_go_to_lobby()
		"设置":
			_enter_settings()
		"退出游戏":
			_quit_game()


# ═══════════════════════════════════════
# 设置面板
# ═══════════════════════════════════════

func _enter_settings() -> void:
	_in_settings = true
	_settings_cursor_idx = 0
	_clear_gradient_labels()
	_build_settings_items()
	_refresh_settings_cursor()


func _exit_settings() -> void:
	_in_settings = false
	_clear_settings_ui()
	_rebuild_menu_items()
	_refresh_all()


func _build_settings_items() -> void:
	var win: Control = $MenuWindow
	var row_step: float = item_height + item_spacing
	var start_y: float = item_start_y
	var label_x: float = _get_item_x()
	var bar_x: float = label_x + _measure_text("  音乐音量", item_font_size).x + 8.0
	var bar_w: float = 80.0
	var bar_h: float = 12.0

	for i: int in range(SETTINGS_ITEMS.size()):
		var pos_y: float = start_y + i * row_step
		var text: String = SETTINGS_ITEMS[i]

		var gl := _make_menu_gradient_label("  %s" % text, Vector2(label_x, pos_y), item_font_size, text_color_index)
		win.add_child(gl)
		_settings_labels.append(gl)

		if i < 2:
			# 音量条：背景 + 填充 + 百分比标签
			var bar_y: float = pos_y + (item_height - bar_h) / 2.0

			var bg := ColorRect.new()
			bg.name = "VolBarBg%d" % i
			bg.color = Color(0.15, 0.15, 0.15, 0.8)
			bg.size = Vector2(bar_w, bar_h)
			bg.position = Vector2(bar_x, bar_y)
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			win.add_child(bg)
			_settings_bar_bg.append(bg)

			var fill := ColorRect.new()
			fill.name = "VolBarFill%d" % i
			fill.color = Color(0.30, 0.30, 0.60, 0.9)
			fill.size = Vector2(bar_w, bar_h)
			fill.position = Vector2(bar_x, bar_y)
			fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			win.add_child(fill)
			_settings_bar_fill.append(fill)

			var pct_label := _make_menu_gradient_label("", Vector2(bar_x + bar_w + 6, pos_y), item_font_size, text_color_index)
			win.add_child(pct_label)
			_settings_value_labels.append(pct_label)
		elif i == 2:
			# 固定朝向模式标签
			var mode_text: String = "切换式" if Global.facing_lock_mode == 0 else "按住式"
			var mode_label := _make_menu_gradient_label(mode_text, Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(mode_label)
			_settings_value_labels.append(mode_label)
		else:
			# "返回" — 无额外控件
			_settings_value_labels.append(null)

	_update_all_settings_volume_display()


func _clear_settings_ui() -> void:
	for gl in _settings_labels:
		if is_instance_valid(gl):
			gl.queue_free()
	_settings_labels.clear()
	for vl in _settings_value_labels:
		if is_instance_valid(vl):
			vl.queue_free()
	_settings_value_labels.clear()
	for bg in _settings_bar_bg:
		if is_instance_valid(bg):
			bg.queue_free()
	_settings_bar_bg.clear()
	for fg in _settings_bar_fill:
		if is_instance_valid(fg):
			fg.queue_free()
	_settings_bar_fill.clear()


func _handle_settings_input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		_exit_settings()
		return

	var item_count: int = SETTINGS_ITEMS.size()
	if event.is_action_pressed("上"):
		_settings_cursor_idx = (_settings_cursor_idx - 1 + item_count) % item_count
		_refresh_settings_cursor()
		return
	if event.is_action_pressed("下"):
		_settings_cursor_idx = (_settings_cursor_idx + 1) % item_count
		_refresh_settings_cursor()
		return

	if event.is_action_pressed("确定键"):
		match _settings_cursor_idx:
			2:  # 固定朝向
				var new_mode: int = 1 if Global.facing_lock_mode == 0 else 0
				Global.set_facing_lock_mode(new_mode)
				var mode_text: String = "切换式" if new_mode == 0 else "按住式"
				if _settings_value_labels[2]:
					_settings_value_labels[2].text = mode_text
			3:  # 返回
				_exit_settings()
		return

	# 左/右 调音量
	var delta_vol: int = 0
	if event.is_action_pressed("左"):
		delta_vol = -5
	elif event.is_action_pressed("右"):
		delta_vol = 5
	else:
		return

	match _settings_cursor_idx:
		0:  # 音乐音量
			Global.set_music_volume(clampi(Global.music_volume + delta_vol, 0, 100))
			_update_settings_volume_display(0)
		1:  # 音效音量
			Global.set_sfx_volume(clampi(Global.sfx_volume + delta_vol, 0, 100))
			_update_settings_volume_display(1)


func _refresh_settings_cursor() -> void:
	if not _cursor_frame:
		return
	var cur_h := _cursor_frame.size.y
	_cursor_frame.position.y = item_start_y + _settings_cursor_idx * (item_height + item_spacing) + (item_height - cur_h) / 2.0 + cursor_offset_y


func _update_settings_volume_display(idx: int) -> void:
	var vol: int = Global.music_volume if idx == 0 else Global.sfx_volume
	if idx < _settings_value_labels.size() and _settings_value_labels[idx]:
		_settings_value_labels[idx].text = "%d%%" % vol
	if idx < _settings_bar_fill.size() and _settings_bar_fill[idx]:
		var bar_w: float = 80.0
		_settings_bar_fill[idx].size.x = bar_w * vol / 100.0


func _update_all_settings_volume_display() -> void:
	_update_settings_volume_display(0)
	_update_settings_volume_display(1)


func _go_to_campaign_select() -> void:
	print("[标题画面] 开始游戏 → 战役选择")
	var err: Error = get_tree().change_scene_to_file(campaign_select_scene)
	if err != OK:
		printerr("[标题画面] 场景切换失败: %s (err=%d)" % [campaign_select_scene, err])


func _go_to_lobby() -> void:
	print("[标题画面] 联机游戏 → 大厅")
	var err: Error = get_tree().change_scene_to_file(lobby_scene)
	if err != OK:
		printerr("[标题画面] 大厅场景切换失败: %s (err=%d)" % [lobby_scene, err])


func _quit_game() -> void:
	print("[标题画面] 退出游戏")
	get_tree().quit()
