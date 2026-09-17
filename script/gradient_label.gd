@tool
class_name GradientLabel
extends Control

## ── 架构定位 ──
## 系统：文字渲染 ｜ 层：表现（Control, @tool）
## 联机：不涉及
## 职责：统一文字节点：像素字体 + 固定色（色表取色）+ 阴影，粗体 = 1px 叠加、可选描边。
## 依赖：Global 默认参数（字体路径 / 色表 / 颜色与阴影默认值）
##
## 【历史】类名 GradientLabel 沿用旧称（大量场景与代码引用，改名得不偿失）。
## 旧版的色表纵向渐变纹理（TextGradientRenderer）与 text_color.gdshader 平色着色
## 已于 2026-09-11 按用户要求整体移除 —— 全部文字统一为「像素字体 + 阴影」。

# ═══════════════════════════════════════
# 脚本默认值（「仍等于默认值」≈「未显式指定」，这类属性才从 Global 继承）
# ═══════════════════════════════════════
const DEFAULT_COLOR_INDEX: int = 0
const DEFAULT_COLOR_ROW: int = 0
const DEFAULT_BOLD: bool = false
const DEFAULT_OUTLINE: bool = false
const DEFAULT_OUTLINE_COLOR: Color = Color.BLACK
const DEFAULT_SHADOW: bool = false
const DEFAULT_SHADOW_COLOR: Color = Color(0, 0, 0, 1)  ## 实心黑影（用户 2026-09-11 参考图定稿）
const DEFAULT_SHADOW_OFFSET: Vector2 = Vector2(2, 2)

# ═══════════════════════════════════════
# 核心属性
# ═══════════════════════════════════════
@export var text: String = "":
	set(v):
		text = v
		_request_render()

@export var text_font_size: int = 16:
	set(v):
		text_font_size = v
		_font_dirty = true
		_request_render()

@export var color_index: int = DEFAULT_COLOR_INDEX:
	set(v):
		color_index = clampi(v, 0, 19)
		_request_render()

@export var color_row: int = DEFAULT_COLOR_ROW:
	set(v):
		color_row = clampi(v, 0, 3)
		_color_dirty = true
		_request_render()

# ═══════════════════════════════════════
# 文字效果
# ═══════════════════════════════════════
@export var bold: bool = DEFAULT_BOLD:
	set(v):
		bold = v
		_request_render()

@export var shadow: bool = DEFAULT_SHADOW:
	set(v):
		shadow = v
		_request_render()

@export var shadow_color: Color = DEFAULT_SHADOW_COLOR:
	set(v):
		shadow_color = v
		_request_render()

@export var shadow_offset: Vector2 = DEFAULT_SHADOW_OFFSET:
	set(v):
		shadow_offset = v
		_request_render()

@export var outline: bool = DEFAULT_OUTLINE:
	set(v):
		outline = v
		_request_render()

@export var outline_color: Color = DEFAULT_OUTLINE_COLOR:
	set(v):
		outline_color = v
		_request_render()

# ═══════════════════════════════════════
# 资源路径（留空 = 从 Global 继承）
# ═══════════════════════════════════════
@export var font_path_override: String = "":
	set(v):
		font_path_override = v
		_resolve_paths()      ## 立即重解析，编辑器里换字体即时生效（2026-09-14）
		_font_dirty = true
		_request_render()

@export var color_sheet_path_override: String = "":
	set(v):
		color_sheet_path_override = v
		_resolve_paths()
		_color_dirty = true
		_request_render()

# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var _label_shadow: Label = null
var _label_bold: Label = null
var _label_main: Label = null

var _dirty: bool = false
var _properties_initialized: bool = false

var _font: Font = null
var _font_dirty: bool = true
var _color_img: Image = null
var _color_dirty: bool = true

var _resolved_font_path: String = ""
var _resolved_color_sheet_path: String = ""

## 共享色表 Image（外部设置可避免每个实例重复读盘）
var _shared_color_img: Image = null


# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════
func _enter_tree() -> void:
	if not _properties_initialized:
		_load_defaults_from_global()
		_properties_initialized = true
	_resolve_paths()
	_ensure_children()
	_request_render()


# ═══════════════════════════════════════
# 公开方法
# ═══════════════════════════════════════
## 设置共享色表 Image，避免每个 GradientLabel 重复加载
func set_color_image(img: Image) -> void:
	_shared_color_img = img
	_color_dirty = true
	_request_render()


# ═══════════════════════════════════════
# 默认值同步 / 路径解析
# ═══════════════════════════════════════
## 从 Global 补齐「未显式指定」的样式；显式设置过的值优先。
## 场景属性先写入、_enter_tree() 后才读 Global，无脑覆盖会抹掉 .tscn 里的显式设置。
func _load_defaults_from_global() -> void:
	var g := _get_global()
	if not g:
		return
	if color_index == DEFAULT_COLOR_INDEX:      color_index = g.text_color_index
	if color_row == DEFAULT_COLOR_ROW:          color_row = g.text_color_row
	if bold == DEFAULT_BOLD:                    bold = g.text_bold
	if outline == DEFAULT_OUTLINE:              outline = g.text_outline
	if shadow == DEFAULT_SHADOW:                shadow = g.text_shadow
	if outline_color == DEFAULT_OUTLINE_COLOR:  outline_color = g.text_outline_color
	if shadow_color == DEFAULT_SHADOW_COLOR:    shadow_color = g.text_shadow_color
	if shadow_offset == DEFAULT_SHADOW_OFFSET:  shadow_offset = g.text_shadow_offset


