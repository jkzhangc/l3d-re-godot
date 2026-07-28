@tool
extends Control
## VXAnimSprite 可视化编辑器面板
##
## 功能：
##   - 精灵表网格视图（点击格子构建帧序列）
##   - 帧序列面板（缩略图 + 时长编辑）
##   - 实时预览播放（draw 实现，不依赖 Sprite2D 子节点）
##   - 多精灵 cell_data 可视化
##   - 新建/打开/保存动画 .tscn 文件
##
## 编辑模式：
##   场景模式 — 编辑当前场景中选中的 VXAnimSprite 节点
##   文件模式 — 编辑独立的 .tscn 动画文件（可保存/加载）


# ═══════════════════════════════════════
# 注入引用
# ═══════════════════════════════════════

var editor_interface: EditorInterface = null

# ═══════════════════════════════════════
# 编辑状态
# ═══════════════════════════════════════

## 当前编辑目标：VXAnimSprite 节点引用
var _target: VXAnimSprite = null
## 是否编辑场景中的节点（false = 编辑独立文件）
var _editing_scene_node: bool = false
## 独立文件路径（编辑 .tscn 动画文件时）
var _file_path: String = ""

## 缓存的纹理和参数（target 可能不在场景树中）
var _texture: Texture2D = null
var _h_frames: int = 5
var _v_frames: int = 0
var _cell_size: Vector2 = Vector2(192, 192)

## 本地帧序列副本
var _frame_sequence: Array[int] = []
var _frame_durations: Array[float] = []
var _frame_offsets: Array[Vector2] = []
var _position_offset: Vector2 = Vector2.ZERO

## 网格视图状态
var _zoom: float = 1.0
var _scroll_ofs: Vector2 = Vector2.ZERO
var _drag_active: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _scroll_start: Vector2 = Vector2.ZERO
var _hover_cell: Vector2i = Vector2i(-1, -1)
var _selected_seq_idx: int = -1

## 预览状态（用 draw 实现，不用 Sprite2D）
var _playing: bool = false
var _preview_seq_idx: int = 0
var _preview_timer: float = 0.0

# ═══════════════════════════════════════
# UI 节点引用
# ═══════════════════════════════════════

var _toolbar: HBoxContainer = null
var _play_btn: Button = null
var _loop_btn: Button = null
var _fps_spin: SpinBox = null
var _hframes_spin: SpinBox = null
var _mode_option: OptionButton = null
var _sprite_view: VXAnimSheetView = null
var _sequence_container: VBoxContainer = null
var _thumb_row: HBoxContainer = null
var _duration_row: HBoxContainer = null
var _cell_data_section: VBoxContainer = null
var _status_label: Label = null
var _file_label: Label = null

# ═══════════════════════════════════════
# 颜色常量
# ═══════════════════════════════════════

const COLOR_GRID := Color(1, 1, 1, 0.25)
const COLOR_HOVER := Color(1, 0.8, 0, 0.6)
const COLOR_SELECTED := Color(0.3, 0.8, 1, 0.7)
const COLOR_SEQUENCE := Color(0.3, 1, 0.5, 0.55)
const COLOR_SEQUENCE_ACTIVE := Color(0.1, 1, 0.3, 0.8)
const COLOR_BG := Color(0.15, 0.15, 0.15, 1)
const COLOR_PREVIEW := Color(1, 1, 1, 0.5)


# ═══════════════════════════════════════
# 公开接口
# ═══════════════════════════════════════

func edit_object(obj: VXAnimSprite) -> void:
	## 编辑场景中选中的 VXAnimSprite 节点
	_target = obj
	_editing_scene_node = true
	_file_path = ""
	_read_from_target()
	_build_ui()
	_update_sprite_view()
	_update_sequence_panel()
	_update_file_label()
	_update_status()


func clear() -> void:
	_target = null
	_editing_scene_node = false
	_file_path = ""
	_texture = null
	_frame_sequence.clear()
	_frame_durations.clear()
	_frame_offsets.clear()
	_selected_seq_idx = -1
	_hover_cell = Vector2i(-1, -1)
	_stop_preview()
	_clear_ui()
	queue_redraw()


# ═══════════════════════════════════════
# 数据读写
# ═══════════════════════════════════════

func _read_from_target() -> void:
	if not _target:
		return
	_texture = _target.texture
	_h_frames = _target.h_frames
	_v_frames = _target.v_frames
	_frame_sequence = _target.frame_sequence.duplicate()
	_frame_durations = _target.frame_durations.duplicate()
	_frame_offsets = _target.frame_offsets.duplicate()
	_position_offset = _target.position_offset

	if _texture:
		var tw: int = _texture.get_width()
		var th: int = _texture.get_height()
		var vf: int = _v_frames if _v_frames > 0 else maxi(1, int(ceil(float(th) / 192.0)))
		_cell_size = Vector2(float(tw) / _h_frames, float(th) / maxf(1, float(vf)))

	if _fps_spin:
		_fps_spin.value = _target.fps
	if _hframes_spin:
		_hframes_spin.value = _h_frames
	if _mode_option:
		_mode_option.selected = 1 if _target.cell_data.size() > 0 else 0
	if _loop_btn:
		_loop_btn.button_pressed = _target.looping
	_selected_seq_idx = -1


