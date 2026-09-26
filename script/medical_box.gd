@tool
extends Node2D

## ── 架构定位 ──
## 系统：医疗箱 ｜ 层：玩法（Node2D，一次性互动物）
## 联机：**Host 权威**（2026-09-26 重做）。Client 按键 → 请求 Host → Host 结算并广播已用名单。
## 职责：
##   · 单机：按 D 治疗**全体座位**（含 HP=0 的死亡队员=复活），用完直接清除（保持原设计）。
##   · 联机：**每个玩家各能用一次**，且**只治疗使用者自己**；用过的玩家看到箱子变暗、
##           不能再按；**当前所有在线玩家都用过**之后，箱子在所有端清除。
## 依赖：Players（本地实体/座位）、Net（peer 名单 / my_peer_id / is_host）
## 素材：art/Characters/[2K-VX]-救急箱.png（标准 576×512 四角色表，寻址同 weapon_pickup）
##
## 【为什么重做（2026-09-26 用户实测）】旧实现**完全没有联机接线**，是每端各跑一份纯本地副本：
##   ① 每个客户端都能各自触发（提示里那句「需主机操作」只是文案，代码里没有任何主机校验）；
##   ② `_use()` 只改**本地** PlayerState 并本地 `queue_free()`、不广播 →
##      主机用完箱子后，其他玩家画面里箱子还在、甚至还能继续用；
##   ③ 旧语义是「治疗全体角色」（单机控多角色时的合理设计）——多人下退化成"一人用、全队受益"。
## 现在：每人一次 / 只治自己 / 用过变暗 / 全员用完才消失。

# ═══════════════════════════════════════
# 精灵帧常量（VX 行走图寻址，与 weapon_pickup 一致）
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

const COLLISION_NODE: String = "Collision"
const COLLISION_SHAPE_NODE: String = "Shape"
const COLLISION_SIZE: int = 32
## 已用玩家的箱子不透明度（"你已用过"的视觉提示）。
const USED_ALPHA: float = 0.45
## 治疗绿闪颜色（沿用旧实现的过曝绿）。
const HEAL_FLASH_COLOR: Color = Color(1.6, 2.0, 1.6, 1.0)

@export_group("外观")
@export var box_texture: Texture2D = preload("res://art/Characters/[2K-VX]-救急箱.png")
@export var box_char_idx: int = 0           ## 精灵表中的角色索引
@export var box_direction: int = 0          ## 朝向（0=下）
@export var sprite_offset: Vector2 = Vector2(0, -20)

@export_group("交互")
@export var interact_label: String = ""     ## 留空按模式自动取（单机=治疗全体角色 / 联机=治疗自己）
@export_range(24.0, 200.0, 4.0) var interact_range: float = 56.0

@export_group("音效")
@export var heal_sound: AudioStream = preload("res://sound/回復1.ogg")  ## 治疗音效（留空=不播）

var _can_interact: bool = false
var _used: bool = false                       ## 单机：一次性
var _used_peers: Dictionary = {}              ## 联机：peer_id → true（Host 权威，Client 由广播覆盖）
## 本场景是否是联机会话（_ready 时取一次）。场景加载后会话类型不会再变，
## 缓存一份省掉每帧多次 autoload 查询；同时给 harness 一个**可在无网络环境覆盖**的缝
## （`is_online_session()` 需要真实 multiplayer peer，测试里造不出来）。
var multiplayer_mode: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		_refresh_sprite()
		return
	multiplayer_mode = _is_online_session()
	_ensure_collision()
	_ensure_label()
	_refresh_sprite()
	_refresh_used_visual()


func _ensure_collision() -> void:
	var body: StaticBody2D = get_node_or_null(COLLISION_NODE) as StaticBody2D
	if not body:
		body = StaticBody2D.new()
		body.name = COLLISION_NODE
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)
	var shape_node: CollisionShape2D = body.get_node_or_null(COLLISION_SHAPE_NODE) as CollisionShape2D
	if not shape_node:
		shape_node = CollisionShape2D.new()
		shape_node.name = COLLISION_SHAPE_NODE
		body.add_child(shape_node)
	if not shape_node.shape:
		var rect := RectangleShape2D.new()
		rect.size = Vector2(COLLISION_SIZE, COLLISION_SIZE)
		shape_node.shape = rect


