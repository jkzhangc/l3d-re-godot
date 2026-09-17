@tool
extends Node2D

## ── 架构定位 ──
## 系统：补给掉落物 ｜ 层：玩法（Node2D）
## 联机：Client 请求 / Host 校验提交
## 职责：治疗品/辅助品/投掷物掉落物：共用一个交互壳，但写入 PlayerState 的字段各不相同。
## 依赖：ItemData/ThrowableData、PlayerState、NetworkWorld

## 治疗品 / 投掷物掉落物。
## healing_item 与 throwable 共用交互壳，但写入 PlayerState 的库存字段不同。
## Client 必须走 _request_network_pickup()；只有 Host 明确标记的 presentation-only 镜像
## 才屏蔽请求，这一点对客户端拾取投掷物尤其重要。
## 治疗品/投掷物拾取物 — 放在地图上供玩家拾取
##
## 治疗品/辅助品：触碰自动拾取。
## 投掷物：空槽自动拾取；已持有则按住「确定键」替换（旧投掷物掉落回地面）。
##
## 支持 VX Ace 行走图渲染（与武器拾取物相同）：当 ItemData.pickup_texture 已配置时，
## 用 region 帧渲染 + 原地踏步动画；未配置则回退到 ItemData.icon 整图显示。

# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

## 拾取物模板场景（投掷物替换时掉落旧投掷物用）
const PICKUP_SCENE := preload("res://object/healing_pickup.tscn")
## 掉落物短时间不可拾取，防止替换后立即重新拾取造成循环
const PICKUP_DELAY_MSEC: int = 600

const INDICATOR_SCRIPT := preload("res://script/hold_indicator.gd")

@export var item: ItemData:
	set(v):
		item = v
		## Inspector 里换物品即时刷编辑器预览（预览走 item.pickup_texture/icon）
		_refresh_sprite()  ## 要给予的物品（治疗品/投掷物）

## 2026-09-13 用户需求：开启后治疗品/辅助品不再触碰自动拾取，
## 改为靠近按住功能键(D)拾取（进度环提示）。投掷物替换仍按住确定键（旧机制）。
@export var require_function_key: bool = false

@export_group("Hold Settings")
## 按住替换所需时长（秒）
@export var hold_time: float = 1.2

@export_group("Hold Indicator")
## 是否启用按住进度指示器（圆环填充动画）
@export var hold_indicator_enabled: bool = true
## 指示器圆环半径（像素）
@export var hold_indicator_radius: float = 18.0
## 圆环线宽（像素）
@export var hold_indicator_thickness: float = 3.0
## 指示器位置偏移（相对拾取物原点，Y轴向上为负）
@export var hold_indicator_offset: Vector2 = Vector2(0, -48)
## 进度填充颜色
@export var hold_indicator_color: Color = Color(1.0, 0.9, 0.2, 1.0)
## 背景圆环颜色
@export var hold_indicator_bg_color: Color = Color(0.0, 0.0, 0.0, 0.55)
## 淡入淡出速度（alpha/秒，值越大过渡越快）
@export var hold_indicator_fade_speed: float = 5.0

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D

var _step_idx: int = 0           ## 当前踏步帧在序列中的索引
var _step_timer: float = 0.0     ## 踏步帧计时器
var _spawn_msec: int = 0         ## 生成时刻（掉落物拾取冷却用）
## 地面放置物上限豁免：地图预摆的拾取物（含 random_pickup 预摆实例刷出的）不参与
## GroundItemCap(8) 计数与淘汰 —— 它们是关卡设计的一部分，不是掉落杂物。
var cap_exempt: bool = false
var _player_in_range: bool = false
var _player_ref: CharacterBody2D = null
var _hold_timer: float = 0.0
var _indicator_alpha: float = 0.0
var _indicator_node: Node2D = null

## 在线联机中由 NetworkWorld 分配；0 表示尚未收到 Host 的权威快照。
var network_pickup_id: int = 0
var network_presentation_only: bool = false
var _network_pickup_request_pending: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		# 编辑器预览（@tool）：按 item.pickup_texture/icon 刷出显示，让摆点时能看见长相。
		# 不注册掉落上限、不连 Area2D、不建按住指示器。
		_refresh_sprite()
		return
	_spawn_msec = Time.get_ticks_msec()
	## 自动判定：编辑器摆进场景的实例 owner 非空 → 豁免（运行时刷出 owner 为空）。
	## 用 or 是为了不覆盖 random_pickup 对预摆实例刷出物的预设豁免。
	cap_exempt = cap_exempt or owner != null
	if not cap_exempt:
		GroundItemCap.register(self)
	if _area:
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)
	_refresh_sprite()

	# 创建按住进度指示器子节点（z_index 高于精灵，确保圆环绘制在精灵上方）
	if hold_indicator_enabled:
		_indicator_node = Node2D.new()
		_indicator_node.name = "HoldIndicator"
		_indicator_node.z_index = 10
		_indicator_node.set_script(INDICATOR_SCRIPT)
		_indicator_node._pickup = self
		add_child(_indicator_node)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# 踏步动画（仅行走图模式下生效）
	if item and item.pickup_texture and item.pickup_animated:
		var frames: Array[int] = item.pickup_step_frames
		if frames.is_empty():
			frames = [1, 0, 1, 2]
		var dur: float = item.pickup_step_duration if item.pickup_step_duration > 0.0 else 0.25
		_step_timer += delta
		if _step_timer >= dur:
			_step_timer -= dur
			_step_idx = (_step_idx + 1) % frames.size()
			_refresh_sprite()

	# 指示器每帧无条件刷新（2026-09-13 残留修复，同 weapon_pickup）
	var holding: bool = false
	if _is_online_network_pickup() and item and item.item_type == ItemData.ItemType.THROWABLE:
		holding = _process_network_pickup(delta)
	else:
		holding = _process_pickup(delta)
	_update_hold_indicator(delta, holding)