func _write_to_target() -> void:
	if not _target:
		return
	_target.frame_sequence = _frame_sequence.duplicate()
	_target.frame_durations = _frame_durations.duplicate()
	_target.frame_offsets = _frame_offsets.duplicate()
	_target.position_offset = _position_offset
	_target.h_frames = _h_frames
	if _fps_spin:
		_target.fps = float(_fps_spin.value)
	if _loop_btn:
		_target.looping = _loop_btn.button_pressed

	# 如果在编辑场景节点，标记场景已修改
	if _editing_scene_node and editor_interface:
		var scene_root: Node = editor_interface.get_edited_scene_root()
		if scene_root:
			pass  # Godot 自动追踪属性修改

	_update_sprite_view()
	_update_sequence_panel()


func _apply_params_to_target() -> void:
	## 将面板参数批量写入 target（用于新建/文件编辑模式）
	if not _target:
		return
	_target.texture = _texture
	_target.h_frames = _h_frames
	_target.fps = float(_fps_spin.value) if _fps_spin else 10.0
	_target.looping = _loop_btn.button_pressed if _loop_btn else false
	_target.frame_sequence = _frame_sequence.duplicate()
	_target.frame_durations = _frame_durations.duplicate()
	_target.frame_offsets = _frame_offsets.duplicate()
	_target.position_offset = _position_offset


# ═══════════════════════════════════════
# UI 构建
# ═══════════════════════════════════════

