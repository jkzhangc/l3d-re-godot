@tool
extends RefCounted

## 2K→Godot内容地图模板：图块/点位只属于地图，公共装配属于GameSession。
## @trace SCENE-003, SCENE-005
const MAP_CONTEXT = preload("res://script/map/map_context.gd")
## 玩法资源延迟到生成函数中加载：--script 解析模板时 autoload 尚未注册，
## preload random_pickup 会让其依赖里的 Global/Players 编译失败。
const RANDOM_PICKUP_PATH := "res://object/random_pickup.tscn"
const RANDOM_PICKUP_SCRIPT_PATH := "res://script/random_pickup.gd"
const DROP_POOL_PATH := "res://script/director/drop_pool_data.gd"
const PICKUP_GENERATOR := "rm2k3_fixed_pickup_v1"
const SOURCE_META := "rm2k3_source_key"
const GENERATOR_META := "rm2k3_generator"


static func create_map(data: Dictionary, lower_tileset: TileSet, upper_tileset: TileSet) -> Node2D:
	var map: Node2D = MAP_CONTEXT.new()
	map.name = "Map%04d" % int(data.map_id)
	map.set("map_id", "rm2k3_%04d" % int(data.map_id))
	var bounds: Array[NodePath] = [^"GroundLayer", ^"UpperLayer"]
	map.set("camera_boundary_paths", bounds)
	var ground := TileMapLayer.new()
	ground.name = "GroundLayer"
	ground.tile_set = lower_tileset
	_attach(map, ground, map)
	var decor := Node2D.new()
	decor.name = "DecorLayer"
	decor.y_sort_enabled = true
	_attach(map, decor, map)
	var upper := TileMapLayer.new()
	upper.name = "UpperLayer"
	upper.y_sort_enabled = true
	upper.tile_set = upper_tileset
	_attach(map, upper, map)
	var spawn := Marker2D.new()
	spawn.name = "PlayerSpawn"
	spawn.position = Vector2(float(data.width) * float(data.tile_size) * 0.5,
		float(data.height) * float(data.tile_size) * 0.5)
	_attach(map, spawn, map)
	sync_item_pickups(map, data)
	return map


