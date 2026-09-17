extends Node
## 临时诊断探针：核对选择界面的文字着色器/渐变实际生效路径。
##
## 渐变走 TextGradientRenderer（真实渲染器），headless 下会主动返回 null，
## 所以本探针必须**窗口渲染**运行，不能用 --headless。
##
## 用法："$GD" --path <项目> res://tools/ui_text_probe.tscn
##
## 对每个 GradientLabel 判定当前生效路径：
##   GRADIENT  = 渐变纹理已生效（_tex_main 可见）
##   FLAT      = 停在占位状态（只显示 Label + 着色器平色，渐变纹理没产出）
##   无着色器  = 既非渐变也无 shader 材质（材质为 null）

const CASES: Array[Dictionary] = [
	{"name": "campaign", "scene": "res://scene/campaign_select.tscn"},
	{"name": "difficulty", "scene": "res://scene/difficulty_select.tscn"},
	{"name": "character", "scene": "res://scene/character_select.tscn"},
]

const OUT_DIR := "user://ui_probe"


var _root: Node = null


func _ready() -> void:
	_dump_palette()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	for case: Dictionary in CASES:
		await _probe(case, "")
	await _stress_character()
	print("=== UI_TEXT_PROBE 完成，图片在 %s ===" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit(0)


## 色表第 0 行 20 个色号的实际颜色（用于核对 color_index 改动的影响）
func _dump_palette() -> void:
	var path := "res://art/System/Text color, 20 types (each 16 x 16).png"
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		return
	var img := tex.get_image()
	var parts: Array[String] = []
	for row in range(mini(2, img.get_height() / 16)):
		var line: Array[String] = []
		for i in range(mini(20, img.get_width() / 16)):
			var c := img.get_pixel(i * 16 + 8, row * 16 + 8)
			line.append("%d:#%s" % [i, c.to_html(false)])
		parts.append("row%d  %s" % [row, " ".join(line)])
	print("[调色板] " + " ｜ ".join(parts))


func _probe(case: Dictionary, tag: String) -> void:
	var packed: PackedScene = load(case["scene"]) as PackedScene
	var root: Control = packed.instantiate() as Control
	add_child(root)
	for i in range(40):
		await get_tree().process_frame
	var label := "%s%s" % [case["name"], tag]
	_dump(root, label)
	_save("%s.png" % label)
	root.queue_free()
	await get_tree().process_frame


func _stress_character() -> void:
	## 快速连按方向键：文字在渐变渲染在途期间被改写，最容易暴露"取消后不重排"的卡死
	var packed: PackedScene = load("res://scene/character_select.tscn") as PackedScene
	var root: Control = packed.instantiate() as Control
	add_child(root)
	for i in range(40):
		await get_tree().process_frame
	for i in range(30):
		var ev := InputEventAction.new()
		ev.action = "右"
		ev.pressed = true
		root._input(ev)
		await get_tree().process_frame
	for i in range(60):
		await get_tree().process_frame
	_dump(root, "character_stress")
	_save("character_stress.png")
	root.queue_free()
	await get_tree().process_frame


func _dump(root: Node, label: String) -> void:
	print("───────── %s ─────────" % label)
	_root = root
	var rows: Array[String] = []
	_walk(root, rows)
	for r: String in rows:
		print(r)


func _walk(node: Node, rows: Array[String]) -> void:
	if node is GradientLabel:
		rows.append("  [%s] %s" % [_path_of(node), _classify(node)])
	elif node is Label:
		var mat: Material = node.material
		var has_font: bool = node.has_theme_font_override("font")
		var col: Color = node.get_theme_color("font_color")
		rows.append("  [%s] 纯Label 材质=%s 字体覆盖=%s 颜色=%s 文本=\"%s\"" % [
			_path_of(node), "有" if mat else "无", "有" if has_font else "无",
			str(col), node.text.substr(0, 14)])
	for c in node.get_children():
		_walk(c, rows)


func _classify(gl: GradientLabel) -> String:
	var tex_main: Control = gl.get_node_or_null("TexMain")
	var label_main: Control = gl.get_node_or_null("LabelMain")
	var mat_on_label: Material = label_main.material if label_main else null
	var tex_on := tex_main != null and tex_main.visible
	var lab_on := label_main != null and label_main.visible
	var path_label := "GRADIENT" if tex_on else ("FLAT" if lab_on else "无显示")
	var shader_state := "着色器=有" if mat_on_label else "着色器=无"
	return "%s %s 粗=%s 影=%s 渐变=%s 色=%d/%d 文本=\"%s\"" % [
		path_label, shader_state, str(gl.bold), str(gl.shadow), str(gl.use_gradient),
		gl.color_index, gl.color_row, gl.text.substr(0, 14)]


func _path_of(node: Node) -> String:
	if _root and is_instance_valid(_root):
		return str(_root.get_path_to(node))
	return str(node.name)


func _save(file_name: String) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	img.save_png(OUT_DIR.path_join(file_name))