func _build_ui() -> void:
	_clear_ui()

	var root := VBoxContainer.new()
	root.name = "Root"
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	add_child(root)

	# ── 工具栏第1行：文件操作 ──
	var file_toolbar := HBoxContainer.new()
	file_toolbar.name = "FileToolbar"
	root.add_child(file_toolbar)

	var new_btn := Button.new()
	new_btn.text = "＋ 新建"
	new_btn.flat = true
	new_btn.tooltip_text = "创建新的动画（未保存）"
	var cb_new: Callable = func(): _on_new_animation()
	new_btn.pressed.connect(cb_new)
	file_toolbar.add_child(new_btn)

	var open_btn := Button.new()
	open_btn.text = "📂 打开"
	open_btn.flat = true
	open_btn.tooltip_text = "打开已保存的 .tscn 动画文件"
	var cb_open: Callable = func(): _on_open_file()
	open_btn.pressed.connect(cb_open)
	file_toolbar.add_child(open_btn)

	var save_btn := Button.new()
	save_btn.text = "💾 保存"
	save_btn.flat = true
	save_btn.tooltip_text = "保存为 .tscn 动画文件"
	var cb_save: Callable = func(): _on_save_file()
	save_btn.pressed.connect(cb_save)
	file_toolbar.add_child(save_btn)

	_file_label = Label.new()
	_file_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1, 1))
	file_toolbar.add_child(_file_label)

	var file_spacer := Control.new()
	file_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_toolbar.add_child(file_spacer)

	# ── 工具栏第2行：播放控制 ──
	_toolbar = HBoxContainer.new()
	_toolbar.name = "PlaybackToolbar"
	root.add_child(_toolbar)

	_play_btn = Button.new()
	_play_btn.text = "▶ 播放"
	_play_btn.flat = true
	var cb_play: Callable = func(): _toggle_play()
	_play_btn.pressed.connect(cb_play)
	_toolbar.add_child(_play_btn)

	_loop_btn = Button.new()
	_loop_btn.text = "↻ 循环"
	_loop_btn.flat = true
	_loop_btn.toggle_mode = true
	_loop_btn.button_pressed = _target.looping if _target else false
	_toolbar.add_child(_loop_btn)

	var sep1 := ColorRect.new()
	sep1.color = Color(1, 1, 1, 0.15)
	sep1.custom_minimum_size = Vector2(1, 20)
	_toolbar.add_child(sep1)

	var fps_label := Label.new()
	fps_label.text = "fps:"
	_toolbar.add_child(fps_label)

	_fps_spin = SpinBox.new()
	_fps_spin.min_value = 0.5
	_fps_spin.max_value = 60.0
	_fps_spin.step = 1.0
	_fps_spin.value = _target.fps if _target else 10.0
	_fps_spin.custom_minimum_size = Vector2(55, 0)
	var cb_fps: Callable = func(v: float): _on_fps_changed(v)
	_fps_spin.value_changed.connect(cb_fps)
	_toolbar.add_child(_fps_spin)

	var sep2 := ColorRect.new()
	sep2.color = Color(1, 1, 1, 0.15)
	sep2.custom_minimum_size = Vector2(1, 20)
	_toolbar.add_child(sep2)

	var hf_label := Label.new()
	hf_label.text = "列数:"
	_toolbar.add_child(hf_label)

	_hframes_spin = SpinBox.new()
	_hframes_spin.min_value = 1
	_hframes_spin.max_value = 20
	_hframes_spin.step = 1
	_hframes_spin.value = _h_frames
	_hframes_spin.custom_minimum_size = Vector2(45, 0)
	var cb_hf: Callable = func(v: float): _on_hframes_changed(int(v))
	_hframes_spin.value_changed.connect(cb_hf)
	_toolbar.add_child(_hframes_spin)

	var sep3 := ColorRect.new()
	sep3.color = Color(1, 1, 1, 0.15)
	sep3.custom_minimum_size = Vector2(1, 20)
	_toolbar.add_child(sep3)

	var mode_label := Label.new()
	mode_label.text = "模式:"
	_toolbar.add_child(mode_label)

	_mode_option = OptionButton.new()
	_mode_option.add_item("单精灵")
	_mode_option.add_item("多精灵")
	_mode_option.selected = 1 if (_target and _target.cell_data.size() > 0) else 0
	var cb_mode: Callable = func(idx: int): _on_mode_changed(idx)
	_mode_option.item_selected.connect(cb_mode)
	_toolbar.add_child(_mode_option)

	var sep_auto := ColorRect.new()
	sep_auto.color = Color(1, 1, 1, 0.15)
	sep_auto.custom_minimum_size = Vector2(1, 20)
	_toolbar.add_child(sep_auto)

	# auto_free 复选框
	var auto_free_cb := CheckBox.new()
	auto_free_cb.text = "播完消除"
	auto_free_cb.tooltip_text = "动画播放完毕后自动 queue_free（auto_free）"
	auto_free_cb.button_pressed = _target.auto_free if _target else true
	var cb_af: Callable = func(toggled: bool):
		if _target:
			_target.auto_free = toggled
	auto_free_cb.toggled.connect(cb_af)
	_toolbar.add_child(auto_free_cb)

	# centered 复选框
	var centered_cb := CheckBox.new()
	centered_cb.text = "居中"
	centered_cb.tooltip_text = "精灵居中锚点（centered）"
	centered_cb.button_pressed = _target.centered if _target else true
	var cb_ct: Callable = func(toggled: bool):
		if _target:
			_target.centered = toggled
	centered_cb.toggled.connect(cb_ct)
	_toolbar.add_child(centered_cb)

	var toolbar_spacer := Control.new()
	toolbar_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sep_off := ColorRect.new()
	sep_off.color = Color(1, 1, 1, 0.15)
	sep_off.custom_minimum_size = Vector2(1, 20)
	_toolbar.add_child(sep_off)

	var off_label := Label.new()
	off_label.text = "整体偏移:"
	_toolbar.add_child(off_label)

	var off_x_spin := SpinBox.new()
	off_x_spin.min_value = -500.0
	off_x_spin.max_value = 500.0
	off_x_spin.step = 1.0
	off_x_spin.value = _position_offset.x
	off_x_spin.custom_minimum_size = Vector2(50, 0)
	off_x_spin.tooltip_text = "整体偏移 X（像素）"
	var cb_ox: Callable = func(v: float): _on_pos_offset_x_changed(v)
	off_x_spin.value_changed.connect(cb_ox)
	_toolbar.add_child(off_x_spin)

	var off_y_spin := SpinBox.new()
	off_y_spin.min_value = -500.0
	off_y_spin.max_value = 500.0
	off_y_spin.step = 1.0
	off_y_spin.value = _position_offset.y
	off_y_spin.custom_minimum_size = Vector2(50, 0)
	off_y_spin.tooltip_text = "整体偏移 Y（像素）"
	var cb_oy: Callable = func(v: float): _on_pos_offset_y_changed(v)
	off_y_spin.value_changed.connect(cb_oy)
	_toolbar.add_child(off_y_spin)
	_toolbar.add_child(toolbar_spacer)

	# ── 主内容区 ──
	var split := HSplitContainer.new()
	split.name = "MainSplit"
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	_sprite_view = VXAnimSheetView.new()
	_sprite_view.name = "SpriteSheetView"
	_sprite_view.custom_minimum_size = Vector2(200, 150)
	_sprite_view.mouse_filter = Control.MOUSE_FILTER_STOP
	split.add_child(_sprite_view)

	# 连接 VXAnimSheetView 的信号
	var cb_click: Callable = func(pat: int): _on_cell_clicked(pat)
	_sprite_view.cell_clicked.connect(cb_click)
	var cb_rclick: Callable = func(pat: int): _remove_pattern_from_sequence(pat)
	_sprite_view.cell_right_clicked.connect(cb_rclick)
	var cb_hover: Callable = func(_pat: int): _update_status()
	_sprite_view.cell_hovered.connect(cb_hover)
	var cb_unhover: Callable = func(): _update_status()
	_sprite_view.cell_unhovered.connect(cb_unhover)

	var right_scroll := ScrollContainer.new()
	right_scroll.name = "RightScroll"
	right_scroll.custom_minimum_size = Vector2(240, 0)
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(right_scroll)

	_sequence_container = VBoxContainer.new()
	_sequence_container.name = "SequencePanel"
	right_scroll.add_child(_sequence_container)

	var seq_title := Label.new()
	seq_title.text = "帧序列 (frame_sequence)"
	seq_title.add_theme_font_size_override("font_size", 13)
	_sequence_container.add_child(seq_title)

	_thumb_row = HBoxContainer.new()
	_thumb_row.name = "ThumbRow"
	_sequence_container.add_child(_thumb_row)

	_duration_row = HBoxContainer.new()
	_duration_row.name = "DurationRow"
	_sequence_container.add_child(_duration_row)

	var sep4 := HSeparator.new()
	_sequence_container.add_child(sep4)

	_cell_data_section = VBoxContainer.new()
	_cell_data_section.name = "CellDataSection"
	_sequence_container.add_child(_cell_data_section)

	var cd_title := Label.new()
	cd_title.text = "多精灵 cell_data"
	cd_title.add_theme_font_size_override("font_size", 13)
	_cell_data_section.add_child(cd_title)

	var cd_hint := Label.new()
	cd_hint.text = "在 Inspector 中编辑 cell_data\n此处显示当前选中帧的配置"
	cd_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1))
	_cell_data_section.add_child(cd_hint)

	# ── 状态栏 ──
	_status_label = Label.new()
	_status_label.name = "StatusBar"
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 1))
	root.add_child(_status_label)

	_sprite_view.focus_mode = Control.FOCUS_ALL

	_update_sequence_panel()
	_update_cell_data_display()
	_update_file_label()


