class_name MapContext extends Node2D

## 地图内容契约；公共装配由GameSession持有，本节点保留F6启动入口。
## @trace SCENE-001, SCENE-003, SCENE-005
## 节点路径均相对于地图根，不改变机关与存档的相对路径。

@export var map_id: String = ""
@export var actor_container_path: NodePath = ^"DecorLayer"
@export var player_spawn_path: NodePath = ^"PlayerSpawn"
@export var camera_boundary_paths: Array[NodePath] = []
@export var director_config_path: NodePath
@export var camera_follow_speed: float = 6.0
@export var camera_zoom: Vector2 = Vector2(2, 2)
@export var camera_bounds_margin: float = 0.0
@export var session_enabled: bool = true


func _ready() -> void:
	if session_enabled:
		call_deferred("_attach_session")


func _attach_session() -> void:
	if not is_inside_tree():
		return
	var session_script: Script = load("res://script/flow/game_session.gd") as Script
	var session: Node = session_script.ensure(get_tree())
	session.call("attach_map", self)


func get_actor_container() -> Node2D:
	if actor_container_path.is_empty():
		return null
	var candidate: Node = get_node_or_null(actor_container_path)
	if candidate is Node2D and candidate != self and is_ancestor_of(candidate):
		return candidate as Node2D
	return null


func get_player_spawn_marker() -> Node2D:
	if player_spawn_path.is_empty():
		return null
	var candidate: Node = get_node_or_null(player_spawn_path)
	if candidate is Node2D and candidate != self and is_ancestor_of(candidate):
		return candidate as Node2D
	return null


func get_camera_boundary_layers() -> Array[TileMapLayer]:
	var layers: Array[TileMapLayer] = []
	for path: NodePath in camera_boundary_paths:
		var candidate: Node = get_node_or_null(path)
		if candidate is TileMapLayer and is_ancestor_of(candidate):
			layers.append(candidate as TileMapLayer)
	return layers


func get_map_scene_path() -> String:
	return scene_file_path
