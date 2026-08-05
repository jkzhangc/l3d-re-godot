extends CanvasLayer
## 主菜单控制器 — 简化版（仅存档/退出）
##
## 操作：
##   菜单键 → 开关菜单
##   上/下   → 移动光标
##   确定键  → 确认
##   取消键  → 关闭菜单

const CURSOR_SYMBOL: String = "▶"
const MENU_ITEMS: Array[String] = ["继续游戏", "设置", "退出游戏"]
const MENU_ITEMS_NO_SAVE: Array[String] = ["继续游戏", "设置", "退出游戏"]

@export_group("主菜单布局")
@export var menu_cursor_x: float = 24.0
@export var menu_item_start_y: float = 38.0
@export var menu_item_height: float = 24.0
@export var menu_panel_size: Vector2 = Vector2(260, 160)
@export var menu_panel_pos: Vector2 = Vector2(510, 400)

var _menu_open: bool = false
var _cursor_idx: int = 0

var _menu_panel: Panel = null
var _cursor_label: Label = null
var _item_labels: Array[Label] = []

## 设置面板状态
var _in_settings: bool = false
var _settings_cursor_idx: int = 0
var _settings_labels: Array[Label] = []
var _settings_value_labels: Array[Label] = []
var _settings_bar_bg: Array[ColorRect] = []
var _settings_bar_fill: Array[ColorRect] = []
const SETTINGS_ITEMS: Array[String] = ["音乐音量", "音效音量", "固定朝向", "返回"]


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_create_menu()
	hide()


func _input(event: InputEvent) -> void:
	if not _menu_open:
		if event.is_action_pressed("菜单键"):
			if not _is_player_in_weapon_state():
				_open_menu()
		return

	if _in_settings:
		_handle_settings_input(event)
		return

	if event.is_action_pressed("菜单键") or event.is_action_pressed("取消键"):
		_close_menu()
		return

	if event.is_action_pressed("确定键"):
		_menu_confirm()
		return

	var item_count: int = _get_menu_item_count()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		_refresh_cursor()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		_refresh_cursor()


func _open_menu() -> void:
	_menu_open = true
	get_tree().paused = true
	_cursor_idx = 0
	_refresh_cursor()
	show()
	print("[菜单] 打开")


func _close_menu() -> void:
	_menu_open = false
	get_tree().paused = false
	hide()
	print("[菜单] 关闭")


func _create_menu() -> void:
	_menu_panel = _make_panel("MenuPanel", menu_panel_size, menu_panel_pos)
	add_child(_menu_panel)

	var title: Label = _make_label("主菜单", Vector2(60, 8), 16, Color.WHITE)
	title.name = "MenuTitle"
	_menu_panel.add_child(title)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name = "MenuItems"
	vbox.position = Vector2(40, menu_item_start_y)
	vbox.add_theme_constant_override("separation", 6)
	_menu_panel.add_child(vbox)

	for i: int in MENU_ITEMS.size():
		var lbl: Label = Label.new()
		lbl.text = "  %s" % MENU_ITEMS[i]
		lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1))
		lbl.add_theme_font_size_override("font_size", 16)
		vbox.add_child(lbl)
		_item_labels.append(lbl)

	_cursor_label = Label.new()
	_cursor_label.text = CURSOR_SYMBOL
	_cursor_label.position = Vector2(menu_cursor_x, menu_item_start_y)
	_cursor_label.add_theme_color_override("font_color", Color.YELLOW)
	_cursor_label.add_theme_font_size_override("font_size", 15)
	_menu_panel.add_child(_cursor_label)


func _get_menu_item_count() -> int:
	return MENU_ITEMS.size()


func _refresh_cursor() -> void:
	_cursor_label.position = Vector2(menu_cursor_x, menu_item_start_y + _cursor_idx * menu_item_height)


func _menu_confirm() -> void:
	var items: Array[String] = MENU_ITEMS
	var selected: String = items[_cursor_idx]

	match selected:
		"继续游戏":
			_close_menu()
		"设置":
			_enter_settings()
		"退出游戏":
			_close_menu()
			get_tree().quit()


# ═══════════════════════════════════════
# 设置面板
# ═══════════════════════════════════════

func _enter_settings() -> void:
	_in_settings = true
	_settings_cursor_idx = 0
	# 隐藏主菜单项
	for lbl in _item_labels:
		lbl.hide()
	if _cursor_label:
		_cursor_label.hide()
	# 查找并隐藏标题
	var title: Node = _menu_panel.get_node_or_null("MenuTitle")
	if title and title is Label:
		title.hide()
	_build_settings_items()
	_refresh_settings_cursor()


func _exit_settings() -> void:
	_in_settings = false
	_clear_settings_ui()
	# 恢复主菜单项
	for lbl in _item_labels:
		lbl.show()
	if _cursor_label:
		_cursor_label.show()
	var title: Node = _menu_panel.get_node_or_null("MenuTitle")
	if title and title is Label:
		title.show()
	_refresh_cursor()


