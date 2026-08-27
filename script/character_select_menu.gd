extends Control
## 角色选择界面 — 窗口/标题/光标/队伍面板在场景中预置，角色列表代码生成

@export_group("场景路由")
@export var campaign_select_scene: String = "res://scene/campaign_select.tscn"
@export var difficulty_select_scene: String = "res://scene/difficulty_select.tscn"
@export var max_team_size: int = 4

@export_group("窗口布局")
@export var window_size: Vector2 = Vector2(500, 360)
@export var window_pos: Vector2 = Vector2(70, 40)

@export_group("资源路径")
@export var font_path: String = "res://art/System/DotGothic16-Regular.ttf"
@export var font_path_small: String = "res://art/System/ark-pixel-12px-monospaced-zh_cn.ttf"  ## 12px 小字专用
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var color_shader_path: String = "res://shader/text_color.gdshader"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"

@export_group("列表布局")
@export var item_start_y: float = 52.0
@export var item_spacing: float = 44.0
@export var item_font_size: int = 16
@export var small_font_size: int = 12
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

var _available_characters: Array[CharacterData] = []
var _team_selection: Array[int] = []
var _cursor_idx: int = 0
var _cursor_atlas: Array[AtlasTexture] = []
var _cursor_frame_idx: int = 0
var _char_labels: Array[GradientLabel] = []
var _team_slot_labels: Array[Label] = []
var _font_small: FontFile = null


func _ready() -> void:
	_load_defaults_from_global()
	_sync_window()
	_font_small = load(font_path_small) as FontFile
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	var color_img := color_texture.get_image() if color_texture else null
	if color_img:
		_title_label.set_color_image(color_img)
	_load_characters()
	_create_cursor_frames()
	_cursor_frame.texture = _cursor_atlas[0] if _cursor_atlas.size() > 0 else null
	_build_list()
	_build_team_slots()
	_refresh_all()
	_start_cursor_blink()


func _load_defaults_from_global() -> void:
	var g = get_node_or_null("/root/Global")
	if not g:
		return
	if g.text_font_path != "":  font_path = g.text_font_path
	if g.get("text_font_path_small") != "":  font_path_small = g.text_font_path_small
	if g.text_color_sheet_path != "":  color_sheet_path = g.text_color_sheet_path
	if g.text_color_shader_path != "":  color_shader_path = g.text_color_shader_path
	text_color_index = g.text_color_index
	text_color_row = g.text_color_row


func _sync_window() -> void:
	_window.size = window_size
	_window.position = window_pos
	_window_bg.size = window_size
	_window_frame.size = window_size


func _load_characters() -> void:
	_available_characters = CharacterCatalog.load_available_characters()
	for character: CharacterData in _available_characters:
		print("[角色选择] 已加载角色: %s (%s)" % [character.character_name, character.resource_path])
	if _available_characters.is_empty():
		push_error("[角色选择] 没有可用 CharacterData；请检查 CharacterCatalog 的正式角色资源")
	print("[角色选择] 可选角色数量: %d" % _available_characters.size())


func _build_list() -> void:
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	var color_img := color_texture.get_image() if color_texture else null
	for i: int in range(_available_characters.size()):
		var cd: CharacterData = _available_characters[i]
		var cy: float = item_start_y + i * item_spacing

		var name_label := GradientLabel.new()
		name_label.text = "%s  Lv.%d" % [cd.character_name, cd.level]
		name_label.position = Vector2(28, cy)
		name_label.text_font_size = item_font_size
		name_label.color_index = text_color_index
		name_label.color_row = text_color_row
		name_label.use_gradient = true
		name_label.bold = true
		name_label.shadow = true
		name_label.font_path_override = font_path
		name_label.color_sheet_path_override = color_sheet_path
		name_label.color_shader_path_override = color_shader_path
		if color_img:
			name_label.set_color_image(color_img)
		_window.add_child(name_label)
		_char_labels.append(name_label)

		# HP/ATK
		var max_hp: int = cd.get_effective_max_hp()
		var hp_label := GradientLabel.new()
		hp_label.text = "HP:%d  ATK:%d" % [max_hp, cd.get_effective_attack()]
		hp_label.position = Vector2(170, cy + 2)
		hp_label.text_font_size = small_font_size
		hp_label.color_index = text_color_index
		hp_label.color_row = text_color_row
		hp_label.use_gradient = true
		hp_label.bold = true
		hp_label.shadow = true
		hp_label.font_path_override = font_path_small
		hp_label.color_sheet_path_override = color_sheet_path
		hp_label.color_shader_path_override = color_shader_path
		if color_img:
			hp_label.set_color_image(color_img)
		_window.add_child(hp_label)

		var compat_text: String = _get_weapon_compat_text(cd)
		var compat_label := GradientLabel.new()
		compat_label.text = compat_text
		compat_label.position = Vector2(170, cy + 18)
		compat_label.text_font_size = small_font_size
		compat_label.color_index = text_color_index
		compat_label.color_row = text_color_row
		compat_label.use_gradient = true
		compat_label.bold = true
		compat_label.shadow = true
		compat_label.font_path_override = font_path_small
		compat_label.color_sheet_path_override = color_sheet_path
		compat_label.color_shader_path_override = color_shader_path
		if color_img:
			compat_label.set_color_image(color_img)
		_window.add_child(compat_label)


