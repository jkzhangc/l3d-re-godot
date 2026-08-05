@tool
class_name GradientLabel
extends Control
## 渐变文字标签 — 自动应用色表纵向渐变效果。
##
## use_gradient = true（默认）:
##   自动通过 TextGradientRenderer 渲染渐变文字，显示为 TextureRect
##   支持粗体（1px 偏移叠加）、阴影、描边
##
## use_gradient = false:
##   使用普通 Label + shader 纯色着色，无渐变
##
## 资源路径留空则从 Global 单例读取默认值。


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

@export var use_gradient: bool = true:
	set(v):
		use_gradient = v
		_request_render()

@export var color_index: int = 0:
	set(v):
		color_index = clampi(v, 0, 19)
		_request_render()

@export var color_row: int = 0:
	set(v):
		color_row = clampi(v, 0, 3)
		_color_dirty = true
		_request_render()


# ═══════════════════════════════════════
# 文字效果
# ═══════════════════════════════════════

@export var bold: bool = false:
	set(v):
		bold = v
		_request_render()

@export var shadow: bool = false:
	set(v):
		shadow = v
		_request_render()

@export var shadow_color: Color = Color(0, 0, 0, 0.6):
	set(v):
		shadow_color = v
		_request_render()

@export var shadow_offset: Vector2 = Vector2(2, 2):
	set(v):
		shadow_offset = v
		_request_render()

@export var outline: bool = false:
	set(v):
		outline = v
		_request_render()

@export var outline_color: Color = Color.BLACK:
	set(v):
		outline_color = v
		_request_render()


# ═══════════════════════════════════════
# 资源路径（留空 = 从 Global 继承）
# ═══════════════════════════════════════

@export var font_path_override: String = ""
@export var color_sheet_path_override: String = ""
@export var color_shader_path_override: String = ""


# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════

var _label_shadow: Label = null
var _label_bold: Label = null
var _label_main: Label = null

var _tex_shadow: TextureRect = null
var _tex_bold: TextureRect = null
var _tex_main: TextureRect = null

var _gradient_renderer: TextGradientRenderer = null
var _render_generation: int = 0
var _dirty: bool = false
var _rendering: bool = false
var _properties_initialized: bool = false

var _font: Font = null
var _font_dirty: bool = true
var _color_img: Image = null
var _color_dirty: bool = true
var _shader_mat: ShaderMaterial = null

var _resolved_font_path: String = ""
var _resolved_color_sheet_path: String = ""
var _resolved_shader_path: String = ""

# Shared color image (set externally to avoid per-instance file I/O)
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


func _exit_tree() -> void:
	_cleanup_renderer()
	_rendering = false


# ═══════════════════════════════════════
# 公开方法
# ═══════════════════════════════════════

## 设置共享色表 Image，避免每个 GradientLabel 重复加载
func set_color_image(img: Image) -> void:
	_shared_color_img = img
	_color_dirty = true
	_request_render()


# ═══════════════════════════════════════
# 默认值同步
# ═══════════════════════════════════════

func _load_defaults_from_global() -> void:
	var g := get_node_or_null("/root/Global")
	if not g:
		return
	use_gradient = g.text_gradient_enabled
	color_index = g.text_color_index
	color_row = g.text_color_row
	bold = g.text_bold
	outline = g.text_outline
	outline_color = g.text_outline_color
	shadow = g.text_shadow
	shadow_color = g.text_shadow_color
	shadow_offset = g.text_shadow_offset


func _resolve_paths() -> void:
	var g := get_node_or_null("/root/Global")
	var g_font := ""
	var g_sheet := ""
	var g_shader := ""
	if g:
		g_font = g.text_font_path
		g_sheet = g.text_color_sheet_path
		g_shader = g.text_color_shader_path

	_resolved_font_path = font_path_override if not font_path_override.is_empty() else g_font
	_resolved_color_sheet_path = color_sheet_path_override if not color_sheet_path_override.is_empty() else g_sheet
	_resolved_shader_path = color_shader_path_override if not color_shader_path_override.is_empty() else g_shader


# ═══════════════════════════════════════
# 子节点管理
# ═══════════════════════════════════════

func _ensure_children() -> void:
	# Label fallback children (always present, for editor preview + non-gradient mode)
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
		_label_shadow.z_index = -1
		_label_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_label_shadow)

	# TextureRect children (created on demand for gradient mode)
	if not _tex_main:
		_tex_main = TextureRect.new()
		_tex_main.name = "TexMain"
		_tex_main.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_tex_main.hide()
		add_child(_tex_main)
	if not _tex_bold:
		_tex_bold = TextureRect.new()
		_tex_bold.name = "TexBold"
		_tex_bold.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_tex_bold.hide()
		add_child(_tex_bold)
	if not _tex_shadow:
		_tex_shadow = TextureRect.new()
		_tex_shadow.name = "TexShadow"
		_tex_shadow.z_index = -1
		_tex_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_tex_shadow.hide()
		add_child(_tex_shadow)


# ═══════════════════════════════════════
# 渲染入口
# ═══════════════════════════════════════

func _request_render() -> void:
	if _rendering:
		_render_generation += 1  # Cancel in-flight render
		_dirty = true
		return
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

	if use_gradient and _color_img:
		_render_gradient()
	else:
		_render_non_gradient()


# ═══════════════════════════════════════
# 资源加载
# ═══════════════════════════════════════

