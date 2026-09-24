extends Control

## ── 架构定位 ──
## 系统：难度选择 ｜ 层：表现（Control）
## 联机：不涉及
## 职责：难度选择界面（简单/普通/困难/专家），下滚全景背景 + 页标题（角色选择同款视觉），节点全部预置、代码只做逻辑。
## 依赖：Global 文字默认值、PanoramaBackdrop

## 难度选择界面 — 所有节点在场景中预置，代码只做逻辑

const DIFFICULTY_NAMES: Array[String] = ["简单", "普通", "困难", "专家"]
const DIFFICULTY_DESCRIPTIONS: Array[String] = [
	"敌人较弱，伤害减半。适合熟悉游戏操作。",
	"标准难度，推荐首次挑战。",
	"敌人更强更耐打，需要策略配合。",
	"真正的生存考验。祝你幸运。",
]

@export_group("背景")
## 下滚全景背景（角色选择界面同款视觉）；留空路径 = 不加背景。
@export var backdrop_texture_path: String = "res://art/Panorama/地下.png"
@export var backdrop_scale: float = 2.0
@export var backdrop_scroll_speed: float = 20.0
@export var backdrop_dim_alpha: float = 0.35

@export_group("窗口布局")
## 2026-09-14：窗口放大到约占屏幕 2/3，列表/描述同步放大
@export var window_size: Vector2 = Vector2(860, 640)
## 窗口是否在视口正中（默认）。关闭后改用 window_pos 手动摆放。
@export var window_centered: bool = true
@export var window_pos: Vector2 = Vector2(160, 80)

@export_group("资源路径")
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"
@export var character_select_scene: String = "res://scene/character_select.tscn"

@export_group("界面音效")
## 留空 = 用 Global 的 ui_*_sfx_path（全局窗口音效参数）
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cursor_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_confirm_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cancel_path: String = ""

@export_group("光标")
@export var cursor_y_offset: float = -3.0  ## 光标框相对文字中心的Y偏移

@export_group("文字")
@export var text_color_index: int = 1
@export var text_color_row: int = 0

@export_group("描述文字")
## DescLabel 是普通 Label（需自动换行，用不了 GradientLabel），字体在此配置；
## 与 tscn 里 DescLabel 的 theme override 保持一致，编辑器所见即运行时所得。
## 留空 = 跟随「设置 → 界面字体」（2026-09-24）。字号取 12px 基底整倍（24/36），非整倍会糊。
@export var desc_font_path: String = ""
@export var desc_font_size: int = 24

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
	Global.play_lobby_music()   # 大厅 BGM：三选择界面共用，切界面不中断（2026-09-13）
	_build_backdrop()
	_load_defaults_from_global()
	_sync_window()
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	var color_img := color_texture.get_image() if color_texture else null
	if color_img:
		_title_label.set_color_image(color_img)
		for lbl: GradientLabel in _item_labels:
			lbl.set_color_image(color_img)
		_style_plain_labels(color_img)
	_create_cursor_frames()
	_cursor_frame.texture = _cursor_atlas[0] if _cursor_atlas.size() > 0 else null
	_refresh_all()
	## 首帧修正（2026-09-15）：GradientLabel 文本尺寸是延迟重建的，_ready 里立即刷光标时
	## size.y 还没就绪（center_y 算小 → 光标停偏）；推迟一帧等尺寸就绪后再刷。
	_refresh_all.call_deferred()
	_start_cursor_blink()


## 描述文字是普通 Label（需要自动换行，用不了 GradientLabel），
## 字体/字号走 desc_font_path/desc_font_size（Inspector 可改，2026-09-15）；
## 留空 = 跟随「设置 → 界面字体」（2026-09-24）。
func _style_plain_labels(color_img: Image) -> void:
	var g: Node = get_node_or_null("/root/Global")
	var font: Font = null
	if g and g.has_method("resolve_and_load_font"):
		font = g.resolve_and_load_font(desc_font_path)
	else:
		font = load(desc_font_path) as Font if not desc_font_path.is_empty() else ThemeDB.fallback_font
	GradientLabel.style_plain_label(
		_desc_label, color_img, text_color_index, text_color_row,
		font, desc_font_size
	)


## 下滚全景背景 + 页标题（角色选择界面同款视觉；背景必须最先加入才能垫底）。
func _build_backdrop() -> void:
	if not backdrop_texture_path.is_empty() and ResourceLoader.exists(backdrop_texture_path):
		var backdrop := PanoramaBackdrop.new()
		backdrop.texture_path = backdrop_texture_path
		backdrop.bg_scale = backdrop_scale
		backdrop.scroll_speed = backdrop_scroll_speed
		backdrop.dim_alpha = backdrop_dim_alpha
		add_child(backdrop)
		move_child(backdrop, 0)  ## 垫底：add_child 默认加到末尾，会盖住预置窗口
# 页标题已节点化：scene/difficulty_select.tscn / PageTitle（编辑器 Inspector 可改）


func _load_defaults_from_global() -> void:
	var g = get_node_or_null("/root/Global")
	if not g:
		return
	text_color_index = g.text_color_index
	text_color_row = g.text_color_row


func _sync_window() -> void:
	_window.size = window_size
	_window.position = _resolve_window_position()
	_window_bg.size = window_size
	_window_frame.size = window_size


## 窗口左上角：默认取视口正中。取整是为了配合 integer 拉伸，避免半像素导致文字糊边。
func _resolve_window_position() -> Vector2:
	if not window_centered:
		return window_pos
	return ((get_viewport_rect().size - window_size) * 0.5).floor()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		get_tree().change_scene_to_file(character_select_scene)
		return
	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		_confirm()
		return
	var item_count: int = DIFFICULTY_NAMES.size()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_all()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_all()


func _refresh_all() -> void:
	_refresh_cursor()
	_refresh_description()


func _refresh_cursor() -> void:
	if not _cursor_frame:
		return
	var lbl: GradientLabel = _item_labels[_cursor_idx]
	_cursor_frame.size = Vector2(window_size.x - 48, 64)  # 先定尺寸，位置用新尺寸算（修初始偏移）
	var center_y: float = lbl.position.y + lbl.size.y * 0.5  # 用标签实际渲染高居中
	_cursor_frame.position = Vector2(24, center_y - _cursor_frame.size.y * 0.5 + cursor_y_offset)


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
	Global.stop_lobby_music()   # 离开大厅（正式开局），停共用 BGM（2026-09-13）
	var level_path: String = ""
	if Global.selected_campaign and Global.selected_campaign.level_scenes.size() > 0:
		level_path = Global.selected_campaign.level_scenes[0]
	else:
		level_path = "res://scene/maps/突袭-第一关-开头安全屋-户外.tscn"
	Global.init_new_game()
	var err: Error = get_tree().change_scene_to_file(level_path)
	if err != OK:
		printerr("[难度选择] 场景切换失败: %s (err=%d)" % [level_path, err])
