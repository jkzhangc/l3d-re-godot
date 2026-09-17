extends Control

## ── 架构定位 ──
## 系统：标题画面 ｜ 层：表现（Control）
## 联机：不涉及
## 职责：RM2K3 风格标题画面：窗口绘制、光标动画、渐变文字与单机/联机入口分流。
## 依赖：GradientLabel、Global 文字默认值

## 标题画面控制器 — RM2K3 风格窗口
##
## 文字颜色：GradientLabel 从色表取固定色（上亮下暗的渐变已移除）。
## 支持阴影（暗色偏移）和粗体（1px 偏移叠加）。
##
## 操作：
##   上/下   → 移动光标
##   确定键  → 确认


const MENU_ITEMS: Array[String] = ["开始游戏", "联机游戏", "操作说明", "设置", "退出游戏"]
const WINDOW_TITLE: String = "のび太的求生之路"

# ═══════════════════════════════════════
# 布局参数
# ═══════════════════════════════════════

@export_group("窗口布局")
## 2026-09-14：5 个菜单项 + RM 窗口样式（角色选择/选择战役同款 WindowBg+WindowFrame）
@export var window_size: Vector2 = Vector2(300, 320)
@export var window_y_offset: float = 130.0
@export var show_title: bool = false
@export var title_position: Vector2 = Vector2(28, 16)
@export var separator_y: float = 60.0
@export var panel_margin: float = 6.0

@export_group("选项布局")
@export var title_font_size: int = 32
@export var item_font_size: int = 32
@export var item_start_y: float = 32.0
@export var item_height: float = 44.0
@export var item_spacing: float = 12.0
@export var item_margin_bottom: float = 0.0
@export var item_title_gap: float = 12.0
@export var item_text_x: float = 6.0
@export var item_width: float = 0.0
@export var item_centered: bool = false

@export_group("文字颜色")
@export var text_color_index: int = 1:
	set(v):
		text_color_index = clampi(v, 0, 19)
@export var text_color_row: int = 0:
	set(v):
		text_color_row = clampi(v, 0, 3)
@export var text_title_color_index: int = 1:
	set(v):
		text_title_color_index = clampi(v, 0, 19)

@export_group("文字效果")
@export var text_bold: bool = true
@export var text_outline: bool = false
@export var text_outline_color: Color = Color.BLACK
@export var text_shadow: bool = true
@export var text_shadow_color: Color = Color(0, 0, 0, 1)
@export var text_shadow_offset: Vector2 = Vector2(2, 2)

@export_group("光标框")
@export var cursor_base_height: float = 48.0
@export var cursor_scale_y: float = 1.0:
	set(v):
		cursor_scale_y = maxf(0.5, snapped(v, 0.5))
@export var cursor_snap_to_item: bool = false
## 选择框默认宽度 = 窗口宽度 - 左右内间距（2026-09-14 用户定稿）；
## cursor_override_width > 0 时仍可强制指定固定宽。
@export var cursor_window_padding: float = 12.0
@export var cursor_offset_y: float = -4.0
@export var cursor_min_width: float = 96.0
@export var cursor_override_width: float = 0.0

@export_group("资源路径")
@export var font_path: String = "res://art/System/DotGothic16-Regular.ttf"
@export var bg_pattern_path: String = "res://art/System/Background pattern for menu screens (16 x 16).png"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"
@export var arrow_down_path: String = "res://art/System/arrow_down.png"
@export var arrow_up_path: String = "res://art/System/arrow_up.png"
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
## RM 窗口样式已节点化（2026-09-15）：WindowBg/WindowFrame/CursorFrame 预置在
## title_screen.tscn 里，编辑器 Inspector 可直接换贴图；脚本按 window_size 同步尺寸。
@export var campaign_select_scene: String = "res://scene/campaign_select.tscn"
@export var controls_guide_scene: String = "res://scene/controls_guide.tscn"

@export_group("界面音效")
## 留空 = 用 Global 的 ui_*_sfx_path。标题画面默认用专属的タイトルカーソル/タイトルキャンセル。
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cursor_path: String = "res://sound/タイトルカーソル.WAV"
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_confirm_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cancel_path: String = "res://sound/タイトルキャンセル.WAV"


var _cursor_idx: int = 0
var _scroll_offset: int = 0
var _visible_items: int = 0

var _scroll_arrow_down: TextureRect = null
var _scroll_arrow_up: TextureRect = null
var _title_gradient_label: GradientLabel = null

var _cursor_atlas: Array[AtlasTexture] = []
var _cursor_frame_idx: int = 0

var _color_img: Image = null