func _clear_ui() -> void:
	for c in get_children():
		c.queue_free()
	_toolbar = null
	_play_btn = null
	_loop_btn = null
	_fps_spin = null
	_hframes_spin = null
	_mode_option = null
	_sprite_view = null
	_sequence_container = null
	_thumb_row = null
	_duration_row = null
	_cell_data_section = null
	_status_label = null
	_file_label = null


func _update_file_label() -> void:
	if not _file_label:
		return
	if _editing_scene_node:
		_file_label.text = "[场景节点]"
	elif not _file_path.is_empty():
		_file_label.text = "[%s]" % _file_path.get_file()
	else:
		_file_label.text = "[未保存]"


# ═══════════════════════════════════════
# 文件操作
# ═══════════════════════════════════════

func _on_new_animation() -> void:
	## 创建新的 VXAnimSprite 用于编辑（不在场景树中）
	_stop_preview()

	_target = VXAnimSprite.new()
	_target.name = "NewAnimation"
	_target.fps = 10.0
	_target.h_frames = 5
	_target.looping = false
	_target.auto_free = true
	_target.centered = true

	_editing_scene_node = false
	_file_path = ""

	_read_from_target()
	_build_ui()
	_update_sprite_view()
	_update_sequence_panel()
	_update_file_label()
	_update_status()
	print("[VXAnimEditor] 已创建新动画")


func _on_open_file() -> void:
	## 打开 .tscn 文件，加载其中的 VXAnimSprite
	if not editor_interface:
		return

	var fd := EditorFileDialog.new()
	fd.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.add_filter("*.tscn", "动画场景文件")
	fd.title = "打开动画文件"

	var cb_file: Callable = func(path: String):
		_load_from_file(path)
	fd.file_selected.connect(cb_file)

	var cb_close: Callable = func():
		fd.queue_free()
	fd.canceled.connect(cb_close)
	fd.close_requested.connect(cb_close)

	editor_interface.get_base_control().add_child(fd)
	fd.popup_centered_ratio(0.6)


func _on_save_file() -> void:
	## 将当前编辑的 target 保存为 .tscn
	if not _target or not editor_interface:
		return

	var fd := EditorFileDialog.new()
	fd.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.add_filter("*.tscn", "动画场景文件")
	fd.title = "保存动画文件"
	if not _file_path.is_empty():
		fd.current_path = _file_path
	else:
		fd.current_file = "anim_effect.tscn"

	var cb_file: Callable = func(path: String):
		_save_to_file(path)
	fd.file_selected.connect(cb_file)

	var cb_close: Callable = func():
		fd.queue_free()
	fd.canceled.connect(cb_close)
	fd.close_requested.connect(cb_close)

	editor_interface.get_base_control().add_child(fd)
	fd.popup_centered_ratio(0.6)


