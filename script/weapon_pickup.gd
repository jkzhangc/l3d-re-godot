extends Node2D
## 地面武器掉落物。
##
## 单机：本地节点完成拾取/替换并生成旧武器掉落；联机：Client 只提交请求，Host
## 验证距离、槽位和物品 ID 后修改权威 PlayerState，再广播结果。
## network_presentation_only=true 只表示该镜像不能发起拾取请求，不能误用于仍需交互的掉落物。
## 武器拾取物 — 放在地图上供玩家拾取
##
## VX Ace 精灵渲染（与玩家/子弹相同）：通过 char_idx 选择角色，
## 通过踏步帧序列实现原地踏步动画。


# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
enum FaceDir { DOWN = 0, LEFT = 1, RIGHT = 2, UP = 3 }

## 武器拾取物模板场景（用于掉落生成）
const PICKUP_SCENE := preload("res://object/weapon_pickup.tscn")


# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
@export var weapon_data: WeaponData           ## 要给予的武器资源
@export var pickup_texture: Texture2D         ## 地上显示的精灵表
@export var pickup_char_idx: int = 0          ## 精灵表中的角色索引
@export var pickup_direction: int = 0         ## 朝向（0=下, 1=左, 2=右, 3=上）

@export_group("拾取弹药")
## 拾取时给予的备弹数量（对应 weapon_data.ammo_item_id 的弹药物品）
@export var pickup_reserve_ammo: int = 0
## 拾取时弹夹内的子弹数（-1=自动填满弹夹容量，0=空弹夹）
@export var pickup_magazine_ammo: int = -1

## 在线联机中由 NetworkWorld 分配；0 表示离线旧逻辑。
var network_pickup_id: int = 0
var network_presentation_only: bool = false
var _network_pickup_request_pending: bool = false


# ═══════════════════════════════════════
# 踏步动画
# ═══════════════════════════════════════
@export_group("Step Animation")
## 踏步帧序列（与玩家行走帧序列一致：frame1 → frame0 → frame1 → frame2）
@export var pickup_step_frames: Array[int] = [1, 0, 1, 2]
## 每帧持续时间（秒）
@export var pickup_step_duration: float = 0.25
## 是否启用踏步动画（关闭则始终显示序列第一帧）
@export var pickup_animated: bool = true


# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════
@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D


# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var _player_in_range: bool = false
var _player_ref: CharacterBody2D = null
var _hold_timer: float = 0.0
var _step_idx: int = 0           ## 当前踏步帧在 pickup_step_frames 中的索引
var _step_timer: float = 0.0     ## 踏步帧计时器
var _indicator_alpha: float = 0.0       ## 指示器当前透明度（用于淡入淡出）
var _indicator_node: Node2D = null      ## 指示器绘制子节点

const INDICATOR_SCRIPT := preload("res://script/hold_indicator.gd")
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


func _ready() -> void:
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
	if _is_online_network_pickup():
		_process_network_pickup(delta)
		_process_step_animation(delta)
		return
	_process_step_animation(delta)

	# 拾取逻辑
	if not _player_in_range or not _player_ref:
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)
		return
	if not weapon_data:
		return

	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return
	var slot: String = weapon_data.get_slot_key()
	var current: WeaponData = state.get_equipped_weapon(slot)

	# 该槽位为空 → 自动拾取装备
	if current == null:
		_do_pickup()
		return

	# 槽位已有武器 → 需按住确定键替换
	if not _can_hold_pickup():
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)
		return

	if Input.is_action_pressed("确定键"):
		_hold_timer += delta
		_update_hold_indicator(delta, true)
		if _hold_timer >= hold_time:
			_do_pickup()
	else:
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)



func _process_step_animation(delta: float) -> void:
	if pickup_animated and pickup_step_frames.size() > 0:
		_step_timer += delta
		if _step_timer >= pickup_step_duration:
			_step_timer -= pickup_step_duration
			_step_idx = (_step_idx + 1) % pickup_step_frames.size()
			_refresh_sprite()


func _is_online_network_pickup() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net and net.has_method("is_online_session") and bool(net.is_online_session())