func _build_settings_items() -> void:
	var panel_w: float = menu_panel_size.x
	var row_step: float = menu_item_height + 6.0
	var start_y: float = 12.0
	var label_x: float = 16.0
	var bar_x: float = 90.0
	var bar_w: float = 100.0
	var bar_h: float = 12.0

	for i: int in range(SETTINGS_ITEMS.size()):
		var pos_y: float = start_y + i * row_step
		var text: String = SETTINGS_ITEMS[i]

		var lbl: Label = _make_label("  %s" % text, Vector2(label_x, pos_y), 16, Color(0.9, 0.9, 0.9, 1))
		_menu_panel.add_child(lbl)
		_settings_labels.append(lbl)

		if i < 2:
			# 音量条
			var bar_y: float = pos_y + (menu_item_height - bar_h) / 2.0

			var bg := ColorRect.new()
			bg.name = "VolBarBg%d" % i
			bg.color = Color(0.15, 0.15, 0.15, 0.8)
			bg.size = Vector2(bar_w, bar_h)
			bg.position = Vector2(bar_x, bar_y)
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_menu_panel.add_child(bg)
			_settings_bar_bg.append(bg)

			var fill := ColorRect.new()
			fill.name = "VolBarFill%d" % i
			fill.color = Color(0.35, 0.35, 0.70, 0.9)
			fill.size = Vector2(bar_w, bar_h)
			fill.position = Vector2(bar_x, bar_y)
			fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_menu_panel.add_child(fill)
			_settings_bar_fill.append(fill)

			var pct := _make_label("", Vector2(bar_x + bar_w + 8, pos_y), 16, Color(0.7, 0.7, 1.0, 1))
			_menu_panel.add_child(pct)
			_settings_value_labels.append(pct)
		elif i == 2:
			var mode_text: String = "切换式" if Global.facing_lock_mode == 0 else "按住式"
			var mode_lbl := _make_label(mode_text, Vector2(bar_x, pos_y), 16, Color(0.7, 0.7, 1.0, 1))
			_menu_panel.add_child(mode_lbl)
			_settings_value_labels.append(mode_lbl)
		else:
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


func _handle_settings_input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		_exit_settings()
		return

	var item_count: int = SETTINGS_ITEMS.size()
	if event.is_action_pressed("上"):
		_settings_cursor_idx = (_settings_cursor_idx - 1 + item_count) % item_count
		_refresh_settings_cursor()
		return
	if event.is_action_pressed("下"):
		_settings_cursor_idx = (_settings_cursor_idx + 1) % item_count
		_refresh_settings_cursor()
		return

	if event.is_action_pressed("确定键"):
		match _settings_cursor_idx:
			2:  # 固定朝向
				var new_mode: int = 1 if Global.facing_lock_mode == 0 else 0
				Global.set_facing_lock_mode(new_mode)
				if _settings_value_labels[2]:
					_settings_value_labels[2].text = "切换式" if new_mode == 0 else "按住式"
			3:  # 返回
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
		0:
			Global.set_music_volume(clampi(Global.music_volume + delta_vol, 0, 100))
			_update_volume_display(0)
		1:
			Global.set_sfx_volume(clampi(Global.sfx_volume + delta_vol, 0, 100))
			_update_volume_display(1)


func _refresh_settings_cursor() -> void:
	if not _cursor_label:
		return
	_cursor_label.show()
	_cursor_label.position.y = 12.0 + _settings_cursor_idx * (menu_item_height + 6.0)
	_cursor_label.position.x = 4.0


func _update_volume_display(idx: int) -> void:
	var vol: int = Global.music_volume if idx == 0 else Global.sfx_volume
	if idx < _settings_value_labels.size() and _settings_value_labels[idx]:
		_settings_value_labels[idx].text = "%d%%" % vol
	if idx < _settings_bar_fill.size() and _settings_bar_fill[idx]:
		_settings_bar_fill[idx].size.x = 100.0 * vol / 100.0


func _update_all_volume_display() -> void:
	_update_volume_display(0)
	_update_volume_display(1)


# ═══════════════════════════════════════
# UI 工具
# ═══════════════════════════════════════

func _make_panel(pname: String, psize: Vector2, ppos: Vector2) -> Panel:
	var p: Panel = Panel.new()
	p.name = pname
	p.size = psize
	p.position = ppos
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.05, 0.05, 0.12, 0.95)
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	s.border_color = Color(0.4, 0.4, 0.6, 0.8)
	s.set_corner_radius_all(6)
	p.add_theme_stylebox_override("panel", s)
	return p


func _make_label(text: String, pos: Vector2, font_size: int, color: Color) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.position = pos
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", font_size)
	return lbl


func _is_player_in_weapon_state() -> bool:
	for node in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(node):
			continue
		if node.has_method("is_facing_locked"):
			return node.player_in_weapon_state
	return false
