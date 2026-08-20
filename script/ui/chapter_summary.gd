class_name ChapterSummary extends CanvasLayer
## L4D2 风格章节总结界面。
## 单人按确定键立即关闭；真正的网络多人模式下，每个玩家确认后才关闭。

signal summary_finished
signal seat_confirmed(seat_index: int)

@export var campaign_title: String = "突袭"
@export var chapter_title: String = "第一章 · 街道"
@export var pause_game: bool = true
@export var auto_show: bool = true
@export var force_multiplayer_preview: bool = false

const FONT_PATH: String = "res://art/System/ark-pixel-16px-monospaced-zh_cn.ttf"
const GOLD: Color = Color("e8c44b")
const PALE: Color = Color("e7e4d7")
const MUTED: Color = Color("8d9186")
const GREEN: Color = Color("8ab45a")

var _confirmed: Dictionary = {}
var _required_seats: Array[int] = []
var _multiplayer_mode: bool = false
var _input_armed: bool = false
var _finishing: bool = false
var _root_control: Control
var _players_box: VBoxContainer
var _status_label: Label
var _prompt_label: Label
var _font: Font


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	layer = 100
	_font = load(FONT_PATH) as Font if ResourceLoader.exists(FONT_PATH) else ThemeDB.fallback_font
	_build_ui()
	if auto_show:
		show_summary()
	else:
		visible = false


func show_summary() -> void:
	visible = true
	_confirmed.clear()
	_finishing = false
	_multiplayer_mode = force_multiplayer_preview or _has_real_multiplayer_session()
	_required_seats = _collect_required_seats()
	_rebuild_player_rows()
	_refresh_status()
	if pause_game:
		get_tree().paused = true
	# 避免安全门的同一次确定键被总结页接收。
	get_tree().create_timer(0.35, true).timeout.connect(func(): _input_armed = true)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not _input_armed or _finishing:
		return
	if event.is_action_pressed("确定键"):
		get_viewport().set_input_as_handled()
		if not _multiplayer_mode:
			_finish_summary()
		else:
			_submit_local_confirmation()


## 供未来联机层或自动化测试直接提交某个座位的确认。
func confirm_seat(seat_index: int) -> void:
	if seat_index not in _required_seats or _confirmed.get(seat_index, false):
		return
	_confirmed[seat_index] = true
	seat_confirmed.emit(seat_index)
	_rebuild_player_rows()
	_refresh_status()
	if _all_players_confirmed():
		_finish_summary()


func _submit_local_confirmation() -> void:
	var seat_index: int = Players.active_seat_index
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		_server_confirm.rpc_id(1, seat_index)
	else:
		_server_confirm(seat_index)


@rpc("any_peer", "call_remote", "reliable")
func _server_confirm(seat_index: int) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	var state: PlayerState = Players.get_seat(seat_index)
	if sender_id > 0 and state and state.owner_peer_id > 0 and state.owner_peer_id != sender_id:
		push_warning("[ChapterSummary] peer %d 不能确认座位 %d" % [sender_id, seat_index])
		return
	confirm_seat(seat_index)
	if multiplayer.has_multiplayer_peer():
		_apply_remote_confirmation.rpc(seat_index)


@rpc("authority", "call_remote", "reliable")
func _apply_remote_confirmation(seat_index: int) -> void:
	confirm_seat(seat_index)


func _has_real_multiplayer_session() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.get_peers().size() > 0


func _collect_required_seats() -> Array[int]:
	var result: Array[int] = []
	if _multiplayer_mode:
		for i: int in range(Players.seat_count()):
			result.append(i)
	else:
		result.append(Players.active_seat_index)
	if result.is_empty():
		result.append(0)
	return result


func _all_players_confirmed() -> bool:
	for seat_index: int in _required_seats:
		if not _confirmed.get(seat_index, false):
			return false
	return true


func _finish_summary() -> void:
	if _finishing:
		return
	_finishing = true
	visible = false
	if pause_game:
		get_tree().paused = false
	summary_finished.emit()
	queue_free()


