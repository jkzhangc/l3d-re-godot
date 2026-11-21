extends SceneTree

## @trace SCENE-004, SCENE-005, FLOW-002, FLOW-003
var _checks: int = 0
var _fails: int = 0
var _hud_id: int = 0
var _camera_id: int = 0
var _session_id: int = 0
const SESSION = preload("res://script/flow/game_session.gd")
const LOCATOR = preload("res://script/map/map_locator.gd")


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])


func _run() -> void:
	await process_frame
	var paths: Array[String] = [
		"res://scene/maps/突袭-第一关-街道.tscn",
		"res://scene/maps/突袭-第二关-学校内部.tscn",
		"res://scene/maps/夜行猎手-第三关-电视台内-二楼.tscn",
		"res://scene/maps/test.tscn",
	]
	for path: String in paths:
		_check(SESSION.request_map(self, path) == OK, "请求地图成功 " + path.get_file())
		for _frame: int in range(60):
			await physics_frame
		var session: Node = SESSION.find(self)
		var map: Node = LOCATOR.get_map_root(self)
		_check(map != null and map.scene_file_path == path, "current_scene保留源地图身份")
		_check(map != null and map.get_parent() == session.get("map_host"), "地图在常驻MapHost下")
		var player: CharacterBody2D = LOCATOR.find_preplaced_player(map)
		_check(player != null and player.get_parent() == LOCATOR.find_actor_container(map), "动态玩家直接参与排序")
		_check(get_nodes_in_group("player").size() == 1, "无旧图玩家残留")
		_check(get_nodes_in_group("combat_hud").size() == 1, "公共HUD仅一份")
		_check(get_nodes_in_group("local_pause_menu").size() == 1, "公共菜单仅一份")
		var hud: Node = session.get("hud")
		var camera: Camera2D = session.get("camera") as Camera2D
		if _hud_id == 0:
			_hud_id = hud.get_instance_id()
			_camera_id = camera.get_instance_id()
			_session_id = session.get_instance_id()
		_check(hud.get_instance_id() == _hud_id, "HUD实例跨图保留")
		_check(camera.get_instance_id() == _camera_id, "Camera实例跨图保留")
		_check(session.get_instance_id() == _session_id, "Session实例跨图保留")
		_check(root.get_node("Players").call("get_local_entity") == player, "本机注册指向新图玩家")
		var phantom: Node = camera.get_node("PhantomCamera2D")
		_check(phantom.get("follow_target") == player, "相机重绑定新图玩家")
		_check(map.get_node("GameInit") != null, "地图装配一次")
		var origin: Vector2 = player.global_position
		player.global_position += Vector2(32, 0)
		for _frame: int in range(20):
			await physics_frame
		_check(player.global_position.distance_to(origin) >= 16.0, "地图输入未被旧加载层永久锁定")
	# 同一地图重建仍保留会话，但替换实例。
	var previous_id: int = LOCATOR.get_map_root(self).get_instance_id()
	SESSION.request_map(self, paths[-1])
	for _frame: int in range(45):
		await physics_frame
	_check(LOCATOR.get_map_root(self).get_instance_id() != previous_id, "同图重载创建新实例")
	_check(SESSION.find(self).get_instance_id() == _session_id, "同图重载不重建会话")
	root.get_node("Director").call("_reset_live_combat_state")
	root.get_node("Director").set_process(false)
	SESSION.end_session(self)
	current_scene = null
	await process_frame
	await process_frame
	_check(SESSION.find(self) == null, "离局释放常驻会话")
	_check(get_nodes_in_group("combat_hud").is_empty(), "离局无残留HUD")
	print("GAME_SESSION_CHECK: %d checks / %d failed" % [_checks, _fails])
	quit(0 if _fails == 0 else 1)
