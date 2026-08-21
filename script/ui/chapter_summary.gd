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
@export_group("音频")
@export var summary_music: AudioStream
@export var summary_music_volume_db: float = 0.0

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
## 切图到安全屋时，客户端的确认包可能比 Host 新场景的 PlayerState/seat 绑定早一帧抵达。
## 暂存 peer 身份并在暂停状态下重试，绝不把客户端的本地 seat 编号当作网络身份。
var _pending_peer_confirmations: Dictionary = {} # Host: peer_id -> expiry_msec
## Client 也可能先收到 Host 的确认广播、后创建对应 PlayerState。
var _pending_remote_confirmations: Dictionary = {} # Client: peer_id -> expiry_msec
## Host 广播确认后，短暂保留节点让可靠 RPC 在关闭总结页前完成 flush。
var _pending_local_confirmations: Dictionary = {} # seat_index -> true
## 章节结算由 Host 汇总 peer_id；Client 只呈现确认状态，完成信号由 Host 可靠下发。
var _confirmed_peer_ids: Dictionary = {}
var _network_completion_started: bool = false
var _root_control: Control
var _players_box: VBoxContainer
var _status_label: Label
var _prompt_label: Label
var _font: Font
var _music_player: AudioStreamPlayer


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
	_pending_peer_confirmations.clear()
	_pending_remote_confirmations.clear()
	_pending_local_confirmations.clear()
	_confirmed_peer_ids.clear()
	_network_completion_started = false
	_finishing = false
	_input_armed = false
	_multiplayer_mode = force_multiplayer_preview or _has_real_multiplayer_session()
	_required_seats = _collect_required_seats()
	_sync_required_multiplayer_seats()
	_rebuild_player_rows()
	_refresh_status()
	_play_summary_music()
	if pause_game:
		get_tree().paused = true
	# 避免安全门的同一次确定键被总结页接收。
	get_tree().create_timer(0.35, true).timeout.connect(func(): _input_armed = true)
	if _is_auto_safe_door_test():
		call_deferred("_run_auto_safe_door_summary_test")


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
	_sync_required_multiplayer_seats()
	if seat_index not in _required_seats or _confirmed.get(seat_index, false):
		return
	_confirmed[seat_index] = true
	seat_confirmed.emit(seat_index)
	_rebuild_player_rows()
	_refresh_status()
	if not _multiplayer_mode and _all_players_confirmed():
		_finish_summary()
	elif _multiplayer_mode and multiplayer.is_server():
		_try_complete_network_summary()


func _submit_local_confirmation() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		# 客户端不得上传本地 seat 编号：每台机器的 active_seat_index 不是网络身份。
		_server_confirm.rpc_id(1)
		return
	var local_peer_id := _get_local_peer_id()
	var seat_index := _find_seat_owned_by_peer(local_peer_id)
	if seat_index < 0:
		seat_index = Players.active_seat_index
	_server_confirm_local(seat_index)


func _server_confirm_local(seat_index: int) -> void:
	if seat_index < 0 or _confirmed.get(seat_index, false) or _pending_local_confirmations.has(seat_index):
		return
	var state: PlayerState = Players.get_seat(seat_index)
	var peer_id := state.owner_peer_id if state else 0
	if peer_id <= 0:
		return
	_confirmed_peer_ids[peer_id] = true
	if multiplayer.has_multiplayer_peer():
		# 先可靠广播并留出一个网络轮询窗口；最后一名 Host 确认若立即关闭/释放
		# 总结页，Client 可能永远收不到 Host 的最终确认。
		_broadcast_remote_confirmation(peer_id)
		_pending_local_confirmations[seat_index] = true
		call_deferred("_confirm_local_after_network_flush", seat_index, peer_id)
		return
	confirm_seat(seat_index)
	print("[ChapterSummary] CONFIRM_APPLIED peer=%d seat=%d" % [peer_id, seat_index])


