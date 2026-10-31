extends Control

## ── 架构定位 ──
## 系统：难度选择 ｜ 层：表现（Control）
## 联机：不涉及
## 职责：难度选择界面（简单/普通/困难/专家），下滚全景背景 + 页标题（角色选择同款视觉），节点全部预置、代码只做逻辑。
## 依赖：Global 文字默认值、PanoramaBackdrop

## 难度选择界面 — 所有节点在场景中预置，代码只做逻辑

const DIFFICULTY_NAMES: Array[String] = ["简单", "普通", "困难", "专家"]
## ── 难度说明（2026-10-30 重写）──
## 每条都是**两行**，与 DescLabel（772×84，字号 24，autowrap）的实际容载对齐：
##   · 第一行 = 敌人强度（血量 / 伤害，取自 Global.difficulty_multipliers）
##              + 紧张度与特感节奏（director_intensity / Players.spawn_scale）
##   · 第二行 = 单人刷怪密度（尸潮 / 区域 / 同屏上限）+ 多人适用范围
## ⚠ 措辞必须与代码一致：
##   · 血量 / 伤害 / 紧张度 → `Global.difficulty_multipliers`（enemy_hp / enemy_damage /
##     director_intensity），**单人与多人共用**。
##   · 尸潮规模 → `Players.spawn_scale()`（含 `difficulty_spawn_scale`，仅单人）。
##   · 区域密度 → `Players.area_spawn_scale()`（复用 enemy_hp 曲线，仅单人）。
##   · 同屏上限 → `Players.scaled_active_cap()`（单人乘 active_cap；
##     多人改按真人数 2 / 2.5 / 3 倍，且**不再叠难度**）。
##   · 特感 / 坦克频率 → `Players.spawn_scale()`（仅单人；多人只按人数）。
##   · **刷怪间隔不随难度缩放**（各难度共用同一条时间节奏）。
##   · 多人局难度只影响血量 / 伤害 / 紧张度；刷怪量、区域密度、同屏上限、特感频率只按真人数。
## ⚠ 每行请保持 ≤ 24 个全角字符（24px × 24 = 576px < 772px），否则会折成三行溢出面板。
const DIFFICULTY_DESCRIPTIONS: Array[String] = [
	"敌人血量 0.7 倍、伤害 0.5 倍，压力与特感更慢。\n单人尸潮/区域/上限更少；多人仅血量伤害压力",
	"敌人血量、伤害 1 倍，压力与特感标准。\n单人尸潮/区域/上限标准；多人仅血量伤害压力",
	"敌人血量、伤害 1.5 倍，压力与特感更快。\n单人尸潮/区域/上限更多；多人仅血量伤害压力",
	"敌人血量、伤害 2 倍，压力与特感最凶。\n单人尸潮/区域/上限最多；多人仅血量伤害压力",
]

## ── 附加参数（2026-10-31 用户需求）──
## 难度列表下方追加三行开关（尸潮狂暴 / 关闭尸潮 / 强制不加压）。
## 语义与存档接线全在 `Global.HORDE_MODIFIER_*`；这里只负责显示与翻转。
## 版式：行距 56、字号 24（12 的整倍），插在 Item3(312) 与 DescPanel 之间。
const MODIFIER_HEADER_TOP: float = 372.0
const MODIFIER_ROW_TOP: float = 404.0
const MODIFIER_ROW_STEP: float = 56.0
const MODIFIER_ROW_FONT: int = 24
## 加了三行之后，描述面板与提示行要整体下移（tscn 里的旧坐标在运行时被覆盖）。
const DESC_PANEL_TOP_AFTER_MODIFIERS: float = 580.0
const HINT_TOP_AFTER_MODIFIERS: float = 700.0

## 每行开关的一句话说明（显示在描述面板；措辞与 `Global.HORDE_MODIFIER_ON_TEXT` 对齐）。
const MODIFIER_DESCRIPTIONS: Dictionary = {
	"berserk": "尸潮时丧尸是否切换狂暴形态（クリムゾンヘッド）。\n关掉只是不变红：规模、血量、伤害都不变",
	"no_horde": "完全不出现尸潮（节奏在加压与喘息之间循环）。\n尸潮 BGM、预警音、尸潮狂暴都会随之消失",
	"no_build_pressure": "导演不再补零星怪（加压预算与喘息补位全关）。\n地图区域刷怪、尸潮、特感、Boss 照常",
}