func _save_to_file(path: String) -> void:
	## 将 target 序列化为 PackedScene 并保存
	if not _target:
		return

	_apply_params_to_target()

	# 创建 PackedScene
	var packed := PackedScene.new()
	var result: int = packed.pack(_target)
	if result != OK:
		push_warning("[VXAnimEditor] pack 失败: %d" % result)
		return

	var err: int = ResourceSaver.save(packed, path)
	if err != OK:
		push_warning("[VXAnimEditor] 保存失败: %d" % err)
		return

	_file_path = path
	_editing_scene_node = false
	_update_file_label()
	print("[VXAnimEditor] 已保存: %s" % path)


func _load_from_file(path: String) -> void:
	## 从 .tscn 文件加载 VXAnimSprite
	if not ResourceLoader.exists(path):
		push_warning("[VXAnimEditor] 文件不存在: %s" % path)
		return

	var packed: PackedScene = load(path) as PackedScene
	if not packed:
		push_warning("[VXAnimEditor] 无法加载: %s" % path)
		return

	var node: Node = packed.instantiate()
	if not (node is VXAnimSprite):
		push_warning("[VXAnimEditor] 文件中没有 VXAnimSprite: %s" % path)
		node.queue_free()
		return

	_stop_preview()
	if _target and not _editing_scene_node:
		_target.queue_free()

	_target = node as VXAnimSprite
	_editing_scene_node = false
	_file_path = path

	_read_from_target()
	_build_ui()
	_update_sprite_view()
	_update_sequence_panel()
	_update_file_label()
	_update_status()
	print("[VXAnimEditor] 已打开: %s" % path)


# ═══════════════════════════════════════
# 工具栏回调
# ═══════════════════════════════════════

func _toggle_play() -> void:
	if _playing:
		_stop_preview()
	else:
		_start_preview()


func _on_fps_changed(v: float) -> void:
	if _target:
		_target.fps = float(v)


func _on_pos_offset_x_changed(v: float) -> void:
	_position_offset.x = v
	_write_to_target()


func _on_pos_offset_y_changed(v: float) -> void:
	_position_offset.y = v
	_write_to_target()

func _on_hframes_changed(v: int) -> void:
	_h_frames = v
	if _texture:
		var tw: int = _texture.get_width()
		var th: int = _texture.get_height()
		var vf: int = _v_frames if _v_frames > 0 else maxi(1, int(ceil(float(th) / 192.0)))
		_cell_size = Vector2(float(tw) / _h_frames, float(th) / maxf(1, float(vf)))
	if _target:
		_target.h_frames = v
	_update_sprite_view()
	_update_sequence_panel()


func _on_mode_changed(idx: int) -> void:
	_update_cell_data_display()
	_update_sprite_view()


# ═══════════════════════════════════════
# 精灵表视图 — 绘制
# ═══════════════════════════════════════

func _update_sprite_view() -> void:
	if not _sprite_view:
		return
	_sync_sheet_view()
	# 首次加载纹理时自动适配视图
	if _texture and _zoom == 1.0 and _scroll_ofs == Vector2.ZERO:
		_sprite_view.call_deferred("fit_to_view")
	_sprite_view.queue_redraw()


func _sync_sheet_view() -> void:
	## 将面板状态同步到 VXAnimSheetView
	if not _sprite_view:
		return
	_sprite_view.sheet_texture = _texture
	_sprite_view.sheet_h_frames = _h_frames
	_sprite_view.sheet_v_frames = _v_frames
	_sprite_view.sheet_cell_size = _cell_size
	_sprite_view.sheet_frame_sequence = _frame_sequence
	_sprite_view.sheet_selected_idx = _selected_seq_idx
	_sprite_view.sheet_playing = _playing
	_sprite_view.sheet_preview_idx = _preview_seq_idx if _playing else -1
	_sprite_view.grid_zoom = _zoom
	_sprite_view.grid_scroll = _scroll_ofs

# ═══════════════════════════════════════
# 帧序列编辑
# ═══════════════════════════════════════

func _on_cell_clicked(pattern: int) -> void:
	## 左键点击格子：
	##   不在序列中 → 追加到末尾
	##   已在序列中 → 选中第一个出现位置（不删除）
	var found: int = -1
	for i in range(_frame_sequence.size()):
		if _frame_sequence[i] == pattern:
			found = i
			break

	if found >= 0:
		_selected_seq_idx = found
	else:
		_frame_sequence.append(pattern)
		_selected_seq_idx = _frame_sequence.size() - 1

	_write_to_target()
	_update_sprite_view()
	_update_sequence_panel()
	_update_status()