func _confirm_local_after_network_flush(seat_index: int, peer_id: int) -> void:
	var tree := get_tree()
	if not tree:
		_pending_local_confirmations.erase(seat_index)
		return
	await tree.create_timer(0.06, true).timeout
	_pending_local_confirmations.erase(seat_index)
	if not is_instance_valid(self) or _finishing or not visible:
		return
	confirm_seat(seat_index)
	print("[ChapterSummary] CONFIRM_APPLIED peer=%d seat=%d" % [peer_id, seat_index])


func _try_complete_network_summary() -> void:
	if not _multiplayer_mode or not multiplayer.is_server() or _network_completion_started:
		return
	var expected := _get_expected_session_peer_ids()
	if expected.is_empty():
		return
	for peer_id: int in expected:
		if not _confirmed_peer_ids.get(peer_id, false):
			return
	_network_completion_started = true
	call_deferred("_finish_network_summary_after_flush")


func _finish_network_summary_after_flush() -> void:
	var tree := get_tree()
	if not tree:
		return
	# 让各 Client 先收到自己的确认行，再收到 Host 的最终完成决定。
	await tree.create_timer(0.08, true).timeout
	if not is_instance_valid(self) or _finishing:
		return
	for target_peer_id: int in _get_expected_session_peer_ids():
		if target_peer_id > 1:
			_network_summary_complete.rpc_id(target_peer_id)
	await tree.create_timer(0.08, true).timeout
	if is_instance_valid(self) and not _finishing:
		_finish_summary()


@rpc("authority", "call_remote", "reliable")
func _network_summary_complete() -> void:
	# Host 是唯一完成裁决者；避免 Client 依据场景本地 seat 顺序提前或永久无法结束。
	if _multiplayer_mode and not multiplayer.is_server():
		_finish_summary()


func _broadcast_remote_confirmation(confirmed_peer_id: int) -> void:
	# 显式逐 peer 发送，避免场景切换后最后一次准备广播漏到 Client。
	for target_peer_id: int in _get_expected_session_peer_ids():
		if target_peer_id > 1:
			_apply_remote_confirmation.rpc_id(target_peer_id, confirmed_peer_id)
	print("[ChapterSummary] CONFIRM_BROADCAST peer=%d targets=%s" % [confirmed_peer_id, str(_get_expected_session_peer_ids())])


@rpc("any_peer", "call_remote", "reliable")
func _server_confirm() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id <= 1:
		return
	var seat_index := _find_seat_owned_by_peer(sender_id)
	if seat_index < 0:
		# 可靠 RPC 可以在新场景 NetworkWorld 完成 PlayerState 绑定前抵达。
		# 按真正的网络 peer 暂存，而不是错误地采用客户端本地 seat 编号。
		_pending_peer_confirmations[sender_id] = Time.get_ticks_msec() + 2000
		print("[ChapterSummary] CONFIRM_DEFER peer=%d" % sender_id)
		return
	_server_confirm_local(seat_index)


func _process(_delta: float) -> void:
	if not visible or _finishing:
		return
	_sync_required_multiplayer_seats()
	var now := Time.get_ticks_msec()
	if multiplayer.is_server():
		for value: Variant in _pending_peer_confirmations.keys():
			var peer_id := int(value)
			var seat_index := _find_seat_owned_by_peer(peer_id)
			if seat_index >= 0:
				_pending_peer_confirmations.erase(peer_id)
				print("[ChapterSummary] CONFIRM_RESOLVED peer=%d seat=%d" % [peer_id, seat_index])
				_server_confirm_local(seat_index)
				continue
			if now >= int(_pending_peer_confirmations[peer_id]):
				_pending_peer_confirmations.erase(peer_id)
				push_warning("[ChapterSummary] CONFIRM_TIMEOUT peer=%d，等待玩家状态同步超时" % peer_id)
	else:
		for value: Variant in _pending_remote_confirmations.keys():
			var peer_id := int(value)
			var seat_index := _find_seat_owned_by_peer(peer_id)
			if seat_index >= 0:
				_pending_remote_confirmations.erase(peer_id)
				print("[ChapterSummary] REMOTE_CONFIRM_RESOLVED peer=%d seat=%d" % [peer_id, seat_index])
				confirm_seat(seat_index)
				continue
			if now >= int(_pending_remote_confirmations[peer_id]):
				_pending_remote_confirmations.erase(peer_id)
				push_warning("[ChapterSummary] REMOTE_CONFIRM_TIMEOUT peer=%d，等待玩家状态同步超时" % peer_id)