@export_group("背景")
## 下滚全景背景（角色选择界面同款视觉）；留空路径 = 不加背景。
@export var backdrop_texture_path: String = "res://art/Panorama/地下.png"
@export var backdrop_scale: float = 2.0
@export var backdrop_scroll_speed: float = 20.0
@export var backdrop_dim_alpha: float = 0.35

@export_group("窗口布局")
## 2026-09-14：窗口放大到约占屏幕 2/3，列表/描述同步放大
## 2026-10-31：底部追加「附加参数」三行开关 → 高度 640 → 760（DescPanel/Hint 在
## `_relayout_for_modifiers()` 里同步下移，tscn 里仍是旧坐标，运行时覆盖）。
@export var window_size: Vector2 = Vector2(860, 760)
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
@onready var _desc_panel: Control = $MenuWindow/DescPanel
@onready var _hint_label: Control = $MenuWindow/HintLabel
@onready var _title_label: GradientLabel = $MenuWindow/TitleLabel

var _cursor_idx: int = 1
var _cursor_atlas: Array[AtlasTexture] = []
var _cursor_frame_idx: int = 0
## 附加参数行（运行时创建，顺序 = `Global.HORDE_MODIFIER_ORDER`）。
var _mod_header: Label = null
var _mod_labels: Array[Label] = []


func _ready() -> void:
	Global.play_lobby_music()   # 大厅 BGM：三选择界面共用，切界面不中断（2026-09-13）
	_build_backdrop()
	_load_defaults_from_global()
	_sync_window()
	_relayout_for_modifiers()
	_build_modifier_rows()
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
	## 附加参数行同一套色表（2026-10-31）；标题行随后单独压暗。
	for l: Label in _mod_labels:
		GradientLabel.style_plain_label(
			l, color_img, text_color_index, text_color_row, font, MODIFIER_ROW_FONT)
	if _mod_header != null:
		GradientLabel.style_plain_label(
			_mod_header, color_img, text_color_index, text_color_row, font, MODIFIER_ROW_FONT)
		_mod_header.modulate = Color(0.7, 0.72, 0.7, 1)


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


# ═══════════════════════════════════════
# 附加参数（2026-10-31）
# ═══════════════════════════════════════
## 三行开关插在 Item3(312) 与描述面板之间，所以描述面板 / 提示行整体下移。
## tscn 里仍是旧坐标（440 / 560），这里运行时覆盖 —— 与 `window_size` 的覆盖方式一致。
func _relayout_for_modifiers() -> void:
	if _desc_panel != null:
		_desc_panel.position = Vector2(_desc_panel.position.x, DESC_PANEL_TOP_AFTER_MODIFIERS)
	if _hint_label != null:
		_hint_label.position = Vector2(_hint_label.position.x, HINT_TOP_AFTER_MODIFIERS)


func _build_modifier_rows() -> void:
	_mod_header = _make_plain_label("附加参数（随存档保存）", MODIFIER_ROW_FONT)
	_mod_header.position = Vector2(56.0, MODIFIER_HEADER_TOP)
	_mod_header.size = Vector2(window_size.x - 96.0, 32.0)
	_window.add_child(_mod_header)
	for i: int in range(Global.HORDE_MODIFIER_ORDER.size()):
		var l: Label = _make_plain_label("", MODIFIER_ROW_FONT)
		l.position = Vector2(56.0, MODIFIER_ROW_TOP + float(i) * MODIFIER_ROW_STEP)
		l.size = Vector2(window_size.x - 96.0, 32.0)
		_window.add_child(l)
		_mod_labels.append(l)
	_refresh_modifier_texts()


## 运行时新建的 Label：字体走 `desc_font_path`（与描述文字同一套像素字体），
## 颜色随后由 `_style_plain_labels()` 用色表统一刷一遍。
func _make_plain_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g: Node = get_node_or_null("/root/Global")
	var font: Font = null
	if g and g.has_method("resolve_and_load_font"):
		font = g.resolve_and_load_font(desc_font_path)
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.86, 0.88, 0.84))
	return l


