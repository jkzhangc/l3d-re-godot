extends Node
## 游戏启动器 — 场景加载时初始化玩家数据 + 创建 CharacterSwitchManager

func _ready() -> void:
	Global.try_load_or_init()
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