## 无头回归专用：验证 Client 的准备 RPC 在安全屋新场景 PlayerState 绑定后确实被 Host 接收，
## 并且 Host 的确认广播能回写到 Client。正式运行不会进入该分支。
func _is_auto_safe_door_test() -> bool:
	return "--net-test-safe-door" in OS.get_cmdline_user_args() and _multiplayer_mode


func _run_auto_safe_door_summary_test() -> void:
	var tree := get_tree()
	if not tree:
		return
	if multiplayer.is_server():
		# 留出 Client 先提交确认的窗口，专门覆盖此前“Client 无法准备”的失败时序。
		await tree.create_timer(1.20, true).timeout
		if visible and not _finishing:
			print("[ChapterSummary] AUTO_HOST_CONFIRM_REQUESTED peer=%d" % _get_local_peer_id())
			_submit_local_confirmation()
	else:
		await tree.create_timer(0.65, true).timeout
		if visible and not _finishing:
			print("[ChapterSummary] AUTO_CLIENT_CONFIRM_REQUESTED peer=%d" % _get_local_peer_id())
			_submit_local_confirmation()


func _get_local_peer_id() -> int:
	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("is_online_session") and bool(net.is_online_session()):
		return int(net.get("my_peer_id"))
	return 1


func _find_seat_owned_by_peer(peer_id: int) -> int:
	if peer_id <= 0:
		return -1
	for seat_index: int in range(Players.seat_count()):
		var state: PlayerState = Players.get_seat(seat_index)
		if state and state.owner_peer_id == peer_id:
			return seat_index
	return -1


@rpc("authority", "call_remote", "reliable")
func _apply_remote_confirmation(peer_id: int) -> void:
	print("[ChapterSummary] REMOTE_CONFIRM_RX peer=%d" % peer_id)
	var seat_index := _find_seat_owned_by_peer(peer_id)
	if seat_index >= 0:
		confirm_seat(seat_index)
		return
	# 可靠广播早于本机的新场景 PlayerState 绑定时，保留网络身份并在 _process 重试。
	_pending_remote_confirmations[peer_id] = Time.get_ticks_msec() + 2000
	print("[ChapterSummary] REMOTE_CONFIRM_DEFER peer=%d" % peer_id)


func _has_real_multiplayer_session() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.get_peers().size() > 0


func _collect_required_seats() -> Array[int]:
	var result: Array[int] = []
	if _multiplayer_mode:
		# 仅等待当前网络会话中的玩家；PlayerRegistry 的本地默认座位
		# （owner_peer_id == 0）不是联机参与者，绝不能阻塞章节总结。
		for seat_index: int in range(Players.seat_count()):
			if _is_required_network_seat(seat_index):
				result.append(seat_index)
	else:
		result.append(Players.active_seat_index)
	if result.is_empty() and not _multiplayer_mode:
		result.append(0)
	return result


func _sync_required_multiplayer_seats() -> void:
	if not _multiplayer_mode:
		return
	# 每帧从会话 peer 重建，不保留切图前遗留的默认/断线座位。
	var required: Array[int] = []
	for seat_index: int in range(Players.seat_count()):
		if _is_required_network_seat(seat_index):
			required.append(seat_index)
	required.sort()
	_required_seats = required


func _is_required_network_seat(seat_index: int) -> bool:
	var state: PlayerState = Players.get_seat(seat_index)
	return state != null and state.owner_peer_id in _get_expected_session_peer_ids()


func _get_expected_session_peer_ids() -> Array[int]:
	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("get_peer_ids"):
		return net.get_peer_ids()
	return []


