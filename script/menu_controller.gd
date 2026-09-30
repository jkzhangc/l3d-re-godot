extends CanvasLayer

## ── 架构定位 ──
## 系统：主菜单 ｜ 层：表现（CanvasLayer）
## 联机：联机时屏蔽武器操作
## 职责：主菜单：继续游戏/设置/退出面板；打开菜单期间屏蔽玩家武器输入。
## 依赖：Global 音量与 UI 音效接口、Player.player_in_weapon_state
##
## 2026-09-15 与标题/选择战役界面同步：
##   ① 窗口换装 RM 皮肤（WindowBg 渐变底图 + WindowFrame 九宫格包边，同款素材）；
##   ② 文字统一 GradientLabel（fusion 像素字体 24px）；
##   ③ 光标换 2 帧九宫格选择框（呼吸闪烁，同标题画面）；
##   ④ 进设置子页窗口放大并居中、退出还原（同标题画面行为）；
##   ⑤ 接入全局 UI 窗口音效（光标/确定/取消，可被本界面导出覆盖）。

## ★2026-09-29 用户需求：第三项原为「退出游戏」直接 `get_tree().quit()`，太粗暴 ——
## 玩家往往只想回主界面。改成「返回标题画面」，统一走 `Global.go_to_title_screen()`
##（该入口会顺带解除暂停 + 退出联机会话，见 global.gd 里的说明）。
const MENU_ITEMS: Array[String] = ["继续游戏", "设置", "返回标题画面"]
## 设置项（2026-09-30：移动端多一项「按键布局」—— 手机端可自由拖动按键/摇杆位置）。
## ⚠ 用函数而非 const（项数随平台变）；「按键布局」插在「返回」之前，
##   所以 0~2（音量 / 固定朝向）的序号在任何平台上都不变。
func _settings_items() -> Array[String]:
	var out: Array[String] = ["音乐音量", "音效音量", "固定朝向"]
	if Global.is_mobile_platform():
		out.append("按键布局")
	out.append("返回")
	return out

## 设置子页窗口尺寸（进设置放大居中、退出还原；同标题画面 SETTINGS_WINDOW_SIZE 思路）
const SETTINGS_WINDOW_SIZE: Vector2 = Vector2(480, 280)
## 音量条几何（GradientLabel 24px 下「  音乐音量」宽约 120px）
const BAR_X: float = 190.0
const BAR_W: float = 160.0
const BAR_H: float = 16.0

@export_group("主菜单布局")
@export var menu_panel_size: Vector2 = Vector2(280, 200)
@export var menu_panel_pos: Vector2 = Vector2(500, 400)

@export_group("菜单项布局")
@export var menu_item_start_y: float = 56.0
@export var menu_item_height: float = 24.0   ## 文字行高（GradientLabel 24px）
@export var menu_item_step: float = 36.0     ## 行距
@export var settings_item_start_y: float = 20.0

@export_group("资源路径")
## 留空 = 跟随「设置 → 界面字体」（2026-09-24）。GradientLabel 会经
## Global.resolve_ui_font_path 解析，所以填可切换字体族的路径同样跟随开关。
@export var font_path: String = ""
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var window_bg_path: String = "res://art/System/Window background color.png"
@export var window_frame_path: String = "res://art/System/Window frame.png"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"
@export var frame_blink_interval: float = 0.3  ## 选择框闪烁间隔（秒）

@export_group("界面音效")
## 留空 = 用 Global 的 ui_*_sfx_path（全局窗口音效参数）
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cursor_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_confirm_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cancel_path: String = ""

var _menu_open: bool = false
var _cursor_idx: int = 0

var _menu_panel: Panel = null
var _window_bg: TextureRect = null
var _window_frame: NinePatchRect = null
var _title_label: GradientLabel = null
var _separator: ColorRect = null
var _item_labels: Array[GradientLabel] = []
var _cursor_frame: NinePatchRect = null
var _cursor_atlas: Array[AtlasTexture] = []
var _cursor_frame_idx: int = 0
var _blink_timer: float = 0.0