## 设置面板状态
var _in_settings: bool = false
var _settings_cursor_idx: int = 0
var _settings_labels: Array[GradientLabel] = []
var _settings_value_labels: Array[GradientLabel] = []
var _settings_bar_bg: Array[ColorRect] = []
var _settings_bar_fill: Array[ColorRect] = []
const SETTINGS_ITEMS: Array[String] = ["音乐音量", "音效音量", "固定朝向", "文字居中", "返回"]
## 设置页窗口尺寸（2026-09-14）：音量条/数值标签比菜单项宽，进设置时窗口加宽、退出还原
const SETTINGS_WINDOW_SIZE: Vector2 = Vector2(520, 336)
## 音量条宽度——背景条与填充条必须同宽（旧版填充刷新写死 80、背景 160，
## 填充永远只有背景一半长，2026-09-15 用户截图复现）
const SETTINGS_BAR_W: float = 160.0
var _base_window_size: Vector2 = Vector2.ZERO

## 场景节点引用（2026-09-15 节点化）：窗口底图/九宫格框/光标框预置在 title_screen.tscn
@onready var _window_bg: TextureRect = $MenuWindow/WindowBg
@onready var _window_frame: NinePatchRect = $MenuWindow/WindowFrame
@onready var _cursor_frame: NinePatchRect = $MenuWindow/CursorFrame
## 菜单项节点化（2026-09-15）：Item0..Item4 预置在 title_screen.tscn，GradientLabel
## 是 @tool —— 编辑器里直接可见可调字体/字号/位置；运行时复用这些节点，不再删建。
@onready var _menu_item_labels: Array = [
	$MenuWindow/Item0, $MenuWindow/Item1, $MenuWindow/Item2, $MenuWindow/Item3, $MenuWindow/Item4,
]


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════

func _ready() -> void:
	# 仅供双进程联机烟测使用：从默认标题场景直接进入联机大厅，
	# 正常启动和玩家手动进入“联机游戏”菜单的流程不受影响。
	var user_args := OS.get_cmdline_user_args()
	if "--net-test=host" in user_args or "--net-test=client" in user_args:
		print("[标题画面] 检测到联机自动测试参数，跳转到联机大厅")
		call_deferred("_go_to_network_lobby")
		return

	_load_defaults_from_global()
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	_color_img = color_texture.get_image() if color_texture else null
	if _color_img:
		print("[标题画面] 色表已加载 %d×%d" % [_color_img.get_width(), _color_img.get_height()])
	else:
		printerr("[标题画面] 色表加载失败: %s" % color_sheet_path)
	# 将背景音乐路由到 Music 总线
	var bgm: AudioStreamPlayer = get_node_or_null("AudioStreamPlayer")
	if bgm:
		bgm.bus = "Music"
	_create_cursor_frames()
	if _cursor_frame and not _cursor_atlas.is_empty():
		_cursor_frame.texture = _cursor_atlas[0]
	_create_menu_window()
	_base_window_size = window_size
	_refresh_all()
	_start_cursor_blink()
	_build_footer_info()
	_build_update_log_icon()


## ── F1 更新日志（2026-09-17 用户需求）──
## 右上角「F1 更新日志」角标 + RM 窗口样式的更新日志面板（F1/Esc/确定键关闭）。

const CHANGELOG_VERSION_TEXT := "v0.22（2026-09-16 ~ 09-17）"

const CHANGELOG_BODY := """【新内容】
· 新特感ブレインディモス：会吐酸磨损武器、还能抵消子弹，贴脸还有酸爪
· 新武器 7 把：平底锅 / 金属球棒 / 十字弩 / 酸·冰·雷属性弹发射器
· 新增「敌人试验场」与标题画面 F1 更新日志
· 爆头与装填有了专属音效；特效动画支持整体染色

【修复】
· 狙击枪拿不起来 / 换不了
· 女巫和丧尸连续攻击有时不掉血
· 子弹贴脸打不中、靠墙打不出去、十字弩哑火
· 弓弩子弹速度过慢
· 敌人隔着墙也能发现和攻击玩家
· 敌人音效的音调设置不生效
· 学校防守战 60→120 秒（对齐原作）
· 难度选择真正影响敌人血量与攻击
· 角色用不了的武器按 D 不再没反应

【调整】
· 刷怪节奏重做：尸潮改为一波大量涌来、间隔更长；
  平常零星快刷；附近敌人太多且蹲着不动时暂停刷怪，走起来才恢复
· 尸潮的丧尸改从玩家前方出现（不再刷在身后来时的路上）
· 狂暴丧尸力竭倒地后趴一会儿再变回普通形态
· 特感死亡专用倒地图，尸体 3 秒渐隐
· 界面统一像素字体；E 键一次丢弃全部武器"""