## 只管理带本工具标记的节点；作者节点、图块、TileSet及其他属性绝不重建。
## 稳定节点名决定原有random_pickup的存档键；重跑不随事件名称/物品改名。
static func sync_item_pickups(map: Node2D, data: Dictionary) -> Dictionary:
	var stats := {"added": 0, "updated": 0, "removed": 0, "skipped": 0}
	if not data.has("item_pickups") or not bool(data.get("item_pickups_export_ok", true)):
		return stats
	if not data.item_pickups is Array:
		push_warning("item_pickups不是数组，保留现有点位")
		return stats
	var decor := map.get_node_or_null("DecorLayer")
	if not decor is Node2D:
		push_warning("缺少DecorLayer，不修改现有地图")
		return stats
	var existing: Dictionary = {}
	for child in decor.get_children():
		if child.get_meta(GENERATOR_META, "") == PICKUP_GENERATOR:
			var key := str(child.get_meta(SOURCE_META, ""))
			if not existing.has(key):
				existing[key] = []
			existing[key].append(child)
	var keep: Dictionary = {}
	# 暂时无法识别/映射的源事件，不借一次失败删除上次成功生成的点。
	for preserve_key in data.get("item_pickups_preserve_keys", []):
		keep[str(preserve_key)] = true
	var seen: Dictionary = {}
	var may_remove := true
	for value in data.item_pickups:
		if not value is Dictionary:
			stats.skipped += 1
			may_remove = false
			continue
		var entry: Dictionary = value
		var key := str(entry.get("source_key", ""))
		var event_id := int(entry.get("event_id", 0))
		var expected_key := "rm2k3:map:%04d:event:%04d" % [int(data.map_id), event_id]
		if key != expected_key or event_id <= 0 or seen.has(key):
			push_warning("忽略无效/重复物品source_key：%s" % key)
			stats.skipped += 1
			may_remove = false
			continue
		seen[key] = true
		keep[key] = true
		# 单页事件用一项；同一事件的多个可达页（原作状态变量分档）合成多项随机池。
		var pool_items: Array[Resource] = []
		var pool_weights: Array[float] = []
		var entry_items: Array = entry.get("items", [])
		if entry_items is Array and not entry_items.is_empty():
			for value2: Variant in entry_items:
				if not value2 is Dictionary:
					continue
				var resolved: Resource = _load_pool_item(value2 as Dictionary)
				if resolved != null:
					pool_items.append(resolved)
					pool_weights.append(maxf(float((value2 as Dictionary).get("weight", 1.0)), 0.0))
		else:
			var single: Resource = _load_pool_item(entry)
			if single != null:
				pool_items.append(single)
				pool_weights.append(1.0)
		if pool_items.is_empty():
			push_warning("原作物品资源无效，保留旧点位：%s" % key)
			stats.skipped += 1
			continue
		# 野外补给点有概率不刷新：池里追加一个空条目（roll 返回 null → 本点不出物）。
		# 安全屋的 empty_weight 为 0，必出。空条目不参与 _load_pool_item 校验。
		var empty_weight := float(entry.get("empty_weight", 0.0))
		if empty_weight > 0.0:
			pool_items.append(null)
			pool_weights.append(empty_weight)
		var point: Node2D = null
		var duplicates: Array = existing.get(key, [])
		if not duplicates.is_empty():
			point = duplicates[0] as Node2D
			if point == null or point.get_script() == null \
					or str(point.get_script().resource_path) != RANDOM_PICKUP_SCRIPT_PATH:
				push_warning("生成标记指向非random_pickup节点，跳过：%s" % key)
				stats.skipped += 1
				continue
		else:
			var node_name := "ItemPickupPoint_RM2K3_E%04d" % event_id
			if decor.has_node(NodePath(node_name)):
				push_warning("作者节点占用生成名称，保持原节点：%s" % node_name)
				stats.skipped += 1
				continue
			point = (load(RANDOM_PICKUP_PATH) as PackedScene).instantiate() as Node2D
			point.name = node_name
			_attach(decor, point, map)
			stats.added += 1
		# 池内容可能是一项（固定物品）或同一事件多页的多项（原作随机档位）。
		var pool: Resource = (load(DROP_POOL_PATH) as Script).new()
		pool.set("items", pool_items)
		pool.set("weights", pool_weights)
		point.set("pool", pool)
		point.position = Vector2(float(entry.get("x", 0)) * 32.0 + 16.0,
			float(entry.get("y", 0)) * 32.0 + 16.0)
		point.set_meta(GENERATOR_META, PICKUP_GENERATOR)
		point.set_meta(SOURCE_META, key)
		point.set_meta("rm2k3_source", entry.duplicate(true))
		if not duplicates.is_empty():
			stats.updated += 1
			for duplicate in duplicates.slice(1):
				decor.remove_child(duplicate)
				duplicate.free()
				stats.removed += 1
	if may_remove:
		for key in existing:
			var map_prefix := "rm2k3:map:%04d:event:" % int(data.map_id)
			if keep.has(key) or not str(key).begins_with(map_prefix):
				continue
			for stale in existing[key]:
				decor.remove_child(stale)
				stale.free()
				stats.removed += 1
	return stats


## 校验并加载池条目；类型/ID 不符返回 null（调用方据此跳过该条或整个点）。
## 多页池条目可能没有顶层 item_id（item_id 只在单页时写），此时只校验类型。
static func _load_pool_item(entry: Dictionary) -> Resource:
	var path := str(entry.get("resource_path", ""))
	if not path.begins_with("res://object/") or not path.ends_with(".tres") \
			or not ResourceLoader.exists(path):
		return null
	var item: Resource = load(path)
	if not (item is ItemData or item is WeaponData):
		return null
	var expected := str(entry.get("item_id", ""))
	if not expected.is_empty() and str(item.get("item_id")) != expected:
		return null
	return item


static func _attach(parent: Node, child: Node, owner_root: Node) -> void:
	parent.add_child(child)
	child.owner = owner_root
