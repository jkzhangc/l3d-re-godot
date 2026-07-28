extends Control
## 角色/关卡选择界面 — 占位
##
## 操作：
##   取消键  → 返回标题画面


@export var title_screen_scene: String = "res://scene/title_screen.tscn"
@export var font_path: String = "res://art/System/DotGothic16-Regular.ttf"


func _ready() -> void:
	_create_ui()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		_go_back()


func _go_back() -> void:
	print("[角色选择] 返回标题画面")
	var err: Error = get_tree().change_scene_to_file(title_screen_scene)
	if err != OK:
		printerr("[角色选择] 场景切换失败: %s (err=%d)" % [title_screen_scene, err])


func _create_ui() -> void:
	# ── 背景 ──
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = Color(0.02, 0.02, 0.08, 1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# ── 标题 ──
	var title := _make_label("选择角色 / 关卡", Vector2(180, 120), 24, Color.WHITE)
	add_child(title)

	# ── 占位文字 ──
	var placeholder := _make_label(
		"（开发中...）",
		Vector2(260, 180),
		16,
		Color(0.45, 0.45, 0.55, 1)
	)
	add_child(placeholder)

	# ── 返回提示 ──
	var hint := _make_label(
		"按 取消键 (X / Esc) 返回标题画面",
		Vector2(160, 420),
		14,
		Color(0.4, 0.4, 0.5, 1)
	)
	add_child(hint)


func _load_font(base_size: int = 16) -> Font:
	var ff: FontFile = load(font_path) as FontFile
	if not ff:
		return ThemeDB.fallback_font
	return ff


func _make_label(text: String, pos: Vector2, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = pos
	lbl.add_theme_font_override("font", _load_font(font_size))
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	return lbl