## 设置面板状态
var _in_settings: bool = false
var _settings_cursor_idx: int = 0
var _settings_labels: Array[GradientLabel] = []
var _settings_value_labels: Array = []
var _settings_bar_bg: Array[ColorRect] = []
var _settings_bar_fill: Array[ColorRect] = []


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	add_to_group("local_pause_menu")
	_create_menu()
	hide()


func _input(event: InputEvent) -> void:
	if not _menu_open:
		if event.is_action_pressed("菜单键"):
			# 联机角色举枪时 X 仍是菜单键；依据真实武器模式拦截，不能只看单机状态机标志。
			if not _is_player_in_weapon_state():
				Global.play_ui_sfx("cursor", sfx_cursor_path)
				_open_menu()
			_mark_handled()
		return

	if _in_settings:
		## ★必须"**消费了才标记**"（2026-09-30 用户实测：手机进设置后虚拟按键全失效）。
		## 旧实现这里无条件 `_mark_handled()` → `set_input_as_handled()` 会把**所有**事件
		## 从输入队列里掐掉，包括触摸层赖以工作的 `InputEventScreenTouch`：
		## 触摸按钮收不到按下事件 → 连虚拟动作都发不出来 → 手机端进设置页后
		## **摇杆推不动、确定/取消点不动**（画面还停在关卡里，所以只有设置子页坏，
		## 主暂停菜单不坏 —— 那边只对已知动作标记，触摸事件能照常穿过去）。
		## 现在与主菜单分支口径一致：只有真正被设置页吃掉的事件才标记。
		if _handle_settings_input(event):
			_mark_handled()
		return

	if event.is_action_pressed("菜单键") or event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		_close_menu()
		_mark_handled()
		return

	if event.is_action_pressed("确定键"):
		## ★必须先标记"已处理"，再执行菜单动作：
		## 「返回标题画面」会 `change_scene_to_file`，**本节点当场被释放** ——
		## 之后再去 `get_viewport()` 已经是 null，会报
		## "Cannot call method 'set_input_as_handled' on a null value"（用户实测）。
		_mark_handled()
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		_menu_confirm()
		return

	var item_count: int = _get_menu_item_count()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_cursor()
		_mark_handled()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_cursor()
		_mark_handled()


func _process(delta: float) -> void:
	# 选择框 2 帧呼吸闪烁（process_mode=ALWAYS，暂停中也闪，同标题画面）
	if _cursor_atlas.is_empty() or not _cursor_frame:
		return
	_blink_timer += delta
	if _blink_timer < frame_blink_interval:
		return
	_blink_timer = 0.0
	_cursor_frame_idx = 1 - _cursor_frame_idx
	_cursor_frame.texture = _cursor_atlas[_cursor_frame_idx]


func _open_menu() -> void:
	_menu_open = true
	if not _is_online_session():
		get_tree().paused = true
	_cursor_idx = 0
	_refresh_cursor()
	show()
	print("[菜单] 打开")


func _close_menu() -> void:
	_menu_open = false
	if not _is_online_session():
		get_tree().paused = false
	hide()
	print("[菜单] 关闭")


# ═══════════════════════════════════════
# 界面构建
# ═══════════════════════════════════════