var _update_log_icon: GradientLabel = null
var _update_log_panel: Control = null
var _log_content: VBoxContainer = null
var _log_clip_height: float = 0.0
var _scroll_log_y: float = 0.0


## 左下角版本/作者/官网/群信息块（2026-09-16 用户需求）。
## 12px fusion-pixel 基底（字号铁律 12 整数倍），行距 16，沿 1280×960 设计分辨率贴左下。
func _build_footer_info() -> void:
	var version: String = str(ProjectSettings.get_setting("application/config/version", ""))
	var vi: Dictionary = Engine.get_version_info()
	var engine_text: String = "Godot Engine %d.%d" % [int(vi.get("major", 4)), int(vi.get("minor", 6))]
	var lines: Array[String] = []
	if not version.is_empty():
		lines.append("v%s ｜ %s" % [version, engine_text])
	else:
		lines.append(engine_text)
	lines.append("制作：剑客")
	lines.append("官网：https://l3dre.xyz:8443")
	lines.append("QQ交流群：1125775141")
	lines.append("本游戏处于测试阶段，遇到 bug 欢迎在交流群反馈")
	var line_h: float = 28.0
	var bottom_margin: float = 10.0
	var start_y: float = 960.0 - bottom_margin - lines.size() * line_h
	for i: int in lines.size():
		var gl := _make_menu_gradient_label(lines[i], Vector2(14, start_y + i * line_h), 24, text_color_index)
		add_child(gl)


## 右上角「F1 更新日志」角标（12px fusion 基底，贴 1280×960 设计分辨率右上）。
func _build_update_log_icon() -> void:
	if _update_log_icon != null:
		return
	_update_log_icon = _make_menu_gradient_label("F1 更新日志", Vector2.ZERO, 24, text_color_index)
	add_child(_update_log_icon)
	# GradientLabel 自算宽 → 延后一帧按实际宽右对齐
	await get_tree().process_frame
	if _update_log_icon != null and is_instance_valid(_update_log_icon):
		_update_log_icon.position = Vector2(1280.0 - _update_log_icon.size.x - 14.0, 10.0)


func _open_update_log() -> void:
	if _update_log_panel != null:
		return
	Global.play_ui_sfx("confirm", sfx_confirm_path)
	var panel := Control.new()
	panel.name = "UpdateLogPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(dim)

	## 与 controls_guide（操作说明）完全同款窗口：960×840 居中，WindowBg 整图拉伸
	## （默认 STRETCH_SCALE，渐变条平铺会出色带）+ WindowFrame 九宫（margins 20）。
	var win := Control.new()
	win.name = "LogWindow"
	win.size = Vector2(960, 840)
	win.position = ((Vector2(1280, 960) - win.size) * 0.5).floor()
	panel.add_child(win)

	var bg := TextureRect.new()
	bg.texture = load("res://art/System/Window background color.png")
	bg.size = win.size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(bg)

	var frame := NinePatchRect.new()
	frame.texture = load("res://art/System/Window frame.png")
	frame.patch_margin_left = 20
	frame.patch_margin_top = 20
	frame.patch_margin_right = 20
	frame.patch_margin_bottom = 20
	frame.size = win.size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(frame)

	# 标题 36px，两帧后按实际宽居中（GradientLabel 首帧测宽不稳）
	var title := _make_menu_gradient_label("更 新 日 志", Vector2.ZERO, 36, text_color_index)
	win.add_child(title)
	## 居中走 resized 信号跟随——GradientLabel 内部重建时序不稳，帧等待测宽仍会偏；
	## 信号在每次 size 变化时自动回正（2026-09-17 用户反馈"还是不够居中"）。
	title.resized.connect(func() -> void:
		title.position.x = (win.size.x - title.size.x) / 2.0
	)
	title.position.y = 20.0

	# 分隔线（操作说明同款）
	var sep := ColorRect.new()
	sep.color = Color(0.5, 0.5, 0.7, 0.5)
	sep.position = Vector2(24, 72)
	sep.size = Vector2(win.size.x - 48, 2)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(sep)

	# 滚动裁剪区 + VBox 自动排版（操作说明同款，杜绝手算行高溢出）
	var clip := Control.new()
	clip.name = "ScrollClip"
	clip.position = Vector2(28, 88)
	clip.size = Vector2(win.size.x - 56, win.size.y - 88 - 52)
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(clip)

	var flow := VBoxContainer.new()
	flow.name = "Content"
	flow.position = Vector2(6, 6)
	## 不显式设 size（对齐 controls_guide）：高度由子行 min 自动撑起，size.y 才能用于滚动量程
	flow.add_theme_constant_override("separation", 8)
	clip.add_child(flow)
	_log_content = flow
	_log_clip_height = clip.size.y
	_scroll_log_y = 0.0

	var g2: Node = get_node_or_null("/root/Global")
	for line: String in CHANGELOG_BODY.split("\n"):
		if line.strip_edges().is_empty():
			continue
		var lbl := Label.new()
		lbl.text = line
		if g2 and g2.has_method("apply_hint_font"):
			g2.apply_hint_font(lbl, 24)
		if g2 and g2.has_method("apply_text_shadow"):
			g2.apply_text_shadow(lbl)
		if line.begins_with("【"):
			lbl.add_theme_color_override("font_color", Color(1, 0.95, 0.55))
		else:
			lbl.add_theme_color_override("font_color", Color(1, 1, 1))
		## 32px 行高下限（24px 字号的 12 整数倍）：12px 基底像素字实际渲染格比字体报告的
		## 高度更高，按 min size 算会"恰好塞下"→ 滚动范围恒 0、末行被裁剪边切掉
		## （2026-09-17 用户反馈：还是不能滚）。
		lbl.custom_minimum_size = Vector2(0, 32)
		flow.add_child(lbl)

	# 底部提示
	var hint := _make_menu_gradient_label("↑↓ / 滚轮 滚动    F1 / Esc 返回", Vector2(24, win.size.y - 46.0), 24, text_color_index)
	win.add_child(hint)

	add_child(panel)
	_update_log_panel = panel
	print("[标题画面] 打开更新日志（v%s）" % str(ProjectSettings.get_setting("application/config/version", "")))


