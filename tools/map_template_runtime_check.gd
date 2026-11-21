extends SceneTree

## 真实转换产物启动验收，不写存档和配置。由 test_map_scene_template.py 调用。
## @trace FLOW-001
const LOCATOR = preload("res://script/map/map_locator.gd")
var _checks: int = 0
var _fails: int = 0


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])


func _run() -> void:
	await process_frame
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("需要传入生成场景路径")
		quit(2)
		return
	var packed: PackedScene = load(args[0]) as PackedScene
	if packed == null:
		quit(3)
		return
	var map: Node2D = packed.instantiate() as Node2D
	root.add_child(map)
	current_scene = map
	for _i: int in range(45):
		await physics_frame
	var player: CharacterBody2D = LOCATOR.find_preplaced_player(map)
	var actors: Node2D = LOCATOR.find_actor_container(map)
	_check(player != null and player.get_parent() == actors, "生成图玩家保持直接排序，无初始化重挂")
	_check(map.get_node("PlayerSpawn").get_child_count() == 0, "出生标记运行后不拥有活体")
	var players: Node = root.get_node("Players")
	_check(players.call("get_local_entity") == player, "本机玩家注册与座位绑定正常")
	var camera: Camera2D = root.get_viewport().get_camera_2d()
	_check(camera != null, "生成图具有活动相机")
	var phantom: Node = camera.get_node_or_null("PhantomCamera2D") if camera != null else null
	_check(phantom != null and phantom.get("follow_target") == player, "跟随相机绑定到本机玩家")
	_check(get_nodes_in_group("combat_hud").size() == 1, "仅一份公共HUD实例")
	_check(map.get_node("GroundLayer").get_used_cells().size() == 768, "地面768格内容完整")
	_check(map.get_node("UpperLayer").get_used_cells().size() == 1, "上层图块内容完整")
	_check(LOCATOR.get_map_scene_path(self) == args[0], "current_scene仍为源地图路径")
	var spawn: Node2D = map.get_node("PlayerSpawn") as Node2D
	_check(player != null and player.global_position.distance_to(spawn.global_position) < 0.1, "启动未覆盖作者出生位置")
	if player != null and camera != null:
		player.global_position += Vector2(96, 0)
		for _i: int in range(90):
			await physics_frame
		_check(camera.global_position.distance_to(player.global_position) < 8.0, "生成图相机移动后仍跟随")
	print("MAP_TEMPLATE_RUNTIME_CHECK: %d checks / %d failed" % [_checks, _fails])
	var director: Node = root.get_node("Director")
	director.call("_reset_live_combat_state")
	director.call("stop_all_music")
	director.set_process(false)
	var session_script: Script = load("res://script/flow/game_session.gd") as Script
	session_script.end_session(self)
	current_scene = null
	map.queue_free()
	packed = null
	await process_frame
	await create_timer(0.15, true).timeout
	quit(0 if _fails == 0 else 1)