func _load_resources() -> void:
	# Font
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

	# Color image
	if _color_dirty:
		_color_img = null
		if _shared_color_img:
			_color_img = _shared_color_img
		elif not _resolved_color_sheet_path.is_empty():
			# Try Global cache first (avoids per-instance Image.load_from_file)
			var g := get_node_or_null("/root/Global")
			if g and g.has_method("get_cached_color_image") and g.text_color_sheet_path == _resolved_color_sheet_path:
				_color_img = g.get_cached_color_image()
			if not _color_img:
				_color_img = Image.load_from_file(_resolved_color_sheet_path)
			if _color_img:
				print("[GradientLabel] 色表已加载 %d×%d" % [_color_img.get_width(), _color_img.get_height()])
			else:
				printerr("[GradientLabel] 色表加载失败: %s" % _resolved_color_sheet_path)
		_color_dirty = false

	# Shader (non-gradient path only)
	if not _shader_mat and not _resolved_shader_path.is_empty():
		var shader: Shader = load(_resolved_shader_path) as Shader
		if shader:
			_shader_mat = ShaderMaterial.new()
			_shader_mat.shader = shader
		else:
			printerr("[GradientLabel] Shader 加载失败: %s" % _resolved_shader_path)


# ═══════════════════════════════════════
# 非渐变路径（Label + shader 纯色）
# ═══════════════════════════════════════

func _render_non_gradient() -> void:
	_hide_textures()

	var base_color := _sample_color()

	# Shadow label
	if shadow:
		_configure_plain_label(_label_shadow, shadow_color, false)
		_label_shadow.position = shadow_offset
		_label_shadow.show()
	else:
		_label_shadow.hide()

	# Bold label
	if bold:
		_configure_label_with_shader(_label_bold, base_color, false)
		_label_bold.position = Vector2(1, 0)
		_label_bold.show()
	else:
		_label_bold.hide()

	# Main label
	_configure_label_with_shader(_label_main, base_color, outline)
	_label_main.position = Vector2.ZERO
	_label_main.show()

	_update_size_from_labels()


func _configure_plain_label(lbl: Label, col: Color, _apply_outline: bool) -> void:
	lbl.text = text
	lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", text_font_size)
	lbl.add_theme_color_override("font_color", col)
	lbl.material = null


func _configure_label_with_shader(lbl: Label, base_color: Color, apply_outline: bool) -> void:
	lbl.text = text
	lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", text_font_size)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	if _shader_mat:
		_shader_mat.set_shader_parameter("text_color", base_color)
		_shader_mat.set_shader_parameter("outline_enabled", apply_outline)
		_shader_mat.set_shader_parameter("outline_color", outline_color)
		lbl.material = _shader_mat
	else:
		lbl.material = null
		lbl.add_theme_color_override("font_color", base_color)


func _update_size_from_labels() -> void:
	var ts := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, text_font_size)
	size = Vector2(ceili(ts.x), ceili(ts.y))


# ═══════════════════════════════════════
# 渐变路径（TextGradientRenderer → TextureRect）
# ═══════════════════════════════════════

func _render_gradient() -> void:
	_rendering = true
	_render_generation += 1
	var gen := _render_generation

	# Show labels as immediate placeholder while gradient renders
	_render_non_gradient()

	# Ensure renderer
	if not _gradient_renderer:
		_gradient_renderer = TextGradientRenderer.new(_font, text_font_size, _color_img, self, color_row)

	# Render shadow (flat color, no gradient)
	if shadow:
		var shadow_tex := await _gradient_renderer.render_flat(text, color_index)
		if gen != _render_generation:
			_rendering = false
			return
		if shadow_tex:
			_tex_shadow.texture = shadow_tex
			_tex_shadow.position = shadow_offset
			_tex_shadow.modulate = shadow_color
			_tex_shadow.size = shadow_tex.get_size()
			_tex_shadow.show()
		else:
			_tex_shadow.hide()
	else:
		_tex_shadow.hide()

	# Render main gradient text
	var main_tex := await _gradient_renderer.render(text, color_index, outline, outline_color)
	if gen != _render_generation:
		_rendering = false
		return

	if main_tex:
		# Bold — reuse same texture, offset 1px right
		if bold:
			_tex_bold.texture = main_tex
			_tex_bold.position = Vector2(1, 0)
			_tex_bold.size = main_tex.get_size()
			_tex_bold.show()
		else:
			_tex_bold.hide()

		# Main
		_tex_main.texture = main_tex
		_tex_main.position = Vector2.ZERO
		_tex_main.size = main_tex.get_size()
		_tex_main.show()

		_hide_labels()
		_update_size_from_texture(main_tex)
	else:
		# Gradient render failed — labels remain as fallback
		_hide_textures()
		_update_size_from_labels()

	_rendering = false


func _update_size_from_texture(tex: Texture2D) -> void:
	size = tex.get_size()


# ═══════════════════════════════════════
# 子节点显示/隐藏
# ═══════════════════════════════════════

func _hide_labels() -> void:
	_label_main.hide()
	_label_bold.hide()
	_label_shadow.hide()


func _hide_textures() -> void:
	_tex_main.hide()
	_tex_bold.hide()
	_tex_shadow.hide()


func _hide_all() -> void:
	_hide_labels()
	_hide_textures()
	size = Vector2.ZERO


# ═══════════════════════════════════════
# 辅助
# ═══════════════════════════════════════

func _sample_color() -> Color:
	if not _color_img:
		return Color.WHITE
	var x := clampi(color_index * 16 + 8, 0, _color_img.get_width() - 1)
	var y := clampi(color_row * 16 + 8, 0, _color_img.get_height() - 1)
	return _color_img.get_pixel(x, y)


func _cleanup_renderer() -> void:
	if _gradient_renderer:
		_gradient_renderer = null