## 更新日志滚动（内容高于裁剪区时 ↑↓/滚轮 平移 VBox）。
## 更新日志滚动（2026-09-17 手感对齐 controls_guide）：↑↓ 按住连续滚 420px/s + 滚轮。
## 在 _process 里驱动；不显式设 VBox size，量程用 get_combined_minimum_size().y。
func _process_log_scroll(delta: float) -> void:
	if _log_content == null or not is_instance_valid(_log_content):
		return
	var dir: float = 0.0
	if Input.is_action_pressed("上"):
		dir -= 1.0
	if Input.is_action_pressed("下"):
		dir += 1.0
	_scroll_log_y = clampf(_scroll_log_y + dir * 420.0 * delta, 0.0, _log_scroll_max())
	_log_content.position.y = 6.0 - _scroll_log_y


func _log_scroll_max() -> float:
	if _log_content == null or not is_instance_valid(_log_content):
		return 0.0
	return maxf(0.0, _log_content.get_combined_minimum_size().y - _log_clip_height)


func _scroll_update_log(delta_y: float) -> void:
	_scroll_log_y = clampf(_scroll_log_y + delta_y, 0.0, _log_scroll_max())
	_log_content.position.y = 6.0 - _scroll_log_y


func _close_update_log() -> void:
	if _update_log_panel != null and is_instance_valid(_update_log_panel):
		_update_log_panel.queue_free()
	_update_log_panel = null
	_log_content = null
	_scroll_log_y = 0.0
	Global.play_ui_sfx("cursor", sfx_cursor_path)


func _load_defaults_from_global() -> void:
	var g = get_node_or_null("/root/Global")
	if not g:
		return
	## 字体路径以场景导出为准（2026-09-15）：节点化后各界面自管字体，不再被 Global
	## 覆盖——否则设置页等代码构建文字会退回 Global 的 DotGothic（用户截图复现）。
	## 色表路径同理。颜色/阴影等样式参数仍从 Global 同步。
	if g.text_color_sheet_path != "" and color_sheet_path.is_empty():
		color_sheet_path = g.text_color_sheet_path
	text_color_index = g.text_color_index
	text_color_row = g.text_color_row
	text_bold = g.text_bold
	text_outline = g.text_outline
	text_outline_color = g.text_outline_color
	text_shadow = g.text_shadow
	text_shadow_color = g.text_shadow_color
	text_shadow_offset = g.text_shadow_offset
	print("[标题画面] Global 同步 — 色表索引=%d 粗体=%s 描边=%s 阴影=%s" % [text_color_index, text_bold, text_outline, text_shadow])




func _process(delta: float) -> void:
	if _update_log_panel != null:
		_process_log_scroll(delta)