func _process_network_pickup(delta: float) -> void:
## 联机交互入口：本地只显示提示和发送意图，成功与否由 Host 的拾取事务决定。
	# 尚未收到 Host 的可靠 pickup_snapshot 前只能展示，不能执行本地拾取。
	if network_pickup_id <= 0:
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)
		return
	var local_player := Players.get_local_entity() as CharacterBody2D
	var in_range := is_instance_valid(local_player) and local_player.global_position.distance_to(global_position) <= 28.0
	_player_ref = local_player if in_range else null
	_player_in_range = in_range
	if not in_range or not weapon_data:
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)
		return
	var state: PlayerState = Players.get_state_for_entity(local_player)
	var current: WeaponData = state.get_equipped_weapon(weapon_data.get_slot_key()) if state else null
	if current == null:
		_request_network_pickup()
		return
	if Input.is_action_pressed("确定键"):
		_hold_timer += delta
		_update_hold_indicator(delta, true)
		if _hold_timer >= hold_time:
			_request_network_pickup()
	else:
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)


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

func _can_hold_pickup() -> bool:
	## 玩家在范围内即可拾取（不再限制武器举起/攻击状态）
	return _player_ref != null


func _update_hold_indicator(delta: float, is_holding: bool) -> void:
	## 更新按住进度指示器的淡入/淡出透明度，并触发重绘
	if not hold_indicator_enabled or not _indicator_node:
		return
	var target: float = 1.0 if is_holding else 0.0
	_indicator_alpha = move_toward(_indicator_alpha, target, hold_indicator_fade_speed * delta)
	if _indicator_alpha > 0.001 or _hold_timer > 0.0:
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

	# 背景圆环（完整一圈）
	var bg: Color = hold_indicator_bg_color
	bg.a *= _indicator_alpha
	node.draw_arc(center, radius, 0, TAU, pts, bg, thickness, true)

	# 进度弧线（顺时针从顶部 12 点钟方向开始填充）
	if progress > 0.0:
		var fg: Color = hold_indicator_color
		fg.a *= _indicator_alpha
		var start_angle: float = -PI / 2.0
		var end_angle: float = start_angle + progress * TAU
		node.draw_arc(center, radius, start_angle, end_angle, pts, fg, thickness, true)


func _do_pickup() -> void:
## 单机或 Host 已授权后的实际换装事务：处理空槽/替换、弹药补充和旧物掉落。
	if not weapon_data:
		return

	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return

	# 检查当前角色是否可以使用此武器
	var player_character: CharacterData = state.character
	if player_character and not player_character.can_use_weapon(weapon_data):
		print("[拾取] 角色 %s 无法使用 %s，拾取拒绝" % [player_character.character_name, weapon_data.item_name])
		_hold_timer = 0.0
		return

	var slot: String = weapon_data.get_slot_key()
	var old: WeaponData = state.get_equipped_weapon(slot)

	if old:
		_drop_weapon(old, slot)
		print("[拾取] 替换 %s 槽: %s → %s" % [slot, old.item_name, weapon_data.item_name])
	else:
		print("[拾取] 装备到 %s 槽: %s" % [slot, weapon_data.item_name])

	state.equip_weapon_in_slot(weapon_data, slot)

	# —— 弹药处理 ——
	# 弹夹子弹
	if weapon_data.is_ranged and weapon_data.magazine_capacity > 0:
		if pickup_magazine_ammo >= 0:
			# 使用指定的弹夹子弹数
			state.set_magazine_ammo(weapon_data.item_id, clampi(pickup_magazine_ammo, 0, weapon_data.magazine_capacity))
		else:
			# -1 = 自动填满弹夹
			state.set_magazine_ammo(weapon_data.item_id, weapon_data.magazine_capacity)

	# 备弹（库存弹药物品）
	if pickup_reserve_ammo > 0 and not weapon_data.ammo_item_id.is_empty():
		var ammo_res: ItemData = _find_ammo_resource(state, weapon_data.ammo_item_id)
		if ammo_res:
			for _i: int in range(pickup_reserve_ammo):
				state.add_item(ammo_res.duplicate())
			print("[拾取] 给予备弹: %s ×%d" % [weapon_data.ammo_item_id, pickup_reserve_ammo])
		else:
			push_warning("[拾取] 找不到弹药资源: %s" % weapon_data.ammo_item_id)

	# 不自动进入武器举起状态，玩家按 Shift 自行举起
	queue_free()


