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
## 掉落物与玩家中心的**最小**距离（像素，2026-10-27）。
## 依据：掉落精灵半宽 24 + 玩家碰撞半宽 12 = 36 → 取 40 才能保证两张 48px 宽的精灵不重叠；
## 同时 40 落在环形搜索的 24/48 之间 → 实际落点至少离开玩家 48px（一格半）。
const PLAYER_CLEAR_RADIUS: float = 40.0

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
##
## ★避玩家（2026-10-27 用户反馈「有时候放置掉落物会直接放在玩家身上」）：
## `SpawnSpotResolver` 的物理探测只保证"不压在玩家碰撞体里"（probe 14 + 玩家半宽 12 ≈ 26px），
## 而掉落精灵 48×64、原点在脚部 —— 落在脚边 25px 时视觉上仍整个压在玩家身上。
## 因此这里额外要求与任一玩家中心 ≥ `PLAYER_CLEAR_RADIUS`。
## ⚠ **武器替换掉落不走本函数**（见 weapon_pickup.drop_weapon_for_player）：用户明确允许
## 换枪后的旧武器落在玩家位置，那里不需要避玩家。
static func free_spot(anchor: Node2D, base: Vector2, require_tile: bool = true,
		avoid_players: bool = true) -> Vector2:
	if anchor == null or not anchor.is_inside_tree():
		return base
	var extra_ok: Callable = Callable()
	if avoid_players:
		extra_ok = _player_clear_check(anchor)
	var spot: Variant = SPOT_RESOLVER.find_near(
			anchor, base, SPOT_RESOLVER.PROBE_RADIUS, extra_ok, require_tile)
	return spot if spot is Vector2 else base


## 附加判据：候选点与任何玩家实体的中心距不足 `PLAYER_CLEAR_RADIUS` → 不接受。
## 拿不到玩家注册表（纯节点测试场景）时返回空 Callable（退化为不避玩家，不会更严）。
static func _player_clear_check(anchor: Node) -> Callable:
	var players: Node = anchor.get_node_or_null("/root/Players")
	if players == null or not players.has_method("all_entities"):
		return Callable()
	return func(pos: Vector2) -> bool:
		for entity: Node2D in players.call("all_entities", true):
			if entity == null or not is_instance_valid(entity):
				continue
			if entity.global_position.distance_to(pos) < PLAYER_CLEAR_RADIUS:
				return false
		return true


## 从掉落池按权重抽一项并生成。池为空 / 全 0 权重 → 返回 null（不生成任何东西）。
static func spawn_from_pool(pool: Resource, base: Vector2, anchor: Node2D,
		cap_exempt: bool = false, avoid_players: bool = true) -> Node2D:
	if pool == null or not pool.has_method("roll"):
		return null
	var picked: Resource = pool.call("roll") as Resource
	return spawn_resource(picked, base, anchor, cap_exempt, avoid_players)


## 生成一件具体的掉落物：WeaponData → weapon_pickup，ItemData → healing_pickup。
static func spawn_resource(res: Resource, base: Vector2, anchor: Node2D,
		cap_exempt: bool = false, avoid_players: bool = true) -> Node2D:
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
	var spot: Vector2 = free_spot(anchor, base, true, avoid_players)
	## ⚠⚠ **必须 deferred 入树**：本函数会被"物理回调链内"调用 ——
	##   `bullet._on_area_entered → enemy.take_damage → _die → _maybe_drop_loot → 这里`，
	##   此时物理服务器正在 flushing_queries；直接 add_child 会让拾取物的 Area2D/碰撞形状
	##   立刻向物理服务器注册 → `area_set_shape_disabled` 报
	##   "Can't change this state while flushing queries"。改用 call_deferred 排到本帧物理之后。
	parent.add_child.call_deferred(spawned)
	spawned.set_deferred("global_position", spot)
	return spawned
