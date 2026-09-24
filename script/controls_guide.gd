extends Control

## ── 架构定位 ──
## 系统：操作说明 ｜ 层：表现（Control，独立场景，标题菜单进入）
## 联机：不涉及
## 职责：RM 窗口（角色选择/选择战役同款 WindowBg+WindowFrame）内滚动展示操作说明；
##       内容单一来源 = 工程根「操作说明.txt」（txt 也随发布带出，两处不会不同步）。
##       键位行画像素键帽图标（代码绘制，无额外素材）；↑↓ 滚动，Z/Esc 返回标题。
## 依赖：Global（字体/色表/阴影）、PanoramaBackdrop

const TITLE_SCENE := "res://scene/title_screen.tscn"
const GUIDE_TXT_PATH := "res://操作说明.txt"

const BACKDROP_PATH := "res://art/Panorama/地下.png"
const WINDOW_BG_PATH := "res://art/System/Window background color.png"
const WINDOW_FRAME_PATH := "res://art/System/Window frame.png"
const COLOR_SHEET_PATH := "res://art/System/Text color, 20 types (each 16 x 16).png"

const COLOR_SHEET_UID := "uid://b0colwtfjbllj"

@export var window_size: Vector2 = Vector2(960, 840)
@export var scroll_speed: float = 420.0        ## ↑↓ 按住时的滚动速度（px/s）
@export var section_gap: float = 18.0          ## 段落标题上方的额外间距
@export var keycap_min_size: Vector2 = Vector2(40, 28)

var _content: Control = null
var _scroll_y: float = 0.0
var _font: Font = null
var _color_img: Image = null
var _text_color_index: int = 1
var _text_color_row: int = 0
var _accent_color_index: int = 5
var _accent_color_row: int = 1


func _ready() -> void:
	Global.play_lobby_music()   # 与战役/角色选择共用大厅 BGM（切界面不中断）
	var g: Node = get_node_or_null("/root/Global")
	if g:
		## 字体（2026-09-24）：统一走 Global —— 跟随「设置 → 界面字体」。
		## 旧实现硬编码 ark-pixel-16px（实测缺字 1513/1733，绝大多数中文会走系统字体）。
		_font = g.get_ui_font() if g.has_method("get_ui_font") else g.get_text_font(16)
		var sheet_path: String = g.text_color_sheet_path if g.text_color_sheet_path != "" else COLOR_SHEET_PATH
		var sheet := load(sheet_path) as Texture2D
		_color_img = sheet.get_image() if sheet else null
		_text_color_index = g.text_color_index
		_text_color_row = g.text_color_row
	if _font == null:
		_font = ThemeDB.fallback_font
	_build_backdrop()
	_build_window()


## 下滚全景背景（角色选择同款），垫底。
func _build_backdrop() -> void:
	if ResourceLoader.exists(BACKDROP_PATH):
		var backdrop := PanoramaBackdrop.new()
		backdrop.texture_path = BACKDROP_PATH
		backdrop.bg_scale = 2.0
		backdrop.scroll_speed = 20.0
		backdrop.dim_alpha = 0.45
		add_child(backdrop)
		move_child(backdrop, 0)


func _build_window() -> void:
	var win := Control.new()
	win.name = "MenuWindow"
	win.size = window_size
	win.position = ((get_viewport_rect().size - window_size) * 0.5).floor()
	add_child(win)

	var bg_tex: Texture2D = load(WINDOW_BG_PATH) as Texture2D
	if bg_tex:
		var bg := TextureRect.new()
		bg.texture = bg_tex
		# 渐变底图整体拉伸（默认 STRETCH_SCALE），不平铺——渐变条平铺会出色带
		bg.size = window_size
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		win.add_child(bg)

	var frame_tex: Texture2D = load(WINDOW_FRAME_PATH) as Texture2D
	if frame_tex:
		var frame := NinePatchRect.new()
		frame.texture = frame_tex
		frame.patch_margin_left = 20
		frame.patch_margin_top = 20
		frame.patch_margin_right = 20
		frame.patch_margin_bottom = 20
		frame.size = window_size
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		win.add_child(frame)

	# 标题 + 分隔线（角色选择同款）
	var title := _make_label("操作说明", 32, _text_color_index, _text_color_row, true)
	title.position = Vector2(28, 14)
	win.add_child(title)
	var sep := ColorRect.new()
	sep.color = Color(0.5, 0.5, 0.7, 0.5)
	sep.position = Vector2(20, 56)
	sep.size = Vector2(window_size.x - 40, 2)
	win.add_child(sep)

	# 滚动裁剪区
	var clip := Control.new()
	clip.name = "ScrollClip"
	clip.position = Vector2(24, 68)
	clip.size = Vector2(window_size.x - 48, window_size.y - 68 - 44)
	clip.clip_contents = true
	win.add_child(clip)

	# 内容容器：VBox 自动排版（2026-09-14 修复手算行高导致的文字重叠），
	# 滚动 = 平移本容器；高度由 VBox 依据子项实际布局自行计算。
	var flow := VBoxContainer.new()
	flow.name = "Content"
	flow.position = Vector2(6, 8)
	flow.size = Vector2(clip.size.x - 12, 0)
	flow.add_theme_constant_override("separation", 6)
	clip.add_child(flow)
	_content = flow

	_parse_and_build(GUIDE_TXT_PATH)

	# 底部提示
	var hint := _make_label("↑↓ 滚动    Z / Esc 返回", 16, _text_color_index, _text_color_row, true)
	hint.position = Vector2(24, window_size.y - 36)
	win.add_child(hint)