func _remove_frame_at_index(idx: int) -> void:
	## 从序列中移除指定索引的帧
	if idx < 0 or idx >= _frame_sequence.size():
		return
	_frame_sequence.remove_at(idx)
	if _frame_durations.size() > idx:
		_frame_durations.remove_at(idx)
	if _selected_seq_idx == idx:
		_selected_seq_idx = -1
	elif _selected_seq_idx > idx:
		_selected_seq_idx -= 1
	_write_to_target()
	_update_sprite_view()
	_update_sequence_panel()
	_update_status()


func _move_frame(from_idx: int, to_idx: int) -> void:
	## 交换帧序列中两个帧的位置
	if from_idx < 0 or from_idx >= _frame_sequence.size():
		return
	if to_idx < 0 or to_idx >= _frame_sequence.size():
		return
	if from_idx == to_idx:
		return

	# 交换 sequence
	var tmp_pat: int = _frame_sequence[from_idx]
	_frame_sequence[from_idx] = _frame_sequence[to_idx]
	_frame_sequence[to_idx] = tmp_pat

	# 交换 durations
	if _frame_durations.size() > from_idx and _frame_durations.size() > to_idx:
		var tmp_dur: float = _frame_durations[from_idx]
		_frame_durations[from_idx] = _frame_durations[to_idx]
		_frame_durations[to_idx] = tmp_dur

	# 更新选中
	if _selected_seq_idx == from_idx:
		_selected_seq_idx = to_idx
	elif _selected_seq_idx == to_idx:
		_selected_seq_idx = from_idx

	_write_to_target()
	_update_sprite_view()
	_update_sequence_panel()
	_update_status()


func _remove_pattern_from_sequence(pattern: int) -> void:
	## 右键格子 → 移除该 pattern 的所有出现
	var i: int = _frame_sequence.size() - 1
	while i >= 0:
		if _frame_sequence[i] == pattern:
			_remove_frame_at_index(i)
		i -= 1


# ═══════════════════════════════════════
# 帧序列面板 — 缩略图 + 时长
# ═══════════════════════════════════════