func _ensure_label() -> void:
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		label = Label.new()
		label.name = "HintLabel"
		label.position = Vector2(-90, -70)
		label.size = Vector2(180, 28)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		var g: Node = get_node_or_null("/root/Global")
		if g:
			g.apply_hint_font(label, 12)  ## 字体统一（2026-09-17）
			g.apply_text_shadow(label)
		label.hide()
		add_child(label)


func _refresh_sprite() -> void:
	var sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not sprite or not box_texture:
		return
	sprite.texture = box_texture
	sprite.position = sprite_offset
	sprite.region_enabled = true
	var frame: int = 1  # 站立帧
	var char_col: int = box_char_idx % CHARS_PER_ROW
	var char_row: int = box_char_idx / CHARS_PER_ROW
	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + box_direction * FRAME_H
	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_check_player_proximity()
	if _can_interact and Input.is_action_just_pressed("功能键"):
		get_viewport().set_input_as_handled()
		_request_use()


# ═══════════════════════════════════════
# 交互判定
# ═══════════════════════════════════════

func _check_player_proximity() -> void:
	var candidate: Node2D = null
	if multiplayer_mode:
		## 联机：只看自己操控的那个实体（每端各判各的，互不影响）。
		candidate = Players.get_local_entity()
	else:
		candidate = Players.nearest_entity_to(global_position)
	_can_interact = (
		not _used_by_me()
		and candidate != null
		and is_instance_valid(candidate)
		and candidate.global_position.distance_to(global_position) <= interact_range
	)
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		return
	## 联机也走同一条提示 —— 旧版写「（需主机操作）」是错的（每人各自可用）。
	label.text = "%s  [功能键]" % _label_text()
	label.visible = _can_interact


func _label_text() -> String:
	if not interact_label.is_empty():
		return interact_label
	return "治疗自己" if multiplayer_mode else "治疗全体角色"


## 本人是否已用过这只箱子。
func _used_by_me() -> bool:
	if not multiplayer_mode:
		return _used
	return _used_peers.has(_local_peer_id())


func _is_online_session() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and bool(net.is_online_session())


func _local_peer_id() -> int:
	var net: Node = get_node_or_null("/root/Net")
	if net == null:
		return 0
	return int(net.get("my_peer_id"))


func _is_host() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and bool(net.get("is_host"))


# ═══════════════════════════════════════
# 使用：单机本地 / 联机走 Host 权威
# ═══════════════════════════════════════

func _request_use() -> void:
	if not multiplayer_mode:
		_use_solo()
		return
	if _is_host():
		_host_use(_local_peer_id())
		return
	## Client：交给 Host 复核（距离 / 是否已用过）后结算。
	_server_use.rpc_id(1)


## Client → Host：申请使用本箱。Host 是唯一裁决者。
@rpc("any_peer", "call_remote", "reliable")
func _server_use() -> void:
	if not _is_host():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender <= 0:
		return
	_host_use(sender)


## Host 权威结算：校验 → 记账 → 只治使用者 → 广播已用名单。
func _host_use(peer_id: int) -> void:
	if peer_id <= 0 or _used_peers.has(peer_id):
		return
	var entity: Node2D = _entity_for_peer(peer_id)
	if entity == null or not is_instance_valid(entity) \
			or entity.global_position.distance_to(global_position) > interact_range + 8.0:
		print("[医疗箱] HOST_USE_REJECT peer=%d（超出交互范围或无实体）" % peer_id)
		return
	_used_peers[peer_id] = true
	_heal_entity(entity)
	_broadcast_used()
	print("[医疗箱] HOST_USE peer=%d（只治疗其本人）已用名单=%s" % [peer_id, str(_used_peers.keys())])


## Host → 各 Client：同步已用名单（Client 据此变暗 / 判定消失）。
func _broadcast_used() -> void:
	_apply_used(_used_peers.keys())
	if not multiplayer.has_multiplayer_peer():
		## 单机 / 无网络（含自动化用例）：没有可广播的对象，本地记账即可。
		return
	for target: int in _expected_peer_ids():
		if target <= 1 or target == _local_peer_id():
			continue
		_apply_used_sync.rpc_id(target, _used_peers.keys())


@rpc("authority", "call_remote", "reliable")
func _apply_used_sync(used_peers: Array) -> void:
	_apply_used(used_peers)


