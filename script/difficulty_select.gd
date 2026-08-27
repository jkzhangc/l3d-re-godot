extends Control
## 难度选择界面 — 所有节点在场景中预置，代码只做逻辑

const DIFFICULTY_NAMES: Array[String] = ["简单", "普通", "困难", "专家"]
const DIFFICULTY_DESCRIPTIONS: Array[String] = [
	"敌人较弱，伤害减半。适合熟悉游戏操作。",
	"标准难度，推荐首次挑战。",
	"敌人更强更耐打，需要策略配合。",
	"真正的生存考验。祝你幸运。",
]

@export_group("窗口布局")
@export var window_size: Vector2 = Vector2(320, 280)
@export var window_pos: Vector2 = Vector2(160, 80)

@export_group("资源路径")
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"
@export var character_select_scene: String = "res://scene/character_select.tscn"

@export_group("光标")
@export var cursor_y_offset: float = -3.0  ## 光标框相对文字中心的Y偏移

@export_group("文字")
@export var text_color_index: int = 1
@export var text_color_row: int = 0

## 场景节点引用
@onready var _window: Control = $MenuWindow
@onready var _window_bg: TextureRect = $MenuWindow/WindowBg
@onready var _window_frame: NinePatchRect = $MenuWindow/WindowFrame
@onready var _cursor_frame: NinePatchRect = $MenuWindow/CursorFrame
@onready var _item_labels: Array[GradientLabel] = [
	$MenuWindow/Item0, $MenuWindow/Item1, $MenuWindow/Item2, $MenuWindow/Item3,
]
@onready var _desc_label: Label = $MenuWindow/DescPanel/DescLabel
@onready var _title_label: GradientLabel = $MenuWindow/TitleLabel

var _cursor_idx: int = 1
var _cursor_atlas: Array[AtlasTexture] = []
var _cursor_frame_idx: int = 0


func _ready() -> void:
	_load_defaults_from_global()
	_sync_window()
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	var color_img := color_texture.get_image() if color_texture else null
	if color_img:
		_title_label.set_color_image(color_img)
		for lbl: GradientLabel in _item_labels:
			lbl.set_color_image(color_img)
	_create_cursor_frames()
	_cursor_frame.texture = _cursor_atlas[0] if _cursor_atlas.size() > 0 else null
	_refresh_all()
	_start_cursor_blink()


func _load_defaults_from_global() -> void:
	var g = get_node_or_null("/root/Global")
	if not g:
		return
	text_color_index = g.text_color_index
	text_color_row = g.text_color_row


func _sync_window() -> void:
	_window.size = window_size
	_window.position = window_pos
	_window_bg.size = window_size
	_window_frame.size = window_size


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		get_tree().change_scene_to_file(character_select_scene)
		return
	if event.is_action_pressed("确定键"):
		_confirm()
		return
	var item_count: int = DIFFICULTY_NAMES.size()
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
	if not _cursor_frame:
		return
	var lbl: GradientLabel = _item_labels[_cursor_idx]
	var center_y: float = lbl.position.y + lbl.text_font_size * 0.5
	_cursor_frame.position = Vector2(16, center_y - _cursor_frame.size.y * 0.5 + cursor_y_offset)


func _refresh_description() -> void:
	if _desc_label:
		_desc_label.text = DIFFICULTY_DESCRIPTIONS[_cursor_idx]


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
	Global.selected_difficulty = _cursor_idx
	var level_path: String = ""
	if Global.selected_campaign and Global.selected_campaign.level_scenes.size() > 0:
		level_path = Global.selected_campaign.level_scenes[0]
	else:
		level_path = "res://scene/maps/突袭-第一关-开头安全屋-户外.tscn"
	Global.init_new_game()
	var err: Error = get_tree().change_scene_to_file(level_path)
	if err != OK:
		printerr("[难度选择] 场景切换失败: %s (err=%d)" % [level_path, err])