## 解析 txt 并构建行内容（VBox 自动排版）。行类型：
##   【xxx】 → 段落标题（强调色）；[KEY] desc → 键帽行；· xxx → 普通行；
##   ==== 装饰线与首行大标题 → 跳过；空行 → 小间隔。
func _parse_and_build(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("[操作说明] 读取失败: %s" % path)
		var err_line := _make_plain_label("操作说明文件缺失：%s" % path, 860.0)
		_content.add_child(err_line)
		return
	var first_content_skipped := false
	while not f.eof_reached():
		var raw: String = f.get_line()
		var line: String = raw.strip_edges()
		if line.is_empty():
			_content.add_child(_make_spacer(8.0))
			continue
		if line.begins_with("="):
			continue
		if not first_content_skipped:
			first_content_skipped = true  # 首行大标题（窗口已有自己的标题）
			continue
		if line.begins_with("【"):
			_content.add_child(_make_spacer(section_gap))
			var head := _make_label(line, 20, _accent_color_index, _accent_color_row, true)
			_content.add_child(head)
		elif line.begins_with("["):
			var close := line.find("]")
			if close > 1:
				_content.add_child(_build_keycap_row(
					line.substr(1, close - 1).strip_edges(),
					line.substr(close + 1).strip_edges()))
			else:
				_content.add_child(_make_plain_label(line, _content_width()))
		elif line.begins_with("·"):
			_content.add_child(_make_plain_label(line.substr(1).strip_edges(), _content_width()))
		else:
			_content.add_child(_make_plain_label(line, _content_width()))


func _content_width() -> float:
	var flow := _content as VBoxContainer
	return flow.size.x if flow.size.x > 0.0 else 860.0


func _make_spacer(h: float) -> Control:
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, h)
	return sp


## 普通文本行：显式宽度 + 自动换行（VBox 依实际高度堆叠，不再手算行数）。
func _make_plain_label(text: String, width: float) -> Label:
	var lbl := _make_label(text, 16, _text_color_index, _text_color_row, false)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(maxf(width - 8.0, 100.0), 0)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lbl


func _build_keycap_row(key_text: String, desc: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	for token: String in key_text.split(" 或 "):
		var t := token.strip_edges()
		if t.is_empty():
			continue
		row.add_child(_make_keycap(t))

	if not desc.is_empty():
		var lbl := _make_label(desc, 16, _text_color_index, _text_color_row, false)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lbl)
	return row


## 像素键帽：深色底 + 浅色描边（StyleBoxFlat），中央字母/符号。
func _make_keycap(cap_text: String) -> Control:
	var cap := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.13, 0.18, 0.95)
	style.border_color = Color(0.75, 0.75, 0.85, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(3)
	cap.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.text = cap_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if _font:
		lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", 16)  ## ark-16 基底整倍渲染
	lbl.add_theme_color_override("font_color", Color(0.92, 0.92, 0.98))
	cap.add_child(lbl)

	var text_w: float = _font.get_string_size(cap_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x if _font else 30.0
	var w: float = maxf(keycap_min_size.x, text_w + 14.0)
	cap.custom_minimum_size = Vector2(w, keycap_min_size.y)
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	return cap


## 普通 Label（自动换行走不了 GradientLabel 单行渐变），补字体 + 色表着色 + 阴影。
func _make_label(text: String, font_size: int, color_index: int, color_row: int, bold: bool) -> Label:
	var lbl := Label.new()
	lbl.text = text
	GradientLabel.style_plain_label(lbl, _color_img, color_index, color_row, _font, font_size)
	if _font:
		lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _process(delta: float) -> void:
	if _content == null:
		return
	var view_h: float = (_content.get_parent() as Control).size.y
	var max_scroll: float = maxf(0.0, _content.size.y - view_h)
	var dir: float = 0.0
	if Input.is_action_pressed("上"):
		dir -= 1.0
	if Input.is_action_pressed("下"):
		dir += 1.0
	_scroll_y = clampf(_scroll_y + dir * scroll_speed * delta, 0.0, max_scroll)
	_content.position.y = -_scroll_y


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("确定键") or event.is_action_pressed("取消键"):
		get_viewport().set_input_as_handled()
		# 回标题前停掉大厅 BGM，让位标题画面自己的音乐（与 campaign_select._go_back 同款）
		Global.stop_lobby_music()
		var err: Error = get_tree().change_scene_to_file(TITLE_SCENE)
		if err != OK:
			printerr("[操作说明] 返回标题失败: %d" % err)
