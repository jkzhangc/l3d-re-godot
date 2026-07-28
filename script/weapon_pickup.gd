extends Node2D
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
const HOLD_TIME: float = 2.0


func _ready() -> void:
	if _area:
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)
	_refresh_sprite()


func _process(delta: float) -> void:
	# 踏步动画
	if pickup_animated and pickup_step_frames.size() > 0:
		_step_timer += delta
		if _step_timer >= pickup_step_duration:
			_step_timer -= pickup_step_duration
			_step_idx = (_step_idx + 1) % pickup_step_frames.size()
			_refresh_sprite()

	# 拾取逻辑
	if not _player_in_range or not _player_ref:
		_hold_timer = 0.0
		return
	if not weapon_data:
		return

	var slot: String = weapon_data.get_slot_key()
	var current: WeaponData = Global.get_equipped_weapon(slot)

	# 该槽位为空 → 自动拾取装备
	if current == null:
		_do_pickup()
		return

	# 槽位已有武器 → 需按住确定键替换
	if not _can_hold_pickup():
		_hold_timer = 0.0
		return

	if Input.is_action_pressed("确定键"):
		_hold_timer += delta
		if _hold_timer >= HOLD_TIME:
			_do_pickup()
	else:
		_hold_timer = 0.0


func _can_hold_pickup() -> bool:
	## 玩家在范围内即可拾取（不再限制武器举起/攻击状态）
	return _player_ref != null


func _do_pickup() -> void:
	if not weapon_data:
		return

	var slot: String = weapon_data.get_slot_key()
	var old: WeaponData = Global.get_equipped_weapon(slot)

	if old:
		_drop_weapon(old, slot)
		print("[拾取] 替换 %s 槽: %s → %s" % [slot, old.item_name, weapon_data.item_name])
	else:
		print("[拾取] 装备到 %s 槽: %s" % [slot, weapon_data.item_name])

	Global.equipment[slot] = weapon_data

	# —— 弹药处理 ——
	# 弹夹子弹
	if weapon_data.is_ranged and weapon_data.magazine_capacity > 0:
		if pickup_magazine_ammo >= 0:
			# 使用指定的弹夹子弹数
			Global.set_magazine_ammo(weapon_data.item_id, clampi(pickup_magazine_ammo, 0, weapon_data.magazine_capacity))
		else:
			# -1 = 自动填满弹夹
			Global.set_magazine_ammo(weapon_data.item_id, weapon_data.magazine_capacity)

	# 备弹（库存弹药物品）
	if pickup_reserve_ammo > 0 and not weapon_data.ammo_item_id.is_empty():
		var ammo_res := _find_ammo_resource(weapon_data.ammo_item_id)
		if ammo_res:
			for _i: int in range(pickup_reserve_ammo):
				Global.inventory.append(ammo_res.duplicate())
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
		var mag: int = Global.weapon_magazines.get(wd.item_id, 0)
		pickup.pickup_magazine_ammo = mag
		Global.weapon_magazines.erase(wd.item_id)

		# 备弹：从背包取出全部对应弹药，写入拾取物
		var reserve: int = Global.count_ammo_item(wd.ammo_item_id)
		if reserve > 0:
			pickup.pickup_reserve_ammo = reserve
			Global.consume_ammo_item(wd.ammo_item_id, reserve)

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


func _find_ammo_resource(ammo_item_id: String) -> ItemData:
	## 根据 ammo_item_id 找到对应的 ItemData 资源。
	## 先在 object/ 目录搜索 .tres 文件，回退到遍历已加载资源。

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

	# 方案3：从 Global.inventory 或已装备中找已有的弹药实例
	for it: Resource in Global.inventory:
		if it is ItemData and it.item_id == ammo_item_id:
			return it as ItemData

	return null


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
