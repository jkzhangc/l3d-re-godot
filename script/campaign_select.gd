extends Control
## 战役选择界面 — 窗口/标题/光标/描述面板在场景中预置，列表项代码生成

@export_group("窗口布局")
@export var window_size: Vector2 = Vector2(440, 280)
@export var window_pos: Vector2 = Vector2(100, 60)

@export_group("资源路径")
@export var font_path: String = "res://art/System/DotGothic16-Regular.ttf"
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var color_shader_path: String = "res://shader/text_color.gdshader"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"
@export var title_screen_scene: String = "res://scene/title_screen.tscn"
@export var character_select_scene: String = "res://scene/character_select.tscn"

@export_group("列表布局")
@export var item_start_y: float = 52.0
@export var item_spacing: float = 30.0
@export var item_font_size: int = 16
@export var cursor_y_offset: float = -3.0  ## 光标框相对文字中心的Y偏移

@export_group("文字")
@export var text_color_index: int = 1
@export var text_color_row: int = 0

## 场景节点引用
@onready var _window: Control = $MenuWindow
@onready var _window_bg: TextureRect = $MenuWindow/WindowBg
@onready var _window_frame: NinePatchRect = $MenuWindow/WindowFrame
@onready var _title_label: GradientLabel = $MenuWindow/TitleLabel
@onready var _cursor_frame: NinePatchRect = $MenuWindow/CursorFrame
@onready var _desc_label: Label = $MenuWindow/DescPanel/DescLabel

var _campaigns: Array[CampaignData] = []
var _cursor_idx: int = 0
var _item_labels: Array[GradientLabel] = []
var _cursor_atlas: Array[AtlasTexture] = []
var _cursor_frame_idx: int = 0


func _ready() -> void:
	_load_defaults_from_global()
	_sync_window()
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	var color_img := color_texture.get_image() if color_texture else null
	if color_img:
		_title_label.set_color_image(color_img)
	_load_campaigns()
	_create_cursor_frames()
	_cursor_frame.texture = _cursor_atlas[0] if _cursor_atlas.size() > 0 else null
	_build_list()
	_refresh_all()
	_start_cursor_blink()


func _load_defaults_from_global() -> void:
	var g = get_node_or_null("/root/Global")
	if not g:
		return
	if g.text_font_path != "":  font_path = g.text_font_path
	if g.text_color_sheet_path != "":  color_sheet_path = g.text_color_sheet_path
	if g.text_color_shader_path != "":  color_shader_path = g.text_color_shader_path
	text_color_index = g.text_color_index
	text_color_row = g.text_color_row


func _sync_window() -> void:
	_window.size = window_size
	_window.position = window_pos
	_window_bg.size = window_size
	_window_frame.size = window_size


func _load_campaigns() -> void:
	var paths: Array[String] = ["res://object/campaign_assault.tres"]
	for p: String in paths:
		if ResourceLoader.exists(p):
			var res: Resource = load(p)
			if res is CampaignData:
				_campaigns.append(res as CampaignData)
	if _campaigns.is_empty():
		printerr("[战役选择] 未找到任何战役数据")


func _build_list() -> void:
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	var color_img := color_texture.get_image() if color_texture else null
	for i: int in range(_campaigns.size()):
		var gl := GradientLabel.new()
		gl.text = "  %s" % _campaigns[i].campaign_name
		gl.position = Vector2(28, item_start_y + i * item_spacing)
		gl.text_font_size = item_font_size
		gl.color_index = text_color_index
		gl.color_row = text_color_row
		gl.use_gradient = true
		gl.bold = true
		gl.shadow = true
		gl.font_path_override = font_path
		gl.color_sheet_path_override = color_sheet_path
		gl.color_shader_path_override = color_shader_path
		if color_img:
			gl.set_color_image(color_img)
		_window.add_child(gl)
		_item_labels.append(gl)


func _input(event: InputEvent) -> void:
	if _campaigns.is_empty():
		return
	if event.is_action_pressed("取消键"):
		_go_back()
		return
	if event.is_action_pressed("确定键"):
		_confirm()
		return
	var item_count: int = _campaigns.size()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		_refresh_all()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		_refresh_all()


func _refresh_all() -> void:
	_refresh_cursor()
	_refresh_description()


func _refresh_cursor() -> void:
	if not _cursor_frame or _item_labels.is_empty():
		return
	var lbl: GradientLabel = _item_labels[_cursor_idx]
	var center_y: float = lbl.position.y + item_font_size * 0.5
	_cursor_frame.position = Vector2(16, center_y - _cursor_frame.size.y * 0.5 + cursor_y_offset)


func _refresh_description() -> void:
	if not _desc_label:
		return
	if _cursor_idx >= 0 and _cursor_idx < _campaigns.size():
		_desc_label.text = _campaigns[_cursor_idx].description
	else:
		_desc_label.text = ""


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
	var cb: Callable = func(): _on_cursor_blink()
	timer.timeout.connect(cb)
	add_child(timer)
	timer.start()


func _on_cursor_blink() -> void:
	if _cursor_atlas.is_empty() or not _cursor_frame:
		return
	_cursor_frame_idx = 1 - _cursor_frame_idx
	_cursor_frame.texture = _cursor_atlas[_cursor_frame_idx]


func _confirm() -> void:
	if _campaigns.is_empty():
		return
	Global.selected_campaign = _campaigns[_cursor_idx]
	print("[战役选择] 选中: %s" % _campaigns[_cursor_idx].campaign_name)
	var err: Error = get_tree().change_scene_to_file(character_select_scene)
	if err != OK:
		printerr("[战役选择] 场景切换失败: %s" % character_select_scene)


func _go_back() -> void:
	get_tree().change_scene_to_file(title_screen_scene)
