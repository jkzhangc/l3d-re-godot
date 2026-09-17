extends Node

## ── 架构定位 ──
## 系统：启动装配 ｜ 层：单例（关卡场景根节点脚本）
## 联机：联机会话改走 NetworkWorld 分支
## 职责：关卡载入时的总装配器：加载/初始化存档、应用待生效到达点、必要时创建 NetworkWorld，并挂载角色切换管理器。
## 依赖：Global、Net、Players、CharacterSwitchManager

## 游戏启动器 — 场景加载时初始化玩家数据 + 创建 CharacterSwitchManager

func _ready() -> void:
	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("is_online_session") and net.is_online_session():
		_start_network_world()
		return

	Global.try_load_or_init()
	_apply_pending_arrival()
	# 安全屋场景加载时自动存档（确保死亡后回到这里时的状态一致）
	if get_tree() and get_tree().current_scene:
		var scene_path: String = get_tree().current_scene.scene_file_path
		if "安全屋" in scene_path or "safe" in scene_path.to_lower():
			Global.capture_checkpoint()
			print("[GameInit] 安全屋自动存档: %s" % scene_path)
		else:
			var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
			if chapter_stats and chapter_stats.has_method("ensure_chapter"):
				chapter_stats.ensure_chapter(scene_path)
	var state: PlayerState = Players.get_active_state()
	print("[GameInit] 初始化完成 | debug=%s | HP=%.0f | team=%d | checkpoint=%s" % [
		Global.debug_enabled, state.current_hp, Global.get_team_size(),
		"有" if not Global.checkpoint.is_empty() else "无"
	])
	_spawn_switch_manager()
	# 预构建 A* 寻路网格（延迟到本帧节点就绪后），
	# 避免首个敌人追击时才同步创建 AStarGrid2D 造成卡顿
	call_deferred("_prebuild_astar")
	# 玩家与敌人必须在同一个 y 排序容器里，两者之间的遮挡才正确（见 _align_actor_layers）
	call_deferred("_align_actor_layers")


func _apply_pending_arrival() -> void:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var arrival := Global.consume_pending_arrival(tree.current_scene.scene_file_path)
	if arrival.is_empty():
		return
	var arrival_id: String = str(arrival.get("id", ""))
	var arrival_position: Variant = ArrivalResolver.resolve(
		tree.current_scene, arrival_id, arrival.get("position")
	)
	if not arrival_position is Vector2:
		return
	var player := _find_preplaced_player(tree.current_scene)
	if not player:
		push_warning("[GameInit] 找不到预置 Player，无法应用入口 ID: %s" % arrival_id)
		return
	player.global_position = arrival_position as Vector2
	print("[GameInit] 已应用入口 ID=%s position=%s" % [arrival_id, player.global_position])


func _find_preplaced_player(scene: Node) -> CharacterBody2D:
	for node: Node in scene.get_tree().get_nodes_in_group("player"):
		if node is CharacterBody2D:
			return node as CharacterBody2D
	return null


func _start_network_world() -> void:
	## 当前场景仍在执行 _ready()，直接 add_child 会被 Godot 拒绝；延后到下一帧创建。
	call_deferred("_create_network_world")


func _create_network_world() -> void:
	## Phase 1 联机只启用 Host 权威移动世界；跳过单机存档、队友切换和 Director 初始化。
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	if tree.current_scene.get_node_or_null("NetworkWorld"):
		return
	# 【回归专用】--net-test-host-scene-delay-ms=N：延迟创建 NetworkWorld，模拟
	# "Host 加载缓慢、Client 的 scene-ready 报告先于 Host 世界就绪到达"的竞态，
	# 配合 --net-test=slow-host-ready 使用；正式游戏绝不会带此参数。
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test-host-scene-delay-ms="):
			var delay_sec := float(argument.trim_prefix("--net-test-host-scene-delay-ms=").to_int()) / 1000.0
			if delay_sec > 0.0:
				print("[GameInit] AUTO_SLOWHOST 模拟 Host 场景延迟 %.2fs" % delay_sec)
				await tree.create_timer(delay_sec).timeout
			break
	if not is_inside_tree() or not tree.current_scene:
		return
	var world := preload("res://script/network_world.gd").new()
	world.name = "NetworkWorld"
	tree.current_scene.add_child(world)
	print("[GameInit] 已进入 Phase 1 Host 权威联机世界")