func _all_players_confirmed() -> bool:
	_sync_required_multiplayer_seats()
	# 新安全屋 Summary 可能早于 NetworkWorld 完成 PlayerState/seat 重建。
	# 即便 Host 已确认，也必须等每个已握手的连接玩家都绑定到一个 seat，
	# 否则会在 Client 准备包抵达前错误地关闭界面。
	if _multiplayer_mode:
		for peer_id: int in _get_expected_session_peer_ids():
			if _find_seat_owned_by_peer(peer_id) < 0:
				return false
	for seat_index: int in _required_seats:
		if not _confirmed.get(seat_index, false):
			return false
	return true


func _finish_summary() -> void:
	if _finishing:
		return
	_finishing = true
	visible = false
	if _music_player:
		_music_player.stop()
	if pause_game:
		get_tree().paused = false
	summary_finished.emit()
	if _is_auto_safe_door_test():
		var role := "host" if multiplayer.is_server() else "client"
		print("[ChapterSummary] AUTO_SUMMARY_COMPLETE role=%s" % role)
		var tree := get_tree()
		if multiplayer.is_server():
			# Host 必须给可靠确认包足够的 flush 时间，随后才结束无头回归。
			tree.create_timer(1.0, true).timeout.connect(func():
				var net: Node = get_node_or_null("/root/Net")
				if net and net.has_method("leave"):
					net.leave()
				tree.quit()
			)
		else:
			# Client 在收到 Host 最后一份确认并关闭自身总结页后主动退出。
			tree.create_timer(0.12, true).timeout.connect(func():
				var net: Node = get_node_or_null("/root/Net")
				if net and net.has_method("leave"):
					net.leave()
				tree.quit()
			)
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

	var safe := _make_label("暂时安全了", 25, GOLD)
	content.add_child(safe)
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
	spacer.custom_minimum_size.y = 48
	content.add_child(spacer)
	var quote := _make_label(_get_active_character_safehouse_line(), 24, PALE)
	quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quote.custom_minimum_size = Vector2(980, 56)
	content.add_child(quote)
	_status_label = _make_label("", 25, PALE)
	content.add_child(_status_label)
	_prompt_label = _make_label("", 22, GOLD)
	content.add_child(_prompt_label)


func _rebuild_player_rows() -> void:
	if not _players_box:
		return
	for child: Node in _players_box.get_children():
		child.queue_free()
	if not _multiplayer_mode:
		_add_stats_row("全队合计", _get_total_stats(), "-", MUTED)
		return
	var count: int = maxi(Players.seat_count(), 1)
	for seat_index: int in range(count):
		var state: PlayerState = Players.get_seat(seat_index)
		var player_name: String = state.get_character_name() if state else "玩家 %d" % (seat_index + 1)
		var stats: Dictionary = _stats_for_seat(seat_index)
		var ready: bool = _confirmed.get(seat_index, false)
		var status_text: String = "已准备" if ready else ("等待" if _multiplayer_mode else "-")
		var status_color: Color = GREEN if ready else MUTED
		_add_stats_row(player_name, stats, status_text, status_color)


func _add_stats_row(player_name: String, stats: Dictionary, status_text: String, status_color: Color) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 48
	row.add_theme_constant_override("separation", 8)
	_players_box.add_child(row)
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


func _get_total_stats() -> Dictionary:
	var stats_node: Node = get_node_or_null("/root/ChapterStats")
	if stats_node and stats_node.has_method("get_totals"):
		return stats_node.get_totals()
	return {}


func _get_active_character_safehouse_line() -> String:
	var state: PlayerState = Players.get_active_state()
	if state and state.character and not state.character.safehouse_lines.is_empty():
		return "「%s」" % state.character.safehouse_lines.pick_random()
	return "「……」"


func _play_summary_music() -> void:
	if not summary_music:
		return
	if not _music_player:
		_music_player = AudioStreamPlayer.new()
		_music_player.name = "SummaryMusic"
		_music_player.bus = &"Music"
		add_child(_music_player)
	_music_player.stop()
	_music_player.stream = summary_music
	_music_player.volume_db = summary_music_volume_db
	_music_player.play()


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