func _create_menu() -> void:
	## Panel 仅作容器（自身透明），视觉全部由 RM 底图/九宫格框承担——
	## 与标题/选择战役同款窗口皮肤（2026-09-15 同步）
	_menu_panel = Panel.new()
	_menu_panel.name = "MenuPanel"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	_menu_panel.add_theme_stylebox_override("panel", style)
	_menu_panel.size = menu_panel_size
	_menu_panel.position = menu_panel_pos
	_menu_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_menu_panel)

	_window_bg = TextureRect.new()
	_window_bg.name = "WindowBg"
	_window_bg.texture = load(window_bg_path) as Texture2D
	_window_bg.size = menu_panel_size
	_window_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_panel.add_child(_window_bg)

	_window_frame = NinePatchRect.new()
	_window_frame.name = "WindowFrame"
	_window_frame.texture = load(window_frame_path) as Texture2D
	_window_frame.patch_margin_left = 20
	_window_frame.patch_margin_top = 20
	_window_frame.patch_margin_right = 20
	_window_frame.patch_margin_bottom = 20
	_window_frame.size = menu_panel_size
	_window_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_panel.add_child(_window_frame)

	# 光标选择框：2 帧九宫格（与标题画面同款素材）。
	## 必须在菜单项/设置文字之前创建——Godot 后 add_child 的画在上面，
	## 光标最后创建会把当前行的文字整个盖住（2026-09-15 用户截图复现）。
	var src: Texture2D = load(cursor_frame_path) as Texture2D
	if src:
		for i: int in range(2):
			var at := AtlasTexture.new()
			at.atlas = src
			at.region = Rect2(i * 64, 0, 64, 64)
			at.filter_clip = true
			_cursor_atlas.append(at)
	_cursor_frame = NinePatchRect.new()
	_cursor_frame.name = "CursorFrame"
	_cursor_frame.patch_margin_left = 16
	_cursor_frame.patch_margin_top = 16
	_cursor_frame.patch_margin_right = 16
	_cursor_frame.patch_margin_bottom = 16
	_cursor_frame.size = Vector2(menu_panel_size.x - 24.0, menu_item_step)
	_cursor_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_panel.add_child(_cursor_frame)
	if not _cursor_atlas.is_empty():
		_cursor_frame.texture = _cursor_atlas[0]

	# 标题 + 分隔线（GradientLabel 统一像素字体）
	_title_label = _make_gl("主菜单", Vector2(24, 12), 24)
	_menu_panel.add_child(_title_label)
	_separator = ColorRect.new()
	_separator.color = Color(0.5, 0.5, 0.7, 0.5)
	_separator.size = Vector2(menu_panel_size.x - 32, 1)
	_separator.position = Vector2(16, 46)
	_separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_panel.add_child(_separator)

	# 菜单项
	for i: int in MENU_ITEMS.size():
		var gl := _make_gl("  %s" % MENU_ITEMS[i], Vector2(12, menu_item_start_y + i * menu_item_step), 24)
		_menu_panel.add_child(gl)
		_item_labels.append(gl)
	_refresh_cursor()


## 统一 GradientLabel 构造（fusion 字体 + 色表固定色 + 阴影，同各选择界面观感）
func _make_gl(label_text: String, pos: Vector2, font_size: int) -> GradientLabel:
	var gl := GradientLabel.new()
	gl.text = label_text
	gl.position = pos
	gl.text_font_size = font_size
	gl.color_index = 1
	gl.shadow = true
	gl.font_path_override = font_path
	gl.color_sheet_path_override = color_sheet_path
	return gl


func _get_menu_item_count() -> int:
	return MENU_ITEMS.size()


func _refresh_cursor() -> void:
	if not _cursor_frame:
		return
	_cursor_frame.position = Vector2(
		12.0,
		menu_item_start_y + _cursor_idx * menu_item_step + (menu_item_height - _cursor_frame.size.y) * 0.5
	)


## 标记输入已被本菜单消费。**所有 `set_input_as_handled()` 都走这里**：
## `_input` 里触发动作可能把本节点释放掉（切场景），此时 `get_viewport()` 是 null。
## 顺带保证顺序安全 —— 调用点也应在动作**之前**调它。
func _mark_handled() -> void:
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.set_input_as_handled()


func _menu_confirm() -> void:
	var selected: String = MENU_ITEMS[_cursor_idx]

	match selected:
		"继续游戏":
			_close_menu()
		"设置":
			_enter_settings()
		"返回标题画面":
			_close_menu()
			Global.go_to_title_screen()


# ═══════════════════════════════════════
# 设置面板
# ═══════════════════════════════════════

## 运行时改窗口尺寸（设置页放大 / 退出还原）：窗口、RM 底图、九宫格框同步并居中
## （同标题画面 _apply_window_size 行为，2026-09-15 用户要求设置页窗口也要有变化）
func _apply_window_size(s: Vector2) -> void:
	_menu_panel.size = s
	## ⚠ 按**当前**画布尺寸居中：逻辑画布会随屏幕比例横向加宽（手机 16:9 → 1706），
	## 写死 1280 会让面板停在画布中间偏左。
	## ⚠ 本脚本 extends CanvasLayer（不是 CanvasItem）→ 没有 `get_viewport_rect()`，
	##   必须走 viewport 实例取。
	var canvas: Vector2 = get_viewport().get_visible_rect().size
	_menu_panel.position = Vector2((canvas.x - s.x) * 0.5, (canvas.y - s.y) * 0.5)
	if _window_bg:
		_window_bg.size = s
	if _window_frame:
		_window_frame.size = s
	if _cursor_frame:
		_cursor_frame.size.x = s.x - 24.0


