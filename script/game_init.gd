extends Node
## 游戏启动器

func _ready() -> void:
	Global.try_load_or_init()
	print("[GameInit] 初始化完成 | debug=%s | 物品数=%d" % [
		Global.debug_enabled, Global.inventory.size()
	])
	_auto_save_on_scene_start()


func _auto_save_on_scene_start() -> void:
	var player: Node = _find_player()
	if player and player.has_method("take_damage"):
		Global.player_hp = player.current_hp
	SaveManager.save_game()
	print("[GameInit] 场景自动存档完成")


func _find_player() -> Node:
	var tree: SceneTree = get_tree()
	if not tree:
		return null
	var root: Window = tree.root
	if not root:
		return null
	return _find_player_recursive(root)


func _find_player_recursive(node: Node) -> Node:
	if node is CharacterBody2D and node.has_method("get_weapon_data"):
		return node
	for child: Node in node.get_children():
		var found: Node = _find_player_recursive(child)
		if found:
			return found
	return null
