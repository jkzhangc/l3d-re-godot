extends RefCounted

## 2K→Godot内容地图模板：图块/点位只属于地图，公共装配属于GameSession。
## @trace SCENE-003, SCENE-005
const MAP_CONTEXT = preload("res://script/map/map_context.gd")


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
	return map


static func _attach(parent: Node, child: Node, owner_root: Node) -> void:
	parent.add_child(child)
	child.owner = owner_root