func _enter_settings() -> void:
	_in_settings = true
	_settings_cursor_idx = 0
	_apply_window_size(SETTINGS_WINDOW_SIZE)
	# 隐藏主菜单项与标题
	for lbl in _item_labels:
		lbl.hide()
	if _title_label:
		_title_label.hide()
	if _separator:
		_separator.hide()
	_build_settings_items()
	_refresh_settings_cursor()


func _exit_settings() -> void:
	_in_settings = false
	_clear_settings_ui()
	_apply_window_size(menu_panel_size)
	# 恢复主菜单项与标题
	for lbl in _item_labels:
		lbl.show()
	if _title_label:
		_title_label.show()
	if _separator:
		_separator.show()
	_refresh_cursor()


func _build_settings_items() -> void:
	var items: Array[String] = _settings_items()
	for i: int in range(items.size()):
		var pos_y: float = settings_item_start_y + i * menu_item_step
		var text: String = items[i]

		var gl := _make_gl("  %s" % text, Vector2(12, pos_y), 24)
		_menu_panel.add_child(gl)
		_settings_labels.append(gl)

		if i < 2:
			# 音量条：背景 + 填充 + 百分比标签
			var bar_y: float = pos_y + (menu_item_height - BAR_H) * 0.5

			var bg := ColorRect.new()
			bg.name = "VolBarBg%d" % i
			bg.color = Color(0.15, 0.15, 0.15, 0.8)
			bg.size = Vector2(BAR_W, BAR_H)
			bg.position = Vector2(BAR_X, bar_y)
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_menu_panel.add_child(bg)
			_settings_bar_bg.append(bg)

			var fill := ColorRect.new()
			fill.name = "VolBarFill%d" % i
			fill.color = Color(0.30, 0.30, 0.60, 0.9)
			fill.size = Vector2(BAR_W, BAR_H)
			fill.position = Vector2(BAR_X, bar_y)
			fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_menu_panel.add_child(fill)
			_settings_bar_fill.append(fill)

			var pct := _make_gl("", Vector2(BAR_X + BAR_W + 12, pos_y), 24)
			_menu_panel.add_child(pct)
			_settings_value_labels.append(pct)
		elif i == 2:
			# 固定朝向模式标签
			var mode_text: String = "切换式" if Global.facing_lock_mode == 0 else "按住式"
			var mode_label := _make_gl(mode_text, Vector2(BAR_X, pos_y), 24)
			_menu_panel.add_child(mode_label)
			_settings_value_labels.append(mode_label)
		elif i == items.size() - 2 and Global.is_mobile_platform():
			# 按键布局（2026-09-30，仅移动端）：显示「默认 / 自定义」，
			# 确定键 → 进入触摸层的拖动调整模式（见 _enter_touch_layout_edit）。
			var lay_text: String = "自定义" if Global.has_custom_touch_layout() else "默认"
			var lay_label := _make_gl(lay_text, Vector2(BAR_X, pos_y), 24)
			_menu_panel.add_child(lay_label)
			_settings_value_labels.append(lay_label)
		else:
			# "返回" — 无额外控件
			_settings_value_labels.append(null)

	_update_all_volume_display()


func _clear_settings_ui() -> void:
	for lbl in _settings_labels:
		if is_instance_valid(lbl):
			lbl.queue_free()
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