func _build_ui() -> void:
	_root_control = Control.new()
	_root_control.name = "SummaryRoot"
	_root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root_control)

	var background := ColorRect.new()
	background.color = Color(0.025, 0.035, 0.025, 0.97)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_control.add_child(background)

	var olive_band := ColorRect.new()
	olive_band.color = Color(0.12, 0.14, 0.075, 1.0)
	olive_band.position = Vector2(0, 88)
	olive_band.set_anchors_preset(Control.PRESET_TOP_WIDE)
	olive_band.size.y = 110
	background.add_child(olive_band)

	var left_stripe := ColorRect.new()
	left_stripe.color = GOLD
	left_stripe.position = Vector2(70, 54)
	left_stripe.size = Vector2(9, 620)
	background.add_child(left_stripe)

	var content := VBoxContainer.new()
	content.position = Vector2(110, 48)
	content.size = Vector2(1060, 790)
	content.add_theme_constant_override("separation", 12)
	background.add_child(content)

	var campaign := _make_label(campaign_title.to_upper(), 24, MUTED)
	content.add_child(campaign)
	var complete := _make_label("章节完成", 54, GOLD)
	complete.add_theme_constant_override("outline_size", 4)
	complete.add_theme_color_override("font_outline_color", Color.BLACK)
	content.add_child(complete)
	var chapter := _make_label(chapter_title, 28, PALE)
	content.add_child(chapter)

	var divider := HSeparator.new()
	divider.custom_minimum_size.y = 10
	content.add_child(divider)

	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 22)
	content.add_child(time_row)
	time_row.add_child(_make_label("章节用时", 24, MUTED, Vector2(260, 42)))
	var stats_node: Node = get_node_or_null("/root/ChapterStats")
	var seconds: float = stats_node.get_elapsed_seconds() if stats_node and stats_node.has_method("get_elapsed_seconds") else 0.0
	time_row.add_child(_make_label(_format_time(seconds), 34, PALE))

	var headings := HBoxContainer.new()
	headings.add_theme_constant_override("separation", 8)
	content.add_child(headings)
	for item: Array in [
		["玩家", 300], ["击杀", 120], ["爆头", 120], ["伤害", 140],
		["受伤", 140], ["医疗品", 140], ["状态", 140]
	]:
		headings.add_child(_make_label(item[0], 20, MUTED, Vector2(item[1], 34)))

	_players_box = VBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 5)
	content.add_child(_players_box)

	var spacer := Control.new()
	spacer.custom_minimum_size.y = 18
	content.add_child(spacer)
	_status_label = _make_label("", 25, PALE)
	content.add_child(_status_label)
	_prompt_label = _make_label("", 22, GOLD)
	content.add_child(_prompt_label)


func _rebuild_player_rows() -> void:
	if not _players_box:
		return
	for child: Node in _players_box.get_children():
		child.queue_free()
	var count: int = maxi(Players.seat_count(), 1)
	for seat_index: int in range(count):
		var row := HBoxContainer.new()
		row.custom_minimum_size.y = 48
		row.add_theme_constant_override("separation", 8)
		_players_box.add_child(row)

		var state: PlayerState = Players.get_seat(seat_index)
		var player_name: String = state.get_character_name() if state else "玩家 %d" % (seat_index + 1)
		var stats: Dictionary = _stats_for_seat(seat_index)
		var ready: bool = _confirmed.get(seat_index, false)
		var status_text: String = "已准备" if ready else ("等待" if _multiplayer_mode else "-")
		var status_color: Color = GREEN if ready else MUTED
		var values: Array = [
			[player_name, 300, PALE],
			[str(int(stats.get("kills", 0))), 120, PALE],
			[str(int(stats.get("headshots", 0))), 120, PALE],
			[str(roundi(float(stats.get("damage_dealt", 0.0)))), 140, PALE],
			[str(roundi(float(stats.get("damage_taken", 0.0)))), 140, PALE],
			[str(int(stats.get("healing_items", 0))), 140, PALE],
			[status_text, 140, status_color],
		]
		for value: Array in values:
			row.add_child(_make_label(value[0], 21, value[2], Vector2(value[1], 42)))


func _refresh_status() -> void:
	if not _status_label or not _prompt_label:
		return
	if _multiplayer_mode:
		var ready_count: int = 0
		for seat_index: int in _required_seats:
			if _confirmed.get(seat_index, false):
				ready_count += 1
		_status_label.text = "等待所有玩家    %d / %d" % [ready_count, _required_seats.size()]
		_prompt_label.text = "按 确定键 准备"
	else:
		_status_label.text = "幸存者已抵达安全屋"
		_prompt_label.text = "按 确定键 继续"


func _stats_for_seat(seat_index: int) -> Dictionary:
	var stats_node: Node = get_node_or_null("/root/ChapterStats")
	if stats_node and stats_node.has_method("get_stats_for_seat"):
		return stats_node.get_stats_for_seat(seat_index)
	return {}


func _make_label(text_value: String, font_size: int, color: Color, minimum: Vector2 = Vector2.ZERO) -> Label:
	var label := Label.new()
	label.text = text_value
	label.custom_minimum_size = minimum
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _format_time(seconds: float) -> String:
	var total: int = maxi(0, roundi(seconds))
	return "%02d:%02d" % [total / 60, total % 60]