func _refresh_modifier_texts() -> void:
	for i: int in range(_mod_labels.size()):
		var key: String = Global.HORDE_MODIFIER_ORDER[i]
		var on: bool = Global.horde_modifier(key)
		var tail: String = str(Global.HORDE_MODIFIER_ON_TEXT.get(key, "")) if on \
			else str(Global.HORDE_MODIFIER_OFF_TEXT.get(key, ""))
		_mod_labels[i].text = "%s  [%s]  %s" % [
			str(Global.HORDE_MODIFIER_LABELS.get(key, key)), "开" if on else "关", tail]
		## 关掉的行压暗一档：一眼能扫出「这局被改了什么」。
		_mod_labels[i].modulate = Color(1, 1, 1, 1) if on else Color(0.66, 0.68, 0.64, 1)


func _toggle_modifier(mod_index: int) -> void:
	if mod_index < 0 or mod_index >= Global.HORDE_MODIFIER_ORDER.size():
		return
	var key: String = Global.HORDE_MODIFIER_ORDER[mod_index]
	Global.toggle_horde_modifier(key)
	print("[难度选择] 附加参数 %s = %s" % [
		str(Global.HORDE_MODIFIER_LABELS.get(key, key)), "开" if Global.horde_modifier(key) else "关"])
	_refresh_modifier_texts()
	_refresh_description()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		get_tree().change_scene_to_file(character_select_scene)
		return
	if event.is_action_pressed("确定键"):
		if _cursor_idx < DIFFICULTY_NAMES.size():
			Global.play_ui_sfx("confirm", sfx_confirm_path)
			_confirm()
		else:
			## 附加参数行：确定 = 翻转（不离开本界面）
			Global.play_ui_sfx("cursor", sfx_cursor_path)
			_toggle_modifier(_cursor_idx - DIFFICULTY_NAMES.size())
		return
	var item_count: int = _total_item_count()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_all()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_all()
	elif event.is_action_pressed("左") or event.is_action_pressed("右"):
		## 左右也能翻转开关（光标停在参数行的快捷操作）
		if _cursor_idx >= DIFFICULTY_NAMES.size():
			Global.play_ui_sfx("cursor", sfx_cursor_path)
			_toggle_modifier(_cursor_idx - DIFFICULTY_NAMES.size())


## 光标可停的总行数 = 4 个难度 + N 个附加参数。
func _total_item_count() -> int:
	return DIFFICULTY_NAMES.size() + Global.HORDE_MODIFIER_ORDER.size()


func _refresh_all() -> void:
	_refresh_cursor()
	_refresh_description()


func _refresh_cursor() -> void:
	if not _cursor_frame:
		return
	var center_y: float
	var frame_h: float = 64.0
	if _cursor_idx < _item_labels.size():
		var lbl: GradientLabel = _item_labels[_cursor_idx]
		center_y = lbl.position.y + lbl.size.y * 0.5  # 用标签实际渲染高居中
	else:
		## 附加参数行的字号只有 24，框跟着缩（否则 64 高会把上下两行一起框住）
		var ml: Label = _mod_labels[_cursor_idx - _item_labels.size()]
		center_y = ml.position.y + ml.size.y * 0.5
		frame_h = 44.0
	_cursor_frame.size = Vector2(window_size.x - 48, frame_h)  # 先定尺寸，位置用新尺寸算（修初始偏移）
	_cursor_frame.position = Vector2(24, center_y - frame_h * 0.5 + cursor_y_offset)


func _refresh_description() -> void:
	if not _desc_label:
		return
	if _cursor_idx < DIFFICULTY_NAMES.size():
		_desc_label.text = DIFFICULTY_DESCRIPTIONS[_cursor_idx]
		return
	var key: String = Global.HORDE_MODIFIER_ORDER[_cursor_idx - DIFFICULTY_NAMES.size()]
	_desc_label.text = str(MODIFIER_DESCRIPTIONS.get(key, ""))


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
	var err: Error = Global.loading_change_scene(level_path)
	if err != OK:
		printerr("[难度选择] 场景切换失败: %s (err=%d)" % [level_path, err])