func _input(event: InputEvent) -> void:
	# ── F1 更新日志（2026-09-17）：打开时吞掉全部菜单输入，F1/Esc/确定键关闭 ──
	var f1_pressed: bool = event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_F1
	if _update_log_panel != null:
		if f1_pressed or event.is_action_pressed("取消键") or event.is_action_pressed("确定键"):
			_close_update_log()
			return
		# 滚动：滚轮（↑↓ 的连续滚动在 _process 驱动，这里不再叠加按键跳变，
		# 否则第一次按下会先瞬移 48px 再开始滑——2026-09-17 用户反馈）
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_scroll_update_log(-48.0)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_scroll_update_log(48.0)
			return
		return
	if f1_pressed:
		_open_update_log()
		return

	if _in_settings:
		_handle_settings_input(event)
		return

	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		_confirm()
		return

	var item_count: int = MENU_ITEMS.size()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
	else:
		return

	if _cursor_idx < _scroll_offset:
		_scroll_offset = _cursor_idx
		_rebuild_menu_items()
	elif _cursor_idx >= _scroll_offset + _visible_items:
		_scroll_offset = _cursor_idx - _visible_items + 1
		_rebuild_menu_items()

	_refresh_all()


# ═══════════════════════════════════════
# 色表采样（CPU）
# ═══════════════════════════════════════

func _load_pixel_font(_base_size: int = 16) -> Font:
	var font_file: FontFile = load(font_path) as FontFile
	if not font_file:
		printerr("[标题画面] 无法加载字体: %s" % font_path)
		return ThemeDB.fallback_font
	return font_file


func _measure_text(text: String, font_size: int) -> Vector2:
	var font := _load_pixel_font(font_size)
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)


# ═══════════════════════════════════════
# 光标框
# ═══════════════════════════════════════

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
	timer.timeout.connect(_on_cursor_blink)
	add_child(timer)
	timer.start()


func _on_cursor_blink() -> void:
	if _cursor_atlas.is_empty() or not _cursor_frame:
		return
	_cursor_frame_idx = 1 - _cursor_frame_idx
	_cursor_frame.texture = _cursor_atlas[_cursor_frame_idx]


func _get_cursor_height() -> float:
	return cursor_base_height * cursor_scale_y


## 选择框几何：x = 左内间距，宽 = 窗口宽 - 左右内间距（override > 0 时用固定宽）。
func _cursor_rect_x() -> float:
	return cursor_window_padding


func _cursor_rect_w() -> float:
	if cursor_override_width > 0.0:
		return cursor_override_width
	return maxf(window_size.x - cursor_window_padding * 2.0, cursor_min_width)


func _calc_max_text_width() -> float:
	var max_w: float = 0.0
	for item: String in MENU_ITEMS:
		var ts := _measure_text("  %s" % item, item_font_size)
		max_w = maxf(max_w, ts.x)
	return max_w


func _get_item_area_width() -> float:
	if item_width > 0.0:
		return item_width
	return _calc_max_text_width()


func _get_item_x() -> float:
	if not _is_centered():
		return item_text_x
	return item_text_x  ## 居中时由调用方按 GradientLabel 实际宽度二次定位（见 _center_label）


## 是否启用文字居中：旧 export（item_centered）或设置开关（Global.menu_item_centered）。
func _is_centered() -> bool:
	if item_centered:
		return true
	var g: Node = get_node_or_null("/root/Global")
	return g != null and bool(g.get("menu_item_centered"))


## 按 GradientLabel 自算的实际文本宽做真居中（旧逻辑用 DotGothic 量宽，
## 与实际渲染字体不一致导致永远歪）。size 未就绪时回退整窗居中。
func _center_label(gl: GradientLabel) -> float:
	var w: float = gl.size.x
	if w <= 0.0:
		w = _measure_text(gl.text, item_font_size).x
	gl.position.x = (window_size.x - w) / 2.0
	return gl.position.x


# ═══════════════════════════════════════
# 窗口构建
# ═══════════════════════════════════════

