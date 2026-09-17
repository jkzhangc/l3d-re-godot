extends Control

## ── 架构定位 ──
## 系统：战役选择 ｜ 层：表现（Control）
## 联机：不涉及
## 职责：战役选择界面：下滚全景背景 + 页标题（角色选择同款视觉），列表项代码生成，窗口/光标/描述面板由场景预置。
## 依赖：CampaignData、Global 文字默认值、PanoramaBackdrop

## 战役选择界面 — 窗口/标题/光标/描述面板在场景中预置，列表项代码生成

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
@export var window_pos: Vector2 = Vector2(100, 60)

@export_group("资源路径")
@export var font_path: String = "res://art/System/DotGothic16-Regular.ttf"
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"
@export var title_screen_scene: String = "res://scene/title_screen.tscn"
@export var character_select_scene: String = "res://scene/character_select.tscn"

@export_group("界面音效")
## 留空 = 用 Global 的 ui_*_sfx_path（全局窗口音效参数）
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cursor_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_confirm_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cancel_path: String = ""

@export_group("列表布局")
@export var item_start_y: float = 108.0
@export var item_spacing: float = 56.0
## 战役名列表项字号：12px 基底取整倍，非整倍（如 32）会糊；36=12×3（2026-09-15 用户定稿）
@export var item_font_size: int = 36
@export var cursor_y_offset: float = 5.0  ## 光标框相对文字中心的Y偏移

@export_group("列表项字体")
## 列表项是代码动态构建的 GradientLabel，字体在此配置（Inspector 可改）。
## 留空回退 font_path（会被 Global 同步覆盖）。列表项编辑器里不可见，进游戏看效果。
@export var item_font_path: String = "res://art/System/fusion-pixel-12px-monospaced-zh_hans.ttf"

@export_group("文字")
@export var text_color_index: int = 1
@export var text_color_row: int = 0

@export_group("描述文字")
## DescLabel 是普通 Label（需自动换行，用不了 GradientLabel），字体在此配置；
## 与 tscn 里 DescLabel 的 theme override 保持一致，编辑器所见即运行时所得。
## 留空回退 Global → ark-pixel。字号取 12px 基底整倍（24/36），非整倍会糊。
@export var desc_font_path: String = "res://art/System/fusion-pixel-12px-monospaced-zh_hans.ttf"
@export var desc_font_size: int = 24

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
	Global.play_lobby_music()   # 大厅 BGM：三选择界面共用，切界面不中断（2026-09-13）
	_build_backdrop()
	_load_defaults_from_global()
	_sync_window()
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	var color_img := color_texture.get_image() if color_texture else null
	if color_img:
		_title_label.set_color_image(color_img)
		_style_plain_labels(color_img)
	_load_campaigns()
	_create_cursor_frames()
	_cursor_frame.texture = _cursor_atlas[0] if _cursor_atlas.size() > 0 else null
	_build_list()
	_refresh_all()
	## 首帧修正（2026-09-15）：GradientLabel 文本尺寸是延迟重建的，_ready 里立即刷光标时
	## size.y 还没就绪（center_y 算小 → 光标停到列表上方）；推迟一帧等尺寸就绪后再刷。
	_refresh_all.call_deferred()
	_start_cursor_blink()


## 描述文字是普通 Label（需要自动换行，走不了单行渐变纹理），
## 这里补上字体 + 色表取色 + 阴影。字体/字号走 desc_font_path/desc_font_size
## （Inspector 可改，2026-09-15）；留空回退 Global → ark-pixel。
func _style_plain_labels(color_img: Image) -> void:
	var path := desc_font_path
	if path.is_empty():
		var g = get_node_or_null("/root/Global")
		path = str(g.text_font_path) if g and str(g.text_font_path) != "" else "res://art/System/ark-pixel-16px-monospaced-zh_cn.ttf"
	GradientLabel.style_plain_label(
		_desc_label, color_img, text_color_index, text_color_row,
		load(path) as Font, desc_font_size
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
# 页标题已节点化：scene/campaign_select.tscn / PageTitle（编辑器 Inspector 可改）


func _load_defaults_from_global() -> void:
	var g = get_node_or_null("/root/Global")
	if not g:
		return
	if g.text_font_path != "":  font_path = g.text_font_path
	if g.text_color_sheet_path != "":  color_sheet_path = g.text_color_sheet_path
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


func _load_campaigns() -> void:
	var paths: Array[String] = ["res://object/campaign_assault.tres", "res://object/campaign_night_hunter.tres"]
	for p: String in paths:
		if ResourceLoader.exists(p):
			var res: Resource = load(p)
			if res is CampaignData:
				var cd := res as CampaignData
				# 章节骨架期：level_scenes 为空的战役（如夜行猎手）只展示不可开局
				if cd.level_scenes.is_empty():
					print("[战役选择] 战役「%s」章节未实装，跳过" % cd.campaign_name)
					continue
				_campaigns.append(cd)
	if _campaigns.is_empty():
		printerr("[战役选择] 未找到任何战役数据")


func _build_list() -> void:
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	var color_img := color_texture.get_image() if color_texture else null
	for i: int in range(_campaigns.size()):
		var gl := GradientLabel.new()
		gl.text = "  %s" % _campaigns[i].campaign_name
		gl.position = Vector2(40, item_start_y + i * item_spacing)
		gl.text_font_size = item_font_size
		gl.color_index = text_color_index
		gl.color_row = text_color_row
		gl.bold = true
		gl.shadow = true
		## 列表项字体：item_font_path 优先（Inspector 可改），留空回退 font_path
		gl.font_path_override = item_font_path if not item_font_path.is_empty() else font_path
		gl.color_sheet_path_override = color_sheet_path
		if color_img:
			gl.set_color_image(color_img)
		_window.add_child(gl)
		_item_labels.append(gl)


func _input(event: InputEvent) -> void:
	if _campaigns.is_empty():
		return
	if event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		_go_back()
		return
	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		_confirm()
		return
	var item_count: int = _campaigns.size()
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
	if not _cursor_frame or _item_labels.is_empty():
		return
	var lbl: GradientLabel = _item_labels[_cursor_idx]
	_cursor_frame.size = Vector2(window_size.x - 48, 64)  # 先定尺寸，位置用新尺寸算（修初始偏移）
	var center_y: float = lbl.position.y + lbl.size.y * 0.5  # 用标签实际渲染高居中
	_cursor_frame.position = Vector2(24, center_y - _cursor_frame.size.y * 0.5 + cursor_y_offset)


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
	Global.stop_lobby_music()   # 回标题，让位标题画面自己的 BGM
	get_tree().change_scene_to_file(title_screen_scene)
