extends RefCounted

## ── 架构定位 ──
## 系统：导演 / 物品 ｜ 层：玩法工具（RefCounted，纯静态）
## 联机：**只由单机 / Host 调用**（掉落物走 ground_pickup 组，由 NetworkWorld 收编后下发）
## 职责：把「掉落池」或「单个资源」变成场景里的地面拾取物 —— 敌人死亡掉落与导演投放共用。
## 依赖：DropPoolData、weapon_pickup.tscn、healing_pickup.tscn、SpawnSpotResolver
##
## 【用法】`LOOT_DROPPER.spawn_from_pool(pool, base_pos, anchor_node)`。
## `anchor_node` 必须是**已入树**的 Node2D（取 World2D 做落点探测 + 找 GroundLayer 当父节点）。

const WEAPON_PICKUP_SCENE := preload("res://object/weapon_pickup.tscn")
const WEAPON_PICKUP_SCRIPT := preload("res://script/weapon_pickup.gd")
const ITEM_PICKUP_SCENE := preload("res://object/healing_pickup.tscn")
const SPOT_RESOLVER := preload("res://script/director/spawn_spot_resolver.gd")

## 掉落物父节点：优先 GroundLayer（与尸体、地面物同层，y_sort 与回收口径一致），
## 找不到就退回锚点的父节点（自定义测试场景）。
static func _ground_parent(anchor: Node) -> Node:
	var tree := anchor.get_tree()
	if tree != null and tree.current_scene != null:
		var ground: Node = tree.current_scene.find_child("GroundLayer", true, false)
		if ground != null:
			return ground
	return anchor.get_parent()


## 在 base 附近找一个可站落点。
## ★硬不变量（掉落落点避墙）：`require_tile` 默认 true —— 逐轮只放宽间距、从不放宽
## 「不压进有物理层图块」。一个空位都找不到时**返回 base**：宁可贴尸体，也不把东西丢进墙里。
static func free_spot(anchor: Node2D, base: Vector2, require_tile: bool = true) -> Vector2:
	if anchor == null or not anchor.is_inside_tree():
		return base
	var spot: Variant = SPOT_RESOLVER.find_near(
			anchor, base, SPOT_RESOLVER.PROBE_RADIUS, Callable(), require_tile)
	return spot if spot is Vector2 else base


## 从掉落池按权重抽一项并生成。池为空 / 全 0 权重 → 返回 null（不生成任何东西）。
static func spawn_from_pool(pool: Resource, base: Vector2, anchor: Node2D,
		cap_exempt: bool = false) -> Node2D:
	if pool == null or not pool.has_method("roll"):
		return null
	var picked: Resource = pool.call("roll") as Resource
	return spawn_resource(picked, base, anchor, cap_exempt)


## 生成一件具体的掉落物：WeaponData → weapon_pickup，ItemData → healing_pickup。
static func spawn_resource(res: Resource, base: Vector2, anchor: Node2D,
		cap_exempt: bool = false) -> Node2D:
	if res == null or anchor == null or not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return null
	var parent: Node = _ground_parent(anchor)
	if parent == null:
		return null

	var spawned: Node2D = null
	if res is WeaponData:
		spawned = WEAPON_PICKUP_SCENE.instantiate()
		## 地面显示参数统一走 WeaponData（与 ItemManager / random_pickup 同源）
		WEAPON_PICKUP_SCRIPT.apply_weapon_ground_display(spawned, res as WeaponData)
	elif res is ItemData:
		spawned = ITEM_PICKUP_SCENE.instantiate()
		spawned.item = res
	else:
		push_warning("[LootDropper] 不支持的掉落条目类型: %s" % res.get_class())
		return null

	## ⚠ `cap_exempt` 必须在 add_child **之前**置位（GroundItemCap 在 _ready 里读它）。
	## 敌人掉落不豁免上限 —— 它属于"掉落杂物"，该被 GroundItemCap 淘汰。
	spawned.set("cap_exempt", cap_exempt)
	## 落点先算（要读 TileData + 物理探测），再入树 —— 顺序与 random_pickup 一致。
	var spot: Vector2 = free_spot(anchor, base)
	## ⚠⚠ **必须 deferred 入树**：本函数会被"物理回调链内"调用 ——
	##   `bullet._on_area_entered → enemy.take_damage → _die → _maybe_drop_loot → 这里`，
	##   此时物理服务器正在 flushing_queries；直接 add_child 会让拾取物的 Area2D/碰撞形状
	##   立刻向物理服务器注册 → `area_set_shape_disabled` 报
	##   "Can't change this state while flushing queries"。改用 call_deferred 排到本帧物理之后。
	parent.add_child.call_deferred(spawned)
	spawned.set_deferred("global_position", spot)
	return spawned