func _create_menu_window() -> void:
	var win: Control = $MenuWindow

	win.position = Vector2(
		(1280.0 - window_size.x) / 2.0,
		(960.0 - window_size.y) / 2.0 + window_y_offset
	)
	win.size = window_size

	# 窗口底图/九宫格框：节点化（2026-09-15），视觉元素在 title_screen.tscn 里，
	# 这里只按 window_size 同步尺寸（设置页加宽/还原共用 _apply_window_size）
	_window_bg.size = window_size
	_window_frame.size = window_size

	# 标题（可选）
	if show_title:
		_title_gradient_label = _make_menu_gradient_label(WINDOW_TITLE, title_position, title_font_size, text_title_color_index)
		win.add_child(_title_gradient_label)

		var sep := ColorRect.new()
		sep.name = "Separator"
		sep.color = Color(0.5, 0.5, 0.7, 0.5)
		sep.size = Vector2(window_size.x - 32, 1)
		sep.position = Vector2(16, separator_y)
		win.add_child(sep)

	# 可见区域
	var start_y: float = separator_y + item_title_gap if show_title else item_start_y
	var avail_h: float = window_size.y - start_y - item_margin_bottom
	var row_step: float = item_height + item_spacing
	_visible_items = clampi(int(avail_h / row_step), 1, MENU_ITEMS.size())

	# 光标框：节点化（tscn 预置），这里只按导出参数摆初始几何；
	# 宽度默认 = 窗口宽 - 左右内间距，之后 _refresh_cursor_frame 每次刷新
	if _cursor_frame:
		_cursor_frame.size = Vector2(_cursor_rect_w(), _get_cursor_height())
		_cursor_frame.position = Vector2(
			_cursor_rect_x(),
			item_start_y + (item_height - _get_cursor_height()) / 2.0 + cursor_offset_y
		)
	# 菜单项
	_rebuild_menu_items()

	# 滚动箭头
	_create_scroll_arrow(win, arrow_down_path, "ScrollArrowDown",
		item_start_y + _visible_items * row_step + 4)
	_create_scroll_arrow(win, arrow_up_path, "ScrollArrowUp",
		item_start_y - 16)


func _create_scroll_arrow(parent: Control, path: String, pname: String, pos_y: float) -> void:
	var tex: Texture2D = load(path) as Texture2D
	if not tex:
		return
	var arrow := TextureRect.new()
	arrow.name = pname
	arrow.texture = tex
	arrow.size = tex.get_size()
	arrow.position = Vector2((window_size.x - tex.get_size().x) / 2.0, pos_y)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.hide()
	parent.add_child(arrow)
	if pname == "ScrollArrowDown":
		_scroll_arrow_down = arrow
	else:
		_scroll_arrow_up = arrow


func _rebuild_menu_items() -> void:
	## 菜单项已节点化（Item0..Item4 预置在 title_screen.tscn，编辑器直接调样式）。
	## 运行时只同步文本（居中开关加/去前缀）与位置，不再删建节点。
	var end_idx: int = mini(_scroll_offset + _visible_items, MENU_ITEMS.size())
	for i: int in range(MENU_ITEMS.size()):
		if i >= _menu_item_labels.size():
			break
		var gl: GradientLabel = _menu_item_labels[i]
		if i < _scroll_offset or i >= end_idx:
			gl.hide()
			continue
		var display_idx: int = i - _scroll_offset
		# 居中模式去掉 "  " 前缀空格——否则量宽连空格一起居中，文字整体右偏
		var item_text := MENU_ITEMS[i] if _is_centered() else "  %s" % MENU_ITEMS[i]
		gl.text = item_text
		## 文字行内垂直位置（2026-09-15 两轮实测校准）：完全顶行首偏上、居中偏移
		## (44-24)/2=10 又偏下，+5（行高差四分之一）正好——fusion 度量 ascent20/descent4
		var text_y: float = item_start_y + display_idx * (item_height + item_spacing) \
				+ (item_height - item_font_size) * 0.25
		gl.position = Vector2(_get_item_x(), text_y)
		if item_width > 0.0:
			gl.size.x = item_width
		# 文字居中排列：按 GradientLabel 自算的实际文本宽二次定位
		if _is_centered():
			_center_label(gl)
		gl.show()

	_update_scroll_arrows()


func _make_menu_gradient_label(label_text: String, pos: Vector2, font_size: int, color_idx: int) -> GradientLabel:
	var gl := GradientLabel.new()
	gl.text = label_text
	gl.position = pos
	gl.text_font_size = font_size
	gl.color_index = color_idx
	gl.color_row = text_color_row
	gl.bold = text_bold
	gl.shadow = text_shadow
	gl.shadow_color = text_shadow_color
	gl.shadow_offset = text_shadow_offset
	gl.outline = text_outline
	gl.outline_color = text_outline_color
	gl.font_path_override = font_path
	gl.color_sheet_path_override = color_sheet_path
	if _color_img:
		gl.set_color_image(_color_img)
	return gl


## 菜单项显隐（进设置页时隐藏节点化菜单项，退出恢复）
func _set_menu_items_visible(v: bool) -> void:
	for gl in _menu_item_labels:
		if is_instance_valid(gl):
			gl.visible = v


func _update_scroll_arrows() -> void:
	if _scroll_arrow_down:
		_scroll_arrow_down.visible = (_scroll_offset + _visible_items < MENU_ITEMS.size())
	if _scroll_arrow_up:
		_scroll_arrow_up.visible = (_scroll_offset > 0)