func _apply_used(used_peers: Array) -> void:
	_used_peers.clear()
	for value: Variant in used_peers:
		_used_peers[int(value)] = true
	_refresh_used_visual()
	if _all_players_used():
		print("[医疗箱] 全体玩家均已使用 → 本箱在所有端清除")
		queue_free()


## 本人已用过 → 箱子变暗半透明（明确「你已用过」，但它还在，因为队友可能没用完）。
func _refresh_used_visual() -> void:
	var sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not sprite:
		return
	var used: bool = _used_by_me()
	sprite.modulate = Color(1.0, 1.0, 1.0, USED_ALPHA) if used else Color.WHITE
	## 变暗后连提示都不该再出现（提示由 _check_player_proximity 每帧重算，这里只兜底一帧）。
	if used:
		var label: Label = get_node_or_null("HintLabel") as Label
		if label:
			label.visible = false
	queue_redraw()


## 当前在线的真人玩家（含 Host）。名单为空（非联机会话）时视为"不判定消失"。
func _expected_peer_ids() -> Array[int]:
	var net: Node = get_node_or_null("/root/Net")
	var empty: Array[int] = []
	if net == null or not net.has_method("get_peer_ids"):
		return empty
	var out: Array[int] = []
	for value: Variant in net.call("get_peer_ids"):
		var id: int = int(value)
		if id > 0:
			out.append(id)
	return out


func _all_players_used() -> bool:
	var ids: Array[int] = _expected_peer_ids()
	if ids.is_empty():
		return false
	for id: int in ids:
		if not _used_peers.has(id):
			return false
	return true


func _entity_for_peer(peer_id: int) -> Node2D:
	## Host 侧：peer → 座位 → 实体（座位表在联机下按 peer 重建，owner_peer_id 是唯一依据）。
	var seat_index: int = Players.find_seat_by_owner_peer_id(peer_id)
	if seat_index >= 0:
		var by_seat: Node2D = Players.get_entity_for_seat(seat_index)
		if by_seat != null and is_instance_valid(by_seat):
			return by_seat
	if peer_id == _local_peer_id():
		return Players.get_local_entity()
	return null


func _heal_entity(entity: Node2D) -> void:
	## 只治使用者自己：写权威 PlayerState（Host 的座位状态就是快照源，会回灌所有端）+ 本地满血表现。
	var state: PlayerState = Players.get_state_for_entity(entity)
	if state == null:
		return
	var hp: float = state.get_max_hp()
	state.current_hp = hp
	if entity.get("_is_dying") == true:
		return
	if entity.get("network_controlled") == true and entity.has_method("apply_network_health_state"):
		## 权威路径：同时写座位状态与节点表现（reliable/不可靠快照都会带上这个 hp）。
		entity.apply_network_health_state(hp, false, false)
	else:
		entity.set("current_hp", hp)
	if entity.has_method("_play_hit_feedback"):
		entity._play_hit_feedback(HEAL_FLASH_COLOR, 0.4)
	if heal_sound:
		Global.play_sfx_managed(heal_sound, get_tree().current_scene)


# ═══════════════════════════════════════
# 单机：保持原设计（全体回满 + 死亡队员复活 + 用完清除）
# ═══════════════════════════════════════

func _use_solo() -> void:
	if _used:
		return
	_used = true
	for s: PlayerState in Players.seats:
		if s:
			s.current_hp = s.get_max_hp()
	for entity: Node2D in Players.all_entities(false):
		if not is_instance_valid(entity):
			continue
		var state: PlayerState = Players.get_state_for_entity(entity)
		if state and entity.get("_is_dying") != true:
			entity.set("current_hp", state.current_hp)
			if entity.has_method("_play_hit_feedback"):
				entity._play_hit_feedback(HEAL_FLASH_COLOR, 0.4)
	if heal_sound:
		Global.play_sfx_managed(heal_sound, get_tree().current_scene)
	print("[医疗箱] 单机：全体角色治疗完毕（含死亡队员复活），医疗箱清除")
	queue_free()


func _draw() -> void:
	if Engine.is_editor_hint():
		return
	if not Global.debug_visuals:
		return
	var color: Color = Color(0.2, 1.0, 0.4, 0.75) if _can_interact else Color(1.0, 0.7, 0.2, 0.5)
	draw_arc(Vector2.ZERO, interact_range, 0.0, TAU, 48, color, 1.5)