func _drop_weapon(wd: WeaponData, slot: String) -> void:
	## 将旧武器生成为地面拾取物，掉落在玩家脚下。
	## 远程武器的弹夹子弹和备弹一并转移到拾取物上。
	if not _player_ref:
		return
	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return

	var pickup: Node2D = PICKUP_SCENE.instantiate()
	pickup.weapon_data = wd

	# 从 WeaponData 读取地面显示参数；未配置则回退到武器行走图
	if wd.pickup_texture:
		pickup.pickup_texture = wd.pickup_texture
		pickup.pickup_char_idx = wd.pickup_char_idx
		pickup.pickup_direction = wd.pickup_direction
	else:
		pickup.pickup_texture = wd.weapon_walk_texture
		var seq: Array[int] = wd.get_raise_char_sequence()
		pickup.pickup_char_idx = seq[0] if seq.size() > 0 else 0
		pickup.pickup_direction = 0  # 面朝下

	# 踏步动画设置（从 WeaponData 读取）
	pickup.pickup_animated = wd.pickup_animated
	if wd.pickup_step_frames.size() > 0:
		pickup.pickup_step_frames = wd.pickup_step_frames
	if wd.pickup_step_duration > 0.0:
		pickup.pickup_step_duration = wd.pickup_step_duration

	# —— 远程武器：转移弹药到拾取物 ——
	if wd.is_ranged and wd.magazine_capacity > 0:
		# 弹夹子弹
		var mag: int = state.get_magazine_ammo(wd.item_id)
		pickup.pickup_magazine_ammo = mag
		state.weapon_magazines.erase(wd.item_id)

		# 备弹：从背包取出全部对应弹药，写入拾取物
		var reserve: int = state.count_ammo_item(wd.ammo_item_id)
		if reserve > 0:
			pickup.pickup_reserve_ammo = reserve
			state.consume_ammo_item(wd.ammo_item_id, reserve)

	# 掉落在玩家脚下
	pickup.position = _player_ref.global_position

	# 添加到 GroundLayer 节点下
	var parent: Node = _find_ground_layer()
	if parent:
		parent.add_child(pickup)
	else:
		var tree: SceneTree = get_tree()
		if tree and tree.current_scene:
			tree.current_scene.add_child(pickup)
		else:
			get_parent().add_child(pickup)

	print("[拾取] %s 掉落在地上 (%s) | 弹夹=%d 备弹=%d" % [wd.item_name, pickup.position, pickup.pickup_magazine_ammo, pickup.pickup_reserve_ammo])


func _find_ground_layer() -> Node:
	## 在当前场景中查找 GroundLayer 节点
	var tree: SceneTree = get_tree()
	if not tree or not tree.current_scene:
		return null
	return tree.current_scene.find_child("GroundLayer", true, false)


func _find_ammo_resource(state: PlayerState, ammo_item_id: String) -> ItemData:
	## 根据 ammo_item_id 找到对应的 ItemData 资源。
	## 先在 object/ 目录搜索 .tres 文件，回退到遍历该玩家背包。

	# 方案1：按命名规则推导路径
	var derived := "res://object/item_%s_ammo.tres" % ammo_item_id.trim_prefix("ammo_")
	if ResourceLoader.exists(derived):
		var res: Resource = load(derived)
		if res is ItemData and res.item_id == ammo_item_id:
			return res as ItemData

	# 方案2：也尝试直接用 item_id 拼接
	var direct := "res://object/item_%s.tres" % ammo_item_id
	if direct != derived and ResourceLoader.exists(direct):
		var res: Resource = load(direct)
		if res is ItemData and res.item_id == ammo_item_id:
			return res as ItemData

	# 方案3：从该玩家背包中找已有的弹药实例
	for it: Resource in state.inventory:
		if it is ItemData and it.item_id == ammo_item_id:
			return it as ItemData

	return null


func _on_body_entered(body: Node2D) -> void:
	var player: CharacterBody2D = body as CharacterBody2D
	if player:
		_player_in_range = true
		_player_ref = player
		_hold_timer = 0.0
		player._near_pickup = true


func _on_body_exited(body: Node2D) -> void:
	var player: CharacterBody2D = body as CharacterBody2D
	if player and player == _player_ref:
		_player_in_range = false
		_player_ref._near_pickup = false
		_player_ref = null
		_hold_timer = 0.0


func _refresh_sprite() -> void:
	if not _sprite or not pickup_texture:
		return

	_sprite.texture = pickup_texture
	_sprite.region_enabled = true

	# 当前踏步帧（动画关闭时用第一帧，即站立帧）
	var frame: int
	if pickup_animated and pickup_step_frames.size() > 0:
		frame = pickup_step_frames[_step_idx]
	else:
		frame = pickup_step_frames[0] if pickup_step_frames.size() > 0 else 1

	var char_col: int = pickup_char_idx % CHARS_PER_ROW
	var char_row: int = pickup_char_idx / CHARS_PER_ROW

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + pickup_direction * FRAME_H
	_sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
