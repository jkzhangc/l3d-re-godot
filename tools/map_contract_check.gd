extends SceneTree

## 地图契约与转换模板结构回归，不修改人工地图、存档或配置。
## @trace FLOW-001
## 运行：Godot --headless --path <项目> --script res://tools/map_contract_check.gd
const LOCATOR = preload("res://script/map/map_locator.gd")
const CONTEXT = preload("res://script/map/map_context.gd")
const TEMPLATE = preload("res://script/map_restore/map_scene_template.gd")
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
	_check(LOCATOR.find_actor_container(null) == null, "null 地图查询安全")
	var legacy := Node2D.new()
	var decor := TileMapLayer.new()
	decor.name = "DecorLayer"
	legacy.add_child(decor)
	_check(LOCATOR.find_actor_container(legacy) == decor, "旧 TileMapLayer 排序域兼容")
	var player := CharacterBody2D.new()
	player.name = "Player"
	decor.add_child(player)
	_check(LOCATOR.find_preplaced_player(legacy) == player, "未入树预置玩家可用于早期到达点")
	_check(LOCATOR.find_preplaced_player(legacy, false) == null, "联机查找不提前接管未就绪玩家")
	legacy.free()
	_check(LOCATOR.find_actor_container(legacy) == null, "释放后的地图引用查询安全")
	_check(LOCATOR.find_legacy_actor_container(legacy) == null, "旧图回退拒绝已释放引用")
	_check(LOCATOR.find_preplaced_player(legacy) == null, "玩家查找拒绝已释放引用")
	var explicit: Node2D = CONTEXT.new()
	var actors := Node2D.new()
	actors.name = "Actors"
	actors.y_sort_enabled = true
	explicit.add_child(actors)
	explicit.set("actor_container_path", NodePath("Actors"))
	_check(LOCATOR.find_actor_container(explicit) == actors, "显式容器不依赖 decor 名称")
	var fallback := Node2D.new()
	fallback.name = "DecorFallback"
	explicit.add_child(fallback)
	explicit.set("actor_container_path", NodePath("Missing"))
	_check(LOCATOR.find_actor_container(explicit) == fallback, "坏配置只在本图执行旧图回退")
	explicit.set("actor_container_path", NodePath(".."))
	_check(explicit.get_actor_container() == null, "契约禁止越出地图根")
	explicit.free()
	_test_player_scope()
	_test_template()
	_test_existing_maps()
	print("MAP_CONTRACT_CHECK: %d checks / %d failed" % [_checks, _fails])
	quit(0 if _fails == 0 else 1)


func _test_player_scope() -> void:
	var unrelated := Node2D.new()
	unrelated.name = "UnrelatedScene"
	root.add_child(unrelated)
	var outsider := CharacterBody2D.new()
	unrelated.add_child(outsider)
	outsider.add_to_group("player")
	var map := Node2D.new()
	map.name = "ScopedMap"
	root.add_child(map)
	var local_player := CharacterBody2D.new()
	map.add_child(local_player)
	local_player.add_to_group("player")
	_check(LOCATOR.find_preplaced_player(map, false) == local_player, "忽略其他场景 player 组成员")
	_check(LOCATOR.find_actor_container(map) == null, "无容器地图不从其他根分支找替代品")
	map.free()
	unrelated.free()


func _test_template() -> void:
	var data := {"map_id": 991, "width": 20, "height": 16, "tile_size": 32}
	var map: Node2D = TEMPLATE.create_map(data, TileSet.new(), TileSet.new())
	var decor: Node2D = map.get_node("DecorLayer") as Node2D
	var marker: Node2D = map.get_node("PlayerSpawn") as Node2D
	_check(map.get_script() == CONTEXT, "转换模板根显式声明 MapContext")
	_check(map.get("map_id") == "rm2k3_0991", "转换地图具有稳定作者标识")
	_check(marker is Marker2D and marker.get_child_count() == 0, "出生点是独立标记而非活体容器")
	_check(decor.y_sort_enabled and decor.get_child_count() == 0, "内容图只声明空角色排序域")
	_check(marker.position == Vector2(320, 256), "生成出生标记保持作者位置")
	_check(map.get_actor_container() == decor, "模板容器契约有效")
	_check(map.get_camera_boundary_layers().size() == 2, "显式相机边界为地面与上层")
	_check(map.get_node("GroundLayer").get_index() < decor.get_index(), "地面早于排序域绘制")
	_check(map.get_node_or_null("CombatHUD") == null and map.get_node_or_null("Menu") == null, "内容模板不重复持有公共UI")
	_check(map.get_node_or_null("GameInit") == null and map.get_node_or_null("Camera2D") == null, "内容模板不预置会话装配和相机")
	var packed := PackedScene.new()
	_check(packed.pack(map) == OK, "新模板可打包")
	var restored: Node2D = packed.instantiate() as Node2D
	_check(restored.get_actor_container() == restored.get_node("DecorLayer"), "打包重载后显式容器路径保留")
	_check(restored.get_node("PlayerSpawn").owner == restored, "出生标记归属正确并可保存")
	_check(restored.get("camera_boundary_paths").size() == 2, "打包后相机边界配置保留")
	restored.free()
	map.free()


func _test_existing_maps() -> void:
	var paths: Array[String] = [
		"res://scene/maps/突袭-第一关-开头安全屋-户外.tscn",
		"res://scene/maps/突袭-第二关-学校内部.tscn",
		"res://scene/maps/突袭-第三关-矿洞.tscn",
	]
	for path: String in paths:
		var packed: PackedScene = load(path) as PackedScene
		_check(packed != null, "试点图可加载：" + path.get_file())
		if packed == null:
			continue
		var map: Node = packed.instantiate()
		_check(LOCATOR.find_actor_container(map) != null, "旧地图解析出本图排序域：" + path.get_file())
		_check(map.call("get_player_spawn_marker") != null, "迁移地图出生标记保留：" + path.get_file())
		_check(map.scene_file_path == path, "旧地图源场景身份不变：" + path.get_file())
		map.free()