func _build_team_slots() -> void:
	for i: int in range(max_team_size):
		var sy: float = 70.0 + i * 42
		var sl := Label.new()
		sl.text = "%d. —" % (i + 1)
		sl.position = Vector2(348, sy)
		sl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5, 1))
		sl.add_theme_font_size_override("font_size", small_font_size)
		if _font_small:
			sl.add_theme_font_override("font", _font_small)
		_window.add_child(sl)
		_team_slot_labels.append(sl)


func _get_weapon_compat_text(cd: CharacterData) -> String:
	if cd.allowed_primary_weapons.is_empty() and cd.allowed_secondary_weapons.is_empty():
		return "武器: 全部可用"
	var parts: Array[String] = []
	if not cd.allowed_primary_weapons.is_empty():
		parts.append("主: %s" % ", ".join(cd.allowed_primary_weapons))
	if not cd.allowed_secondary_weapons.is_empty():
		parts.append("副: %s" % ", ".join(cd.allowed_secondary_weapons))
	if parts.is_empty():
		return "武器: 全部可用"
	return "武器: %s" % ", ".join(parts)


func _input(event: InputEvent) -> void:
	if _available_characters.is_empty():
		return
	if event.is_action_pressed("取消键"):
		if _team_selection.is_empty():
			_go_back()
		else:
			_team_selection.pop_back()
			_refresh_all()
		return
	if event.is_action_pressed("确定键"):
		_toggle_character()
		return
	if event.is_action_pressed("开始游戏键"):
		if _team_selection.size() > 0:
			_confirm_team()
		return
	var item_count: int = _available_characters.size()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		_refresh_all()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		_refresh_all()


func _toggle_character() -> void:
	var idx: int = _team_selection.find(_cursor_idx)
	if idx != -1:
		_team_selection.remove_at(idx)
	else:
		if _team_selection.size() >= max_team_size:
			return
		_team_selection.append(_cursor_idx)
	_refresh_all()


func _refresh_all() -> void:
	_refresh_cursor()
	_refresh_team_slots()
	for i: int in range(_char_labels.size()):
		_char_labels[i].modulate = Color(1.0, 0.9, 0.2, 1) if _team_selection.has(i) else Color.WHITE


func _refresh_cursor() -> void:
	if not _cursor_frame or _char_labels.is_empty():
		return
	var lbl: GradientLabel = _char_labels[_cursor_idx]
	var center_y: float = lbl.position.y + item_font_size * 0.5
	_cursor_frame.position = Vector2(16, center_y - _cursor_frame.size.y * 0.5 + cursor_y_offset)


func _refresh_team_slots() -> void:
	for i: int in range(max_team_size):
		if i >= _team_slot_labels.size():
			continue
		if i < _team_selection.size():
			var cd: CharacterData = _available_characters[_team_selection[i]]
			_team_slot_labels[i].text = "%d. %s" % [i + 1, cd.character_name]
			_team_slot_labels[i].add_theme_color_override("font_color", Color(0.5, 1.0, 0.5, 1))
		else:
			_team_slot_labels[i].text = "%d. —" % (i + 1)
			_team_slot_labels[i].add_theme_color_override("font_color", Color(0.4, 0.4, 0.5, 1))


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


func _confirm_team() -> void:
	Players.clear_seats()
	for idx: int in _team_selection:
		var cd: CharacterData = _available_characters[idx]
		# duplicate() 让每个座位独占一份 CharacterData 实例，
		# 否则同角色的多个座位会共享运行时字段、并污染资源缓存里的 .tres 母本
		var cd_copy: CharacterData = cd.duplicate()
		cd_copy.init_runtime_hp()
		cd_copy.init_runtime_tp()
		var st: PlayerState = PlayerState.new()
		st.init_from_character(cd_copy, cd.resource_path)
		Players.add_seat(st)
	Players.seats_authored = true
	Players.active_seat_index = 0
	print("[角色选择] 确认队伍: %d人" % Players.seat_count())
	var err: Error = get_tree().change_scene_to_file(difficulty_select_scene)
	if err != OK:
		printerr("[角色选择] 场景切换失败: %s" % difficulty_select_scene)


func _go_back() -> void:
	get_tree().change_scene_to_file(campaign_select_scene)