func _update_sequence_panel() -> void:
	if not _thumb_row or not _duration_row:
		return

	for c in _thumb_row.get_children():
		c.queue_free()
	for c in _duration_row.get_children():
		c.queue_free()

	if _frame_sequence.size() == 0:
		var hint := Label.new()
		hint.text = "点击左侧精灵表格子添加帧\n右键格子移除所有该帧"
		hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 1))
		_thumb_row.add_child(hint)
		return

	for i in range(_frame_sequence.size()):
		var pat: int = _frame_sequence[i]
		var cols: int = _h_frames

		# 每帧一个 VBox（缩略图 + 时长 + 删除按钮）
		var frame_box := VBoxContainer.new()
		frame_box.custom_minimum_size = Vector2(58, 0)

		# 帧序号标签
		var idx_label := Label.new()
		idx_label.text = "#%d" % i
		idx_label.add_theme_font_size_override("font_size", 9)
		idx_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1))
		frame_box.add_child(idx_label)

		# 缩略图按钮 + 删除按钮
		var top_row := HBoxContainer.new()

		var thumb := Button.new()
		thumb.custom_minimum_size = Vector2(44, 44)
		thumb.flat = true
		if _texture:
			var tr := TextureRect.new()
			tr.texture = _texture
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.custom_minimum_size = Vector2(40, 40)
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var col: int = pat % cols
			var row: int = pat / cols
			tr.region_enabled = true
			tr.region_rect = Rect2(col * _cell_size.x, row * _cell_size.y, _cell_size.x, _cell_size.y)
			thumb.add_child(tr)

		if i == _selected_seq_idx:
			thumb.add_theme_color_override("icon_normal_color", COLOR_SELECTED)
		else:
			thumb.add_theme_color_override("icon_normal_color", Color(0.3, 0.3, 0.3, 0.5))

		var idx: int = i
		var cb_thumb: Callable = func(): _on_thumb_clicked(idx)
		thumb.pressed.connect(cb_thumb)
		thumb.tooltip_text = "帧 %d: pattern=%d (点击选中)" % [i, pat]
		top_row.add_child(thumb)

		# 删除按钮
		var del_btn := Button.new()
		del_btn.text = "✕"
		del_btn.flat = true
		del_btn.custom_minimum_size = Vector2(16, 16)
		del_btn.add_theme_font_size_override("font_size", 9)
		del_btn.tooltip_text = "删除帧 %d" % i
		var del_idx: int = i
		var cb_del: Callable = func(): _remove_frame_at_index(del_idx)
		del_btn.pressed.connect(cb_del)
		top_row.add_child(del_btn)

		frame_box.add_child(top_row)
		# 排序箭头 ◀ ▶
		var arrow_row := HBoxContainer.new()
		var left_btn := Button.new()
		left_btn.text = "◀"
		left_btn.flat = true
		left_btn.disabled = (i == 0)
		left_btn.custom_minimum_size = Vector2(22, 16)
		left_btn.add_theme_font_size_override("font_size", 8)
		left_btn.tooltip_text = "向前移动"
		var mv_idx: int = i
		var cb_left: Callable = func(): _move_frame(mv_idx, mv_idx - 1)
		left_btn.pressed.connect(cb_left)
		var right_btn := Button.new()
		right_btn.text = "▶"
		right_btn.flat = true
		right_btn.disabled = (i == _frame_sequence.size() - 1)
		right_btn.custom_minimum_size = Vector2(22, 16)
		right_btn.add_theme_font_size_override("font_size", 8)
		right_btn.tooltip_text = "向后移动"
		var cb_right: Callable = func(): _move_frame(mv_idx, mv_idx + 1)
		right_btn.pressed.connect(cb_right)
		arrow_row.add_child(left_btn)
		arrow_row.add_child(right_btn)
		frame_box.add_child(arrow_row)

		# 时长
		var sb := SpinBox.new()
		sb.min_value = 0.01
		sb.max_value = 5.0
		sb.step = 0.01
		sb.value = _get_effective_duration(i)
		sb.custom_minimum_size = Vector2(56, 0)
		sb.tooltip_text = "帧 %d 时长（秒）" % i
		var dur_idx: int = i
		var cb_dur: Callable = func(v: float): _on_duration_changed(dur_idx, v)
		sb.value_changed.connect(cb_dur)
		frame_box.add_child(sb)

		# 帧偏移 X/Y
		var off_row := HBoxContainer.new()
		var offx := SpinBox.new()
		offx.min_value = -500.0
		offx.max_value = 500.0
		offx.step = 1.0
		offx.value = _get_effective_offset_x(dur_idx)
		offx.custom_minimum_size = Vector2(26, 0)
		offx.tooltip_text = "帧 %d X偏移" % dur_idx
		var oidx: int = dur_idx
		var cb_ox2: Callable = func(v: float): _on_frame_offset_changed(oidx, 0, v)
		offx.value_changed.connect(cb_ox2)
		off_row.add_child(offx)

		var offy := SpinBox.new()
		offy.min_value = -500.0
		offy.max_value = 500.0
		offy.step = 1.0
		offy.value = _get_effective_offset_y(dur_idx)
		offy.custom_minimum_size = Vector2(26, 0)
		offy.tooltip_text = "帧 %d Y偏移" % dur_idx
		var cb_oy2: Callable = func(v: float): _on_frame_offset_changed(oidx, 1, v)
		offy.value_changed.connect(cb_oy2)
		off_row.add_child(offy)

		frame_box.add_child(off_row)

		_thumb_row.add_child(frame_box)


func _on_thumb_clicked(idx: int) -> void:
	if idx >= 0 and idx < _frame_sequence.size():
		_selected_seq_idx = idx
		_update_sprite_view()
		_update_sequence_panel()
		_update_cell_data_display()


func _get_effective_duration(idx: int) -> float:
	# 返回帧 idx 的有效时长：优先 frame_durations，否则用 fps 回退
	if idx >= 0 and idx < _frame_durations.size():
		return _frame_durations[idx]
	return 1.0 / maxf(0.1, float(_fps_spin.value) if _fps_spin else 10.0)


func _on_duration_changed(idx: int, v: float) -> void:
	# 用户手动调整某帧时长 → 自动填充 frame_durations 到该索引
	if idx < 0 or idx >= _frame_sequence.size():
		return
	# 补齐缺失项
	var default_dur: float = 1.0 / maxf(0.1, float(_fps_spin.value) if _fps_spin else 10.0)
	while _frame_durations.size() <= idx:
		_frame_durations.append(default_dur)
	_frame_durations[idx] = v
	_write_to_target()


func _get_effective_offset_x(idx: int) -> float:
	if idx >= 0 and idx < _frame_offsets.size():
		return _frame_offsets[idx].x
	return 0.0

func _get_effective_offset_y(idx: int) -> float:
	if idx >= 0 and idx < _frame_offsets.size():
		return _frame_offsets[idx].y
	return 0.0

func _on_frame_offset_changed(idx: int, axis: int, v: float) -> void:
	if idx < 0 or idx >= _frame_sequence.size():
		return
	# 补齐缺失项
	while _frame_offsets.size() <= idx:
		_frame_offsets.append(Vector2.ZERO)
	var cur: Vector2 = _frame_offsets[idx]
	if axis == 0:
		_frame_offsets[idx] = Vector2(v, cur.y)
	else:
		_frame_offsets[idx] = Vector2(cur.x, v)
	_write_to_target()

