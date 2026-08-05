extends Node
## 游戏启动器 — 场景加载时初始化玩家数据 + 创建 CharacterSwitchManager

func _ready() -> void:
	Global.try_load_or_init()
	print("[GameInit] 初始化完成 | debug=%s | HP=%.0f | team=%d | checkpoint=%s" % [
		Global.debug_enabled, Global.player_hp, Global.get_team_size(),
		"有" if not Global.checkpoint.is_empty() else "无"
	])
	_spawn_switch_manager()
	_spawn_network_support()


func _spawn_network_support() -> void:
	## 联机模式：创建网络同步节点
	if not NetworkManager.is_online():
		return
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return

	# NetworkSpawner — 玩家生成和位置同步
	_spawn_syncer(tree, "NetworkSpawner", "res://script/network_spawner.gd")
	# NetworkEnemySyncer — 敌人状态同步
	_spawn_syncer(tree, "NetworkEnemySyncer", "res://script/network_enemy_syncer.gd")
	# NetworkPickupSyncer — 武器掉落物同步
	_spawn_syncer(tree, "NetworkPickupSyncer", "res://script/network_pickup_syncer.gd")


func _spawn_syncer(tree: SceneTree, name_str: String, script_path: String) -> void:
	if tree.current_scene.find_child(name_str, true, false):
		return
	if not ResourceLoader.exists(script_path):
		return
	var scr: Script = load(script_path) as Script
	var node := Node.new()
	node.set_script(scr)
	node.name = name_str
	tree.current_scene.call_deferred("add_child", node)


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