func _is_online_network_pickup() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net and net.has_method("is_online_session") and bool(net.is_online_session())


func _process_network_pickup(delta: float) -> bool:
## 联机客户端只检测交互、显示长按提示并提交请求；Host 回包后才视为成功。
	if network_pickup_id <= 0 or network_presentation_only:
		_hold_timer = 0.0
		return false
	var local_player := Players.get_local_entity() as CharacterBody2D
	var in_range := is_instance_valid(local_player) and local_player.global_position.distance_to(global_position) <= 28.0
	_player_ref = local_player if in_range else null
	_player_in_range = in_range
	if not in_range or not item:
		_hold_timer = 0.0
		return false
	var state: PlayerState = Players.get_state_for_entity(local_player)
	if not state:
		return false
	var throwable_replacement: bool = item.item_type == ItemData.ItemType.THROWABLE and state.throwable != null
	if not throwable_replacement and not require_function_key:
		_request_network_pickup()
		return false
	return _process_hold(delta, throwable_replacement)


func _request_network_pickup() -> void:
	if _network_pickup_request_pending:
		return
	_network_pickup_request_pending = true
	_hold_timer = 0.0
	var scene := get_tree().current_scene
	var world := scene.find_child("NetworkWorld", true, false) if scene else null
	if world and world.has_method("request_pickup"):
		world.request_pickup(network_pickup_id)
	else:
		_network_pickup_request_pending = false


func configure_network_pickup(pickup_id: int, presentation_only: bool = false) -> void:
	network_pickup_id = pickup_id
	network_presentation_only = presentation_only
	_network_pickup_request_pending = false


func reset_network_pickup_request() -> void:
	_network_pickup_request_pending = false


func disable_network_pickup() -> void:
	visible = false
	_player_in_range = false
	_player_ref = null
	_hold_timer = 0.0
	if _area:
		_area.set_deferred("monitoring", false)
		_area.set_deferred("monitorable", false)


func _process_pickup(delta: float) -> bool:
## 单机/Host 拾取逻辑。返回本帧是否处于按住状态（供进度环刷新）。
	if not _player_in_range or not _player_ref:
		_hold_timer = 0.0
		return false
	if not item:
		return false
	# 掉落物短时间不可拾取，防止替换后立即重新拾取循环
	if Time.get_ticks_msec() - _spawn_msec < PICKUP_DELAY_MSEC:
		return false

	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return false

	# 投掷物且已持有 → 按住确定键替换；其余默认自动拾取，
	# require_function_key 时改按住功能键(D)（进度环提示，避免路过误拾）
	var throwable_replacement: bool = item.item_type == ItemData.ItemType.THROWABLE and state.throwable != null
	if not throwable_replacement:
		if not require_function_key:
			_do_pickup()
			return false
		return _process_hold(delta, false)

	# 玩家正在武器/投掷物举起/瞄准状态，不触发替换（避免与确定键瞄准冲突）
	if _player_ref.get("player_in_weapon_state"):
		_hold_timer = 0.0
		return false
	return _process_hold(delta, true)


func _process_hold(delta: float, throwable_replacement: bool) -> bool:
	## 按住进度：投掷物替换用确定键（旧行为），功能键获取用功能键(D)。
	var action: String = "确定键" if throwable_replacement else "功能键"
	if Input.is_action_pressed(action):
		_hold_timer += delta
		if _hold_timer >= hold_time:
			_do_pickup()
			return false
		return true
	_hold_timer = 0.0
	return false