# ═══════════════════════════════════════
# 交互
# ═══════════════════════════════════════

func _refresh_all() -> void:
	_refresh_cursor_frame()
	_update_scroll_arrows()


func _refresh_cursor_frame() -> void:
	if not _cursor_frame:
		return
	var display_idx: int = _cursor_idx - _scroll_offset
	var cur_h := _cursor_frame.size.y
	_cursor_frame.position.y = item_start_y + display_idx * (item_height + item_spacing) + (item_height - cur_h) / 2.0 + cursor_offset_y
	# 宽度/横向位置随窗口尺寸实时同步（设置页加宽/还原时选择框跟着变）
	_cursor_frame.size.x = _cursor_rect_w()
	_cursor_frame.position.x = _cursor_rect_x()


func _confirm() -> void:
	match MENU_ITEMS[_cursor_idx]:
		"开始游戏":
			_go_to_campaign_select()
		"联机游戏":
			_go_to_network_lobby()
		"操作说明":
			_go_to_controls_guide()
		"设置":
			_enter_settings()
		"退出游戏":
			_quit_game()


## 操作说明（2026-09-14 新增菜单项）：界面与 txt 文档内容待用户确认后实现，
## 届时切换到 controls_guide_scene；确认前先占位避免误触无反应。
func _go_to_controls_guide() -> void:
	if ResourceLoader.exists(controls_guide_scene):
		var err: Error = get_tree().change_scene_to_file(controls_guide_scene)
		if err != OK:
			printerr("[标题画面] 操作说明场景切换失败: %d" % err)
		return
	print("[标题画面] 操作说明界面尚未实现（内容待用户确认）")


# ═══════════════════════════════════════
# 设置面板
# ═══════════════════════════════════════

func _apply_window_size(s: Vector2) -> void:
	## 运行时改窗口尺寸（设置页加宽 / 退出还原）：窗口、RM 底图、九宫格框同步，
	## 并按新尺寸重新居中。
	window_size = s
	var win: Control = $MenuWindow
	win.position = Vector2(
		(1280.0 - s.x) / 2.0,
		(960.0 - s.y) / 2.0 + window_y_offset
	)
	win.size = s
	if _window_bg:
		_window_bg.size = s
	if _window_frame:
		_window_frame.size = s


func _enter_settings() -> void:
	_in_settings = true
	_settings_cursor_idx = 0
	_apply_window_size(SETTINGS_WINDOW_SIZE)
	_set_menu_items_visible(false)
	_build_settings_items()
	_refresh_settings_cursor()


func _exit_settings() -> void:
	_in_settings = false
	_clear_settings_ui()
	_apply_window_size(_base_window_size)
	_rebuild_menu_items()
	_refresh_all()


