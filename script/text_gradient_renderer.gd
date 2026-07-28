class_name TextGradientRenderer
extends RefCounted
## Renders text with vertical color gradient using the 20-color sheet.
##
## Renders white text to a hidden SubViewport, captures the pixel data,
## applies per-pixel vertical gradient from the color sheet, and returns
## an ImageTexture for display in a TextureRect.
##
## Usage:
##   var tgr := TextGradientRenderer.new(font, font_size, color_img, self)
##   var tex := await tgr.render("开始游戏", color_index)
##   texture_rect.texture = tex


var _font: Font
var _font_size: int
var _color_img: Image
var _text_color_row: int
var _viewport: SubViewport


func _init(font: Font, font_size: int, color_img: Image, parent: Node, text_color_row: int = 0) -> void:
	_font = font
	_font_size = font_size
	_color_img = color_img
	_text_color_row = clampi(text_color_row, 0, 3)

	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.size = Vector2i(256, 64)
	parent.add_child(_viewport)


## Internal helper used by render() — not meant for direct use.
func _render(text: String, color_index: int, outline: bool, outline_color: Color, padding: int) -> Image:
	# Measure text
	var ts := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size)
	var img_w := maxi(ceili(ts.x) + padding * 2, 1)
	var img_h := maxi(ceili(ts.y) + padding * 2, 1)

	_viewport.size = Vector2i(img_w, img_h)

	# Clear previous label
	for c in _viewport.get_children():
		_viewport.remove_child(c)
		c.queue_free()

	# Create label with white text
	var lbl := Label.new()
	lbl.text = text
	lbl.position = Vector2(padding, padding)
	lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", _font_size)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	_viewport.add_child(lbl)

	# Wait for viewport to render (UPDATE_ALWAYS renders every frame)
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		await tree.process_frame
		await tree.process_frame

	var img := _viewport.get_texture().get_image()
	if img.is_empty():
		printerr("[TextGradientRenderer] 渲染失败: 文字='%s'" % text)
		return img

	# Apply vertical gradient — brighten top, darken bottom from base color
	var out := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))

	var ci := clampi(color_index, 0, 19)
	var sheet_center_x := clampi(ci * 16 + 8, 0, _color_img.get_width() - 1)
	var sheet_center_y := clampi(_text_color_row * 16 + 8, 0, _color_img.get_height() - 1)
	var base_color := _color_img.get_pixel(sheet_center_x, sheet_center_y)
	var img_h_f := float(maxi(img.get_height() - 1, 1))

	for py in img.get_height():
		# gradient_t: 0.0 = top of text, 1.0 = bottom of text
		var gradient_t := float(py) / img_h_f
		# Brightness: ~1.35 at top → ~0.55 at bottom
		var brightness := 1.35 - gradient_t * 0.8
		var grad_color := Color(
			clampf(base_color.r * brightness, 0.0, 1.0),
			clampf(base_color.g * brightness, 0.0, 1.0),
			clampf(base_color.b * brightness, 0.0, 1.0),
			base_color.a
		)

		for px in img.get_width():
			var pixel := img.get_pixel(px, py)
			if pixel.a < 0.01:
				continue

			if outline and _is_edge(img, px, py):
				out.set_pixel(px, py, Color(
					outline_color.r, outline_color.g, outline_color.b,
					pixel.a * outline_color.a
				))
			else:
				out.set_pixel(px, py, Color(
					grad_color.r, grad_color.g, grad_color.b, pixel.a
				))

	return out


## Render text with vertical gradient. Caller must await the returned value.
## Returns [ImageTexture] or null on failure.
func render(text: String, color_index: int, outline: bool = false, outline_color: Color = Color.BLACK) -> ImageTexture:
	if text.is_empty() or not _font or not _color_img:
		return null

	var padding := 2 if outline else 0
	var img := await _render(text, color_index, outline, outline_color, padding)

	if img.is_empty():
		return null

	return ImageTexture.create_from_image(img)


## Render text with a flat color (no gradient).
## Useful for shadows or bold-offset copies where gradient would look wrong.
func render_flat(text: String, color_index: int, _unused: bool = false, _unused2: Color = Color.BLACK) -> ImageTexture:
	if text.is_empty() or not _font or not _color_img:
		return null

	# Render white text
	var img := await _render(text, color_index, false, Color.BLACK, 0)
	if img.is_empty():
		return null

	# Apply flat color from color sheet center
	var ci := clampi(color_index, 0, 19)
	var cell_cy := _text_color_row * 16 + 8
	var cell_cx := ci * 16 + 8
	cell_cx = clampi(cell_cx, 0, _color_img.get_width() - 1)
	cell_cy = clampi(cell_cy, 0, _color_img.get_height() - 1)
	var flat_color := _color_img.get_pixel(cell_cx, cell_cy)

	for py in img.get_height():
		for px in img.get_width():
			var pixel := img.get_pixel(px, py)
			if pixel.a > 0.01:
				img.set_pixel(px, py, Color(
					flat_color.r, flat_color.g, flat_color.b, pixel.a
				))

	return ImageTexture.create_from_image(img)


## Check if a pixel is on the edge of a glyph (has ≥1 transparent neighbor).
func _is_edge(img: Image, x: int, y: int) -> bool:
	var w: int = img.get_width()
	var h: int = img.get_height()
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var nx: int = x + dx
			var ny: int = y + dy
			if nx < 0 or nx >= w or ny < 0 or ny >= h:
				return true
			if img.get_pixel(nx, ny).a < 0.01:
				return true
	return false