# ═══════════════════════════════════════
# cell_data 多精灵显示
# ═══════════════════════════════════════

func _update_cell_data_display() -> void:
	if not _cell_data_section:
		return

	var children: Array = _cell_data_section.get_children()
	for i in range(2, children.size()):
		children[i].queue_free()

	if not _target or _target.cell_data.size() == 0:
		return

	var frame_idx: int = _selected_seq_idx if _selected_seq_idx >= 0 else 0

	var sep := HSeparator.new()
	_cell_data_section.add_child(sep)

	var info := Label.new()
	info.text = "当前帧 %d 的 cell 配置:" % frame_idx
	_cell_data_section.add_child(info)

	var count: int = 0
	for cd: VXAnimCellData in _target.cell_data:
		if cd.frame_idx == frame_idx:
			count += 1
			var row := HBoxContainer.new()

			var tr := TextureRect.new()
			if _texture:
				tr.texture = _texture
				tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tr.custom_minimum_size = Vector2(32, 32)
				tr.region_enabled = true
				var cols: int = _h_frames
				var col: int = cd.pattern % cols
				var row_i: int = cd.pattern / cols
				tr.region_rect = Rect2(col * _cell_size.x, row_i * _cell_size.y, _cell_size.x, _cell_size.y)
			row.add_child(tr)

			var params := Label.new()
			params.text = "pat=%d off=(%.0f,%.0f) sc=(%.1f,%.1f) rot=%.0f°" % [
				cd.pattern, cd.offset.x, cd.offset.y, cd.scale.x, cd.scale.y, cd.rotation_deg
			]
			params.add_theme_font_size_override("font_size", 10)
			row.add_child(params)

			_cell_data_section.add_child(row)

	if count == 0:
		var no_data := Label.new()
		no_data.text = "  （此帧无 cell_data 配置）"
		no_data.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 1))
		_cell_data_section.add_child(no_data)


# ═══════════════════════════════════════
# 预览播放（draw 实现，无 Sprite2D 子节点）
# ═══════════════════════════════════════

func _start_preview() -> void:
	if _frame_sequence.size() == 0:
		return
	set_process(true)
	_playing = true
	_preview_seq_idx = 0
	_preview_timer = 0.0
	if _play_btn:
		_play_btn.text = "⏸ 暂停"
	# 播放期间关闭拖拽
	_drag_active = false


func _stop_preview() -> void:
	_playing = false
	set_process(false)
	if _play_btn:
		_play_btn.text = "▶ 播放"
	_update_sprite_view()


func _process(delta: float) -> void:
	if not _playing:
		return
	if _frame_sequence.size() == 0:
		_stop_preview()
		return

	_preview_timer -= delta
	if _preview_timer <= 0.0:
		_preview_seq_idx += 1
		if _preview_seq_idx >= _frame_sequence.size():
			var should_loop: bool = (_loop_btn and _loop_btn.button_pressed) or (_target and _target.looping)
			if should_loop:
				_preview_seq_idx = 0
			else:
				_stop_preview()
				return

		# 下一帧时长
		var dur: float
		if _preview_seq_idx < _frame_durations.size():
			dur = _frame_durations[_preview_seq_idx]
		else:
			dur = 1.0 / maxf(0.1, float(_fps_spin.value) if _fps_spin else 10.0)
		_preview_timer = dur

		_update_sprite_view()


# ═══════════════════════════════════════
# 状态栏
# ═══════════════════════════════════════

func _update_status() -> void:
	if not _status_label:
		return
	var msg: String = ""
	if _texture:
		msg += "纹理: %dx%d | " % [_texture.get_width(), _texture.get_height()]
		var vf: int = _v_frames if _v_frames > 0 else maxi(1, int(ceil(float(_texture.get_height()) / _cell_size.y)))
		msg += "格子: %d×%d (%.0f×%.0fpx) | " % [_h_frames, vf, _cell_size.x, _cell_size.y]
	else:
		msg += "无纹理 | "
	msg += "帧序列: %d 帧" % _frame_sequence.size()
	if _sprite_view and _sprite_view.sheet_hover_cell.x >= 0:
		var hc: Vector2i = _sprite_view.sheet_hover_cell
		var pat: int = hc.y * _h_frames + hc.x
		msg += " | 悬停: (%d,%d) = pattern %d" % [hc.x, hc.y, pat]
	if _selected_seq_idx >= 0 and _selected_seq_idx < _frame_sequence.size():
		msg += " | 选中: 帧[%d] pattern=%d" % [_selected_seq_idx, _frame_sequence[_selected_seq_idx]]
	if _playing:
		msg += " | ▶ 播放中: 帧 %d/%d" % [_preview_seq_idx, _frame_sequence.size()]
	_status_label.text = msg