## 设置页输入。**返回是否消费了该事件** —— 调用方据此决定要不要 `_mark_handled()`。
## ★不要改回"无条件消费"：那会把触摸层的 `InputEventScreenTouch` 一起吞掉，
## 手机端直接失去全部虚拟按键（见 `_input` 顶部注释）。
func _handle_settings_input(event: InputEvent) -> bool:
	if event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		_exit_settings()
		return true

	var items: Array[String] = _settings_items()
	var item_count: int = items.size()
	if event.is_action_pressed("上"):
		_settings_cursor_idx = (_settings_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_settings_cursor()
		return true
	if event.is_action_pressed("下"):
		_settings_cursor_idx = (_settings_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_settings_cursor()
		return true

	## ★按**项名**分派，不硬编码序号（2026-09-30）：移动端多一项「按键布局」，序号会变。
	var cur: String = items[_settings_cursor_idx] if _settings_cursor_idx < items.size() else ""
	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		match cur:
			"固定朝向":
				var new_mode: int = 1 if Global.facing_lock_mode == 0 else 0
				Global.set_facing_lock_mode(new_mode)
				if _settings_value_labels[2]:
					_settings_value_labels[2].text = "切换式" if new_mode == 0 else "按住式"
			"按键布局":
				_enter_touch_layout_edit()
			"返回":
				_exit_settings()
		return true

	# 左/右 调音量
	var delta_vol: int = 0
	if event.is_action_pressed("左"):
		delta_vol = -5
	elif event.is_action_pressed("右"):
		delta_vol = 5
	else:
		return false

	match cur:
		"音乐音量":
			Global.set_music_volume(clampi(Global.music_volume + delta_vol, 0, 100))
			_update_volume_display(0)
		"音效音量":
			Global.set_sfx_volume(clampi(Global.sfx_volume + delta_vol, 0, 100))
			_update_volume_display(1)
	return true


## ── 按键布局调整（2026-09-30，仅移动端）──
## 交给触摸层自己的编辑模式；暂停菜单只负责进入 + 结束后刷新「默认 / 自定义」。
## ⚠ 此时 `get_tree().paused == true` —— 触摸层是 `PROCESS_MODE_ALWAYS`，
##   所以编辑模式照常可操作（这条链路靠用例 ⑩ 的冻结态断言兜着）。
func _enter_touch_layout_edit() -> void:
	var tc: Node = Global.touch_controls()
	if tc == null or not tc.has_method("enter_layout_edit"):
		push_warning("[暂停菜单] 触摸层不存在，无法进入按键布局调整（桌面端属正常）")
		return
	if not tc.is_connected("layout_edit_finished", _on_touch_layout_edit_finished):
		tc.connect("layout_edit_finished", _on_touch_layout_edit_finished)
	tc.call("enter_layout_edit")


func _on_touch_layout_edit_finished(_saved: bool) -> void:
	if not _in_settings:
		return
	_clear_settings_ui()
	_build_settings_items()
	_refresh_settings_cursor()


func _refresh_settings_cursor() -> void:
	if not _cursor_frame:
		return
	_cursor_frame.position = Vector2(
		12.0,
		settings_item_start_y + _settings_cursor_idx * menu_item_step + (menu_item_height - _cursor_frame.size.y) * 0.5
	)


func _update_volume_display(idx: int) -> void:
	var vol: int = Global.music_volume if idx == 0 else Global.sfx_volume
	if idx < _settings_value_labels.size() and _settings_value_labels[idx]:
		_settings_value_labels[idx].text = "%d%%" % vol
	if idx < _settings_bar_fill.size() and _settings_bar_fill[idx]:
		_settings_bar_fill[idx].size.x = BAR_W * vol / 100.0


func _update_all_volume_display() -> void:
	_update_volume_display(0)
	_update_volume_display(1)


# ═══════════════════════════════════════
# 状态查询
# ═══════════════════════════════════════

func is_menu_open() -> bool:
	return _menu_open


func _is_online_session() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and net.is_online_session()


func _is_player_in_weapon_state() -> bool:
	# NetworkWorld is created dynamically by GameInit and owns the authoritative local network entity.
	# During connection or scene transition Players can still point at an old/preplaced node.
	var scene := get_tree().current_scene
	var network_world: Node = scene.get_node_or_null("NetworkWorld") if scene else null
	if network_world and network_world.has_method("is_local_weapon_mode_active"):
		return network_world.is_local_weapon_mode_active()
	var player: Node2D = Players.get_local_entity()
	if player and player.has_method("is_weapon_mode_active"):
		return player.is_weapon_mode_active()
	return false