func _resolve_paths() -> void:
	var g := _get_global()
	var g_font := ""
	var g_sheet := ""
	if g:
		g_font = g.text_font_path
		g_sheet = g.text_color_sheet_path

	_resolved_font_path = font_path_override if not font_path_override.is_empty() else g_font
	_resolved_color_sheet_path = color_sheet_path_override if not color_sheet_path_override.is_empty() else g_sheet


# ═══════════════════════════════════════
# 子节点管理
# ═══════════════════════════════════════
func _ensure_children() -> void:
	if not _label_main:
		_label_main = Label.new()
		_label_main.name = "LabelMain"
		_label_main.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_label_main)
	if not _label_bold:
		_label_bold = Label.new()
		_label_bold.name = "LabelBold"
		_label_bold.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_label_bold)
	if not _label_shadow:
		_label_shadow = Label.new()
		_label_shadow.name = "LabelShadow"
		## 只垫在主文字后面：show_behind_parent 把阴影画在本节点之前、
		## 又不参与 CanvasLayer 的全局 z 排序 —— 之前用 z_index=-1 会让阴影
		## 排到整层 z=0 节点（窗口背景/面板）之后，窗口内文字的阴影全部被吞。
		_label_shadow.show_behind_parent = true
		_label_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_label_shadow)


# ═══════════════════════════════════════
# 渲染（同步重建；旧版异步渐变渲染的「取消不重排」问题随渐变一起消失）
# ═══════════════════════════════════════
func _request_render() -> void:
	if not is_inside_tree():
		return
	_dirty = true
	call_deferred("_rebuild")


func _rebuild() -> void:
	if not _dirty:
		return
	_dirty = false
	_ensure_children()

	if text.is_empty():
		_hide_all()
		return

	_load_resources()
	_render_plain()


## 资源加载：字体 + 色表 Image（仅用于取色）
func _load_resources() -> void:
	if _font_dirty:
		_font = null
		if not _resolved_font_path.is_empty():
			var ff := load(_resolved_font_path) as FontFile
			if ff:
				_font = ff
			else:
				printerr("[GradientLabel] 字体加载失败: %s" % _resolved_font_path)
		if not _font:
			_font = ThemeDB.fallback_font
		_font_dirty = false

	if _color_dirty:
		_color_img = null
		if _shared_color_img:
			_color_img = _shared_color_img
		elif not _resolved_color_sheet_path.is_empty():
			var g := _get_global()
			if g and g.has_method("get_cached_color_image") and g.text_color_sheet_path == _resolved_color_sheet_path:
				_color_img = g.get_cached_color_image()
			if not _color_img:
				_color_img = Image.load_from_file(_resolved_color_sheet_path)
			if _color_img == null:
				printerr("[GradientLabel] 色表加载失败: %s" % _resolved_color_sheet_path)
		_color_dirty = false


## 渲染：像素字体 + 固定色 + 阴影
## 【粗体已废弃】ark-pixel 没有粗体变体，旧版的 1px 横向叠加会被感知为「字被拉长」
## （用户 2026-09-11 实测反馈），故不再渲染；bold 属性保留只为兼容旧场景与调用方。
func _render_plain() -> void:
	var base_color := _sample_color()

	# 阴影（实心黑，永不描边）
	if shadow:
		_configure_label(_label_shadow, shadow_color, false)
		_label_shadow.position = shadow_offset
		_label_shadow.show()
	else:
		_label_shadow.hide()

	_label_bold.hide()

	_configure_label(_label_main, base_color, outline)
	_label_main.position = Vector2.ZERO
	_label_main.show()

	_update_size_from_labels()


func _configure_label(lbl: Label, col: Color, apply_outline: bool) -> void:
	lbl.text = text
	lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", text_font_size)
	lbl.add_theme_color_override("font_color", col)
	if apply_outline:
		lbl.add_theme_color_override("font_outline_color", outline_color)
		lbl.add_theme_constant_override("outline_size", maxi(2, text_font_size / 8))
	else:
		lbl.remove_theme_color_override("font_outline_color")
		lbl.remove_theme_constant_override("outline_size")


func _update_size_from_labels() -> void:
	var ts := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, text_font_size)
	size = Vector2(ceili(ts.x), ceili(ts.y))


func _hide_labels() -> void:
	_label_main.hide()
	_label_bold.hide()
	_label_shadow.hide()


func _hide_all() -> void:
	_hide_labels()
	size = Vector2.ZERO


# ═══════════════════════════════════════
# 辅助
# ═══════════════════════════════════════
## 从 20 色表取某格中心色（固定色来源，非渐变）
static func sample_sheet_color(color_img: Image, color_index: int, color_row: int) -> Color:
	if not color_img:
		return Color.WHITE
	var x := clampi(color_index * 16 + 8, 0, color_img.get_width() - 1)
	var y := clampi(color_row * 16 + 8, 0, color_img.get_height() - 1)
	return color_img.get_pixel(x, y)


func _sample_color() -> Color:
	return GradientLabel.sample_sheet_color(_color_img, color_index, color_row)


## 给普通 Label 套同一套文字样式：字体覆盖 + 色表固定色 + 可选原生描边 + 全局阴影。
## 用于拿不到 GradientLabel 的场景（如需自动换行的多行文本）。
static func style_plain_label(lbl: Label, color_img: Image, color_index: int, color_row: int,
		font: Font, font_size: int, apply_outline: bool = false, apply_shadow: bool = true) -> void:
	if font:
		lbl.add_theme_font_override("font", font)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", sample_sheet_color(color_img, color_index, color_row))
	if apply_outline:
		lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		lbl.add_theme_constant_override("outline_size", maxi(2, font_size / 8))
	if apply_shadow:
		var g := _get_global()
		if g:
			g.apply_text_shadow(lbl)


## static 方法里取 Global autoload（编辑器 @tool 分支下可能不存在 → 返回 null）
static func _get_global() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Global")
	return null
