extends Node

## 会话持有公共UI与镜头；引擎current_scene是本会话，MapLocator保留源地图身份。
## 存档与机关始终相对于活动地图，不写入GameSession路径。
## @trace SCENE-004, FLOW-002
const LOCATOR = preload("res://script/map/map_locator.gd")
const CONTEXT = preload("res://script/map/map_context.gd")
const SESSION_NAME := "GameSession"
var active_map: Node2D = null
var map_host: Node2D = null
var ui_host: Node = null
var camera: Camera2D = null
var hud: CanvasLayer = null
var menu: CanvasLayer = null
var _generation: int = 0
var _changing: bool = false
var _closing: bool = false


static func find(tree: SceneTree) -> Node:
	return tree.root.get_node_or_null(SESSION_NAME) if tree != null else null


static func ensure(tree: SceneTree) -> Node:
	var existing: Node = find(tree)
	if existing != null:
		return existing
	var script: Script = load("res://script/flow/game_session.gd") as Script
	var session: Node = script.new()
	session.name = SESSION_NAME
	tree.root.add_child(session)
	return session


static func request_map(tree: SceneTree, path: String) -> Error:
	if tree == null:
		return ERR_UNCONFIGURED
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		return ERR_CANT_OPEN
	var session: Node = ensure(tree)
	session.call_deferred("_replace_map", path, packed)
	return OK


static func end_session(tree: SceneTree) -> void:
	var session: Node = find(tree)
	if session != null:
		session.call("close_session")


func _ready() -> void:
	map_host = Node2D.new()
	map_host.name = "MapHost"
	add_child(map_host)
	ui_host = Node.new()
	ui_host.name = "GameplayUI"
	add_child(ui_host)


## F6/旧测试宿主的地图保持原父节点，避免已ready子树整体reparent的退树副作用。
## 由request_map加载的正常生产路径则直接创建在MapHost下。
func attach_map(map: Node2D) -> void:
	if _closing or not is_instance_valid(map) or not map.is_inside_tree():
		return
	if active_map == map and map.has_meta("session_initialized"):
		return
	map.set_meta("session_initialized", true)
	_generation += 1
	var generation: int = _generation
	active_map = map
	map.tree_exiting.connect(_on_map_exiting.bind(map.get_instance_id()), CONNECT_ONE_SHOT)
	_prepare_local_ui(map)
	## BGS 环境音：编辑器里没有 BGS 总线可选（运行时才创建），载入时按节点名统一挂载。
	## node_added 已能覆盖绝大多数情况，这里对整张图再扫一遍兜底（含 preload 的子树）。
	var global: Node = get_node_or_null("/root/Global")
	if global != null and global.has_method("route_map_bgs"):
		var routed: int = int(global.call("route_map_bgs", map))
		if routed > 0:
			print("[GameSession] BGS 总线路由 %d 个播放器（%s）" % [routed, map.scene_file_path])
	var actors: Node2D = LOCATOR.find_actor_container(map)
	if actors == null:
		push_error("[GameSession] 地图没有角色排序容器：%s" % map.scene_file_path)
		return
	if LOCATOR.find_preplaced_player(map) == null:
		var packed_player: PackedScene = load("res://object/player.tscn") as PackedScene
		var player: Node2D = packed_player.instantiate() as Node2D
		player.name = "Player"
		var spawn: Node2D = map.call("get_player_spawn_marker") as Node2D
		actors.add_child(player)
		if spawn != null:
			player.global_position = spawn.global_position
		if camera != null:
			camera.call("set_follow_target", player)
	_configure_camera(map)
	if generation != _generation or not is_instance_valid(map):
		return
	var init := Node.new()
	init.name = "GameInit"
	init.set_script(load("res://script/game_init.gd"))
	map.add_child(init)
	print("[GameSession] MAP_ENTER path=%s generation=%d hud=%d" % [
		map.scene_file_path, generation, hud.get_instance_id()])


func _prepare_local_ui(_map: Node2D) -> void:
	if not is_instance_valid(hud):
		hud = (load("res://scene/ui/combat_hud.tscn") as PackedScene).instantiate() as CanvasLayer
		hud.name = "CombatHUD"
		ui_host.add_child(hud)
	if not is_instance_valid(menu):
		menu = (load("res://scene/menu.tscn") as PackedScene).instantiate() as CanvasLayer
		menu.name = "Menu"
		ui_host.add_child(menu)
	if not is_instance_valid(camera):
		camera = Camera2D.new()
		camera.name = "Camera2D"
		camera.set_script(load("res://script/camera_follow.gd"))
		add_child(camera)
	hud.visible = true
	hud.set_process(true)
	hud.call("hide_holdout")
	camera.enabled = true


func _configure_camera(map: Node2D) -> void:
	var paths: Array[NodePath] = []
	for layer: TileMapLayer in map.call("get_camera_boundary_layers"):
		paths.append(camera.get_path_to(layer))
	camera.set("bound_layers", paths)
	camera.set("follow_speed", map.get("camera_follow_speed"))
	camera.set("default_zoom", map.get("camera_zoom"))
	camera.set("bounds_margin", map.get("camera_bounds_margin"))
	camera.call("refresh_map_binding", LOCATOR.find_preplaced_player(map))


func _replace_map(path: String, packed: PackedScene) -> void:
	if _changing or _closing:
		return
	_changing = true
	var tree: SceneTree = get_tree()
	var old: Node = tree.current_scene
	if is_instance_valid(active_map):
		old = active_map
	if old != null and old != self:
		if tree.current_scene == old:
			tree.current_scene = null
		old.queue_free()
		await tree.process_frame
	if not is_inside_tree() or _closing:
		return
	var map: Node2D = packed.instantiate() as Node2D
	if map == null:
		_changing = false
		push_error("[GameSession] 目标地图根不是Node2D：%s" % path)
		return
	# current_scene只能是root直接子节点；业务地图身份统一走MapLocator。
	tree.current_scene = self
	# 子节点_ready之前设置活动地图，保证随机拾取键使用源地图相对路径。
	active_map = map
	map.set_meta("session_owned", true)
	map_host.add_child(map)
	_changing = false
	if not is_instance_of(map, CONTEXT):
		push_warning("[GameSession] 目标尚未使用MapContext，沿用其旧装配：%s" % path)


func _on_map_exiting(map_instance_id: int) -> void:
	if not is_instance_valid(active_map) or active_map.get_instance_id() != map_instance_id:
		return
	_generation += 1
	active_map = null
	if is_instance_valid(camera):
		camera.call("set_follow_target", null)
		camera.enabled = false
	if is_instance_valid(hud):
		hud.call("hide_holdout")
		hud.visible = false
		hud.set_process(false)
	if is_instance_valid(menu):
		menu.call("reset_for_map_change")
	call_deferred("_release_if_not_gameplay", _generation)


func _release_if_not_gameplay(generation: int) -> void:
	if generation != _generation or _changing or _closing or active_map != null:
		return
	var scene: Node = get_tree().current_scene
	if scene != null and not is_instance_of(scene, CONTEXT):
		close_session()


func close_session() -> void:
	if _closing:
		return
	_closing = true
	_generation += 1
	if is_instance_valid(active_map) and active_map.get_parent() == map_host:
		# SceneTree换图将释放current_scene；先从宿主摘除，避免重复queue_free。
		if get_tree().current_scene != active_map:
			active_map.queue_free()
	active_map = null
	if is_instance_valid(camera):
		camera.call("set_follow_target", null)
	if is_instance_valid(menu):
		menu.call("reset_for_map_change")
	queue_free()