func _do_pickup() -> void:
## 单机/授权后的库存写入：按类型增加治疗品或投掷物，并按规则处理已有投掷物。
	if not item:
		return
	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return

	# 投掷物单槽位：已持有则先掉落旧的（同副武器替换逻辑）
	if item.item_type == ItemData.ItemType.THROWABLE and state.throwable:
		_drop_old_throwable(_player_ref, state)
	# 治疗品（急救喷雾）：
	#   单机 → 队伍共用池（上限 10，2026-09-13 用户定稿），满了留在地上；
	#   联机 → 各自持有（每人上限 3），自己满转投其他座位；全满 = 留在地上。
	if item.item_type == ItemData.ItemType.HEALING:
		var placed: bool = false
		if Players.using_shared_spray_pool():
			placed = Players.try_add_team_spray(item)
			if not placed:
				print("[拾取] 喷雾共用池已满（10），留在地上")
				return
		else:
			var cap: int = Players.spray_per_seat_cap()
			placed = state.pickup_consumable(item, cap)
			if not placed:
				for s: PlayerState in Players.seats:
					if s and s != state and s.pickup_consumable(item, cap):
						placed = true
						break
			if not placed:
				print("[拾取] 急救喷雾已达全队所持上限，留在地上")
				return
	else:
		state.pickup_consumable(item)
	## 拾取音效：物品数据（ItemData.pickup_sound）可配，留空用全局默认（2026-09-15）。
	## 放满留在地上的分支在上面已 return，不会响。
	Global.play_pickup_sfx(item.pickup_sound, item.pickup_sound_pitch)
	queue_free()


func _drop_old_throwable(body: Node2D, state: PlayerState) -> void:
	## 将旧的投掷物生成为地面拾取物，掉落在玩家脚下。
	var old: ThrowableData = state.throwable
	if not old:
		return
	var drop: Node2D = PICKUP_SCENE.instantiate()
	drop.item = old
	drop.position = body.global_position
	var parent: Node = get_parent()
	if not parent:
		parent = get_tree().current_scene
	parent.add_child(drop)
	print("[拾取] 投掷物替换: %s → %s" % [old.item_name, item.item_name])


func _refresh_sprite() -> void:
	# @onready 在编辑器预览路径可能未赋值（如手动触发），兜底按节点名取
	var sprite: Sprite2D = _sprite if _sprite else get_node_or_null("Sprite2D") as Sprite2D
	if not sprite or not item:
		return

	# 行走图模式：ItemData 配置了地面精灵表
	if item.pickup_texture:
		var frames: Array[int] = item.pickup_step_frames
		if frames.is_empty():
			frames = [1, 0, 1, 2]
		var frame: int
		if item.pickup_animated and frames.size() > 0:
			frame = frames[_step_idx]
		else:
			frame = frames[0] if frames.size() > 0 else 1

		var char_col: int = item.pickup_char_idx % CHARS_PER_ROW
		var char_row: int = item.pickup_char_idx / CHARS_PER_ROW
		var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + item.pickup_direction * FRAME_H

		sprite.texture = item.pickup_texture
		sprite.region_enabled = true
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
		return

	# 回退：整图显示 icon
	if item.icon:
		sprite.texture = item.icon
		sprite.region_enabled = false


func _on_body_entered(body: Node2D) -> void:
	var player: CharacterBody2D = body as CharacterBody2D
	if player:
		_player_in_range = true
		_player_ref = player
		_hold_timer = 0.0


func _on_body_exited(body: Node2D) -> void:
	var player: CharacterBody2D = body as CharacterBody2D
	if player and player == _player_ref:
		_player_in_range = false
		_player_ref = null
		_hold_timer = 0.0


func _update_hold_indicator(delta: float, is_holding: bool) -> void:
	## 更新按住进度指示器的淡入/淡出透明度，并触发重绘。
	## 2026-09-13 残留修复：同 weapon_pickup —— 每帧无条件调用 + alpha 归零补清屏。
	if not hold_indicator_enabled or not _indicator_node:
		return
	var target: float = 1.0 if is_holding else 0.0
	var prev: float = _indicator_alpha
	_indicator_alpha = move_toward(_indicator_alpha, target, hold_indicator_fade_speed * delta)
	if prev != _indicator_alpha or _indicator_alpha > 0.0 or _hold_timer > 0.0:
		_indicator_node.queue_redraw()


func _indicator_draw(node: Node2D) -> void:
	## 由 hold_indicator.gd 子节点的 _draw() 回调
	## 绘制背景圆环 + 进度填充弧线
	if _indicator_alpha <= 0.001:
		return

	var progress: float = clampf(_hold_timer / hold_time, 0.0, 1.0)
	var center: Vector2 = hold_indicator_offset
	var radius: float = hold_indicator_radius
	var thickness: float = hold_indicator_thickness
	var pts: int = 64

	var bg: Color = hold_indicator_bg_color
	bg.a *= _indicator_alpha
	node.draw_arc(center, radius, 0, TAU, pts, bg, thickness, true)

	if progress > 0.0:
		var fg: Color = hold_indicator_color
		fg.a *= _indicator_alpha
		var start_angle: float = -PI / 2.0
		var end_angle: float = start_angle + progress * TAU
		node.draw_arc(center, radius, start_angle, end_angle, pts, fg, thickness, true)