func _spawn_switch_manager() -> void:
	## 如果队伍 > 1人且场景中不存在，自动创建 CharacterSwitchManager
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var existing: Node = tree.current_scene.find_child("CharacterSwitchManager", true, false)
	if existing:
		return
	var script_path := "res://script/character_switch_manager.gd"
	if not ResourceLoader.exists(script_path):
		return
	var mgr_script: Script = load(script_path) as Script
	var mgr := Node.new()
	mgr.set_script(mgr_script)
	mgr.name = "CharacterSwitchManager"
	# 延迟添加，避免在场景初始化期间 add_child
	tree.current_scene.call_deferred("add_child", mgr)
	var log_cb: Callable = func(): print("[GameInit] CharacterSwitchManager 已创建 team=%d" % Global.get_team_size())
	log_cb.call_deferred()


func _prebuild_astar() -> void:
	## 场景树就绪后启动 A* 网格构建（一次性同步 update() 前移到加载阶段）
	EnemyChaseState.prebuild()


func _physics_process(_delta: float) -> void:
	## 每物理帧驱动 A* 网格分帧构建，敌人未追击时也能推进；闲置时开销可忽略
	EnemyChaseState.tick_build()


## ── 玩家与敌人的绘制层级对齐 ──
## 敌人由 Director 生成，父节点固定是名字含 "decor" 的 DecorLayer（两张图的 DecorLayer 都开了
## y_sort_enabled）。玩家却是场景里预摆的，且两张图的挂法不一致：
##   街道 = DecorLayer/PlayerSpawn/Player；学校内部 = PlayerSpawn/Player（挂在关卡根下）。
## 后者与敌人不在同一个 y 排序容器 → 整个玩家子树按根节点顺序画在敌人之后，
## 表现为「玩家永远盖住敌人 / 敌人永远钻到玩家底下」。这里在关卡就绪后把玩家
## reparent 到 DecorLayer，与敌人成为兄弟节点，参与同一轮 y 排序。
func _align_actor_layers() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var players: Array[Node] = tree.get_nodes_in_group("player")
	if players.is_empty():
		return
	var player := players[0] as Node2D
	if player == null or not is_instance_valid(player):
		return
	var decor := _find_decor_container(tree.root)
	if decor == null or player.get_parent() == decor:
		return
	var old_parent := player.get_parent()
	var gp: Vector2 = player.global_position
	player.get_parent().remove_child(player)
	decor.add_child(player)
	player.global_position = gp

	## ⚠ reparent（remove_child/add_child）的两个副作用，都必须手动补救：
	## ① 触发 player._exit_tree() → 从 Players 注册表注销，而 _ready 不会重跑 ——
	##    必须重新注册，否则 Director 的生成/回收、角色切换等全部失联
	##    （注册表虽有 group 兜底自愈，但显式重注册不依赖兜底时序）；
	## ② 发出 tree_exiting → PhantomCamera2D 把 _should_follow 关掉（见
	##    camera_follow.rebind_follow_target 的注释），镜头从此钉死在原地。
	if not player.get("network_controlled"):
		Players.register_entity(player)
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam and cam.has_method("rebind_follow_target"):
		cam.rebind_follow_target(player)

	print("[GameInit] 玩家已移入与敌人相同的 y 排序容器 %s（原父节点 %s，镜头与注册已重绑）" % [
		str(decor.get_path()), str(old_parent.get_path())])


func _find_decor_container(node: Node) -> Node:
	if node is Node2D and "decor" in node.name.to_lower():
		return node
	for child: Node in node.get_children():
		var found: Node = _find_decor_container(child)
		if found:
			return found
	return null
