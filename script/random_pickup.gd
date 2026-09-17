@tool
extends Node2D

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node2D）
## 联机：仅单机/Host 刷出；拾取交互随具体拾取物节点（weapon_pickup/healing_pickup）
## 职责：随机掉落物：_ready 时从掉落池按权重抽一项，生成对应的地面拾取物后自毁。
## 依赖：DropPoolData、weapon_pickup.tscn、healing_pickup.tscn
##
## 【用法】把 object/random_pickup.tscn 摆进地图（或由 ItemManager 动态生成），
## Inspector 里设 pool（DropPoolData 资源）——生成时即随机决定里面是什么。

const WEAPON_PICKUP_SCENE := preload("res://object/weapon_pickup.tscn")
const WEAPON_PICKUP_SCRIPT := preload("res://script/weapon_pickup.gd")
const ITEM_PICKUP_SCENE := preload("res://object/healing_pickup.tscn")

const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

@export var pool: DropPoolData:
	set(v):
		pool = v
		## Inspector 里换掉落池即时刷占位预览；仅编辑器（_editor_preview 建预览节点，
		## 运行时不需要也不能建）
		if Engine.is_editor_hint() and is_inside_tree():
			_editor_preview()  ## 掉落池（武器/物品混合，按权重随机）

## 2026-09-13 用户需求：开启后刷出的拾取物需要靠近按住功能键(D)才拾取
## （武器空槽也不再触碰自动拾取）；关闭（默认）保持触碰拾取。透传给刷出的拾取物。
@export var require_function_key: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		_editor_preview()
		return
	var picked: Resource = pool.roll() if pool else null
	if picked == null:
		print("[随机掉落物] 掉落池为空或全 0 权重，未生成拾取物")
		queue_free()
		return

	var parent: Node = get_parent()
	var pos := global_position
	var spawned: Node2D = null

	if picked is WeaponData:
		var wd: WeaponData = picked as WeaponData
		var wp: Node2D = WEAPON_PICKUP_SCENE.instantiate()
		# 地面显示参数统一走 WeaponData（2026-09-13：完全按武器数据来）
		WEAPON_PICKUP_SCRIPT.apply_weapon_ground_display(wp, wd)
		wp.set("require_function_key", require_function_key)
		spawned = wp
	elif picked is ItemData:
		var ip: Node2D = ITEM_PICKUP_SCENE.instantiate()
		ip.item = picked as ItemData
		ip.set("require_function_key", require_function_key)
		spawned = ip
	else:
		push_warning("[随机掉落物] 掉落池条目类型不支持: %s" % picked.get_class())
		queue_free()
		return

	# 本节点常在父节点构建子节点期间被实例化（如 Director 的生成流程），
	# 直接 add_child 会报 "Parent node is busy setting up children" → 推迟到帧末；
	# global_position 也延迟到入树后再设置（未入树时该属性语义不完整）。
	# 预摆在地图里的 random_pickup（owner 非空）刷出的拾取物继承「预摆」身份，
	# 豁免 GroundItemCap(8)——初始安全屋的补给囤积不属于掉落杂物。
	var is_placed: bool = owner != null
	spawned.set("cap_exempt", is_placed)
	parent.add_child.call_deferred(spawned)
	spawned.set_deferred("global_position", pos)
	print("[随机掉落物] 刷出 %s（%s）@ (%d, %d)" % [
		picked.get("item_name") if picked.get("item_name") else picked.resource_name,
		"武器" if picked is WeaponData else "物品",
		int(pos.x), int(pos.y)])
	queue_free()


## 编辑器预览（@tool）：显示掉落池**第一项**的图当作占位参考。
## ⚠ 实际刷出项按权重随机，预览不代表必出；只用来在摆点时确认"这里有个掉落物"。
## PreviewSprite 不设 owner → 不会被打进 .tscn。
func _editor_preview() -> void:
	var sprite: Sprite2D = get_node_or_null("PreviewSprite") as Sprite2D
	if not sprite:
		sprite = Sprite2D.new()
		sprite.name = "PreviewSprite"
		add_child(sprite)
	sprite.position = Vector2.ZERO
	sprite.region_enabled = false
	sprite.texture = null
	if pool == null or pool.items.is_empty():
		return

	var first: Resource = pool.items[0]
	if first is WeaponData:
		var wd := first as WeaponData
		if wd.pickup_texture:
			sprite.texture = wd.pickup_texture
			sprite.region_enabled = true
			sprite.region_rect = _walk_frame_rect(wd.pickup_char_idx, wd.pickup_direction)
		elif wd.weapon_walk_texture:
			var seq: Array[int] = wd.get_raise_char_sequence()
			var char_idx: int = seq[0] if seq.size() > 0 else 0
			sprite.texture = wd.weapon_walk_texture
			sprite.region_enabled = true
			sprite.region_rect = _walk_frame_rect(char_idx, 0)
	elif first is ItemData:
		var it := first as ItemData
		if it.pickup_texture:
			sprite.texture = it.pickup_texture
			sprite.region_enabled = true
			sprite.region_rect = _walk_frame_rect(it.pickup_char_idx, it.pickup_direction)
		elif it.icon:
			sprite.texture = it.icon
			sprite.region_enabled = false


## VX Ace 行走图 48x64 裁帧（与 weapon_pickup/healing_pickup 同一寻址规则）
func _walk_frame_rect(char_idx: int, direction: int) -> Rect2:
	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var x: int = char_col * (FRAME_W * 3) + 1 * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + clampi(direction, 0, DIRECTIONS - 1) * FRAME_H
	return Rect2(x, y, FRAME_W, FRAME_H)