func _build_settings_items() -> void:
	var win: Control = $MenuWindow
	var row_step: float = item_height + item_spacing
	var start_y: float = item_start_y
	var label_x: float = item_text_x
	var bar_x: float = label_x + _measure_text("  音乐音量", item_font_size).x + 16.0
	var bar_w: float = SETTINGS_BAR_W
	var bar_h: float = 24.0

	for i: int in range(SETTINGS_ITEMS.size()):
		var pos_y: float = start_y + i * row_step
		var text: String = SETTINGS_ITEMS[i]

		var gl := _make_menu_gradient_label("  %s" % text, Vector2(label_x, pos_y), item_font_size, text_color_index)
		win.add_child(gl)
		_settings_labels.append(gl)
		if i < 2:
			# 音量条：背景 + 填充 + 百分比标签
			var bar_y: float = pos_y + (item_height - bar_h) / 2.0

			var bg := ColorRect.new()
			bg.name = "VolBarBg%d" % i
			bg.color = Color(0.15, 0.15, 0.15, 0.8)
			bg.size = Vector2(bar_w, bar_h)
			bg.position = Vector2(bar_x, bar_y)
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			win.add_child(bg)
			_settings_bar_bg.append(bg)

			var fill := ColorRect.new()
			fill.name = "VolBarFill%d" % i
			fill.color = Color(0.30, 0.30, 0.60, 0.9)
			fill.size = Vector2(bar_w, bar_h)
			fill.position = Vector2(bar_x, bar_y)
			fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			win.add_child(fill)
			_settings_bar_fill.append(fill)

			var pct_label := _make_menu_gradient_label("", Vector2(bar_x + bar_w + 12, pos_y), item_font_size, text_color_index)
			win.add_child(pct_label)
			_settings_value_labels.append(pct_label)
		elif i == 2:
			# 固定朝向模式标签
			var mode_text: String = "切换式" if Global.facing_lock_mode == 0 else "按住式"
			var mode_label := _make_menu_gradient_label(mode_text, Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(mode_label)
			_settings_value_labels.append(mode_label)
		elif i == 3:
			# 文字居中开关（2026-09-14 新增）
			var center_text: String = "开" if Global.menu_item_centered else "关"
			var center_label := _make_menu_gradient_label(center_text, Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(center_label)
			_settings_value_labels.append(center_label)
		else:
			# "返回" — 无额外控件
			_settings_value_labels.append(null)

	_update_all_settings_volume_display()


func _clear_settings_ui() -> void:
	for gl in _settings_labels:
		if is_instance_valid(gl):
			gl.queue_free()
	_settings_labels.clear()
	for vl in _settings_value_labels:
		if is_instance_valid(vl):
			vl.queue_free()
	_settings_value_labels.clear()
	for bg in _settings_bar_bg:
		if is_instance_valid(bg):
			bg.queue_free()
	_settings_bar_bg.clear()
	for fg in _settings_bar_fill:
		if is_instance_valid(fg):
			fg.queue_free()
	_settings_bar_fill.clear()


func _handle_settings_input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		_exit_settings()
		return

	var item_count: int = SETTINGS_ITEMS.size()
	if event.is_action_pressed("上"):
		_settings_cursor_idx = (_settings_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_settings_cursor()
		return
	if event.is_action_pressed("下"):
		_settings_cursor_idx = (_settings_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_settings_cursor()
		return

	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		match _settings_cursor_idx:
			2:  # 固定朝向
				var new_mode: int = 1 if Global.facing_lock_mode == 0 else 0
				Global.set_facing_lock_mode(new_mode)
				var mode_text: String = "切换式" if new_mode == 0 else "按住式"
				if _settings_value_labels[2]:
					_settings_value_labels[2].text = mode_text
			3:  # 文字居中（2026-09-14 新增开关）
				Global.menu_item_centered = not Global.menu_item_centered
				if _settings_value_labels[3]:
					_settings_value_labels[3].text = "开" if Global.menu_item_centered else "关"
				# 立即重排当前设置行（标签居中、音量条跟随）
				_clear_settings_ui()
				_build_settings_items()
				_refresh_settings_cursor()
			4:  # 返回
				_exit_settings()
		return

	# 左/右 调音量
	var delta_vol: int = 0
	if event.is_action_pressed("左"):
		delta_vol = -5
	elif event.is_action_pressed("右"):
		delta_vol = 5
	else:
		return

	match _settings_cursor_idx:
		0:  # 音乐音量
			Global.set_music_volume(clampi(Global.music_volume + delta_vol, 0, 100))
			_update_settings_volume_display(0)
		1:  # 音效音量
			Global.set_sfx_volume(clampi(Global.sfx_volume + delta_vol, 0, 100))
			_update_settings_volume_display(1)


func _refresh_settings_cursor() -> void:
	if not _cursor_frame:
		return
	var cur_h := _cursor_frame.size.y
	_cursor_frame.position.y = item_start_y + _settings_cursor_idx * (item_height + item_spacing) + (item_height - cur_h) / 2.0 + cursor_offset_y
	_cursor_frame.size.x = _cursor_rect_w()
	_cursor_frame.position.x = _cursor_rect_x()


func _update_settings_volume_display(idx: int) -> void:
	var vol: int = Global.music_volume if idx == 0 else Global.sfx_volume
	if idx < _settings_value_labels.size() and _settings_value_labels[idx]:
		_settings_value_labels[idx].text = "%d%%" % vol
	if idx < _settings_bar_fill.size() and _settings_bar_fill[idx]:
		_settings_bar_fill[idx].size.x = SETTINGS_BAR_W * vol / 100.0


func _update_all_settings_volume_display() -> void:
	_update_settings_volume_display(0)
	_update_settings_volume_display(1)

func _go_to_network_lobby() -> void:
	const lobby_scene := "res://scene/network_lobby.tscn"
	print("[标题画面] 联机游戏 → 大厅")
	var err: Error = get_tree().change_scene_to_file(lobby_scene)
	if err != OK:
		printerr("[标题画面] 大厅场景切换失败: %s (err=%d)" % [lobby_scene, err])

func _go_to_campaign_select() -> void:
	print("[标题画面] 开始游戏 → 战役选择")
	var err: Error = get_tree().change_scene_to_file(campaign_select_scene)
	if err != OK:
		printerr("[标题画面] 场景切换失败: %s (err=%d)" % [campaign_select_scene, err])


func _quit_game() -> void:
	print("[标题画面] 退出游戏")
	get_tree().quit()
