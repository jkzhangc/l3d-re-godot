class_name MapLocator extends RefCounted

## 业务地图身份唯一查询：常驻会话取active_map，F6/旧宿主回退引擎current_scene。
## 不缓存跨图节点，存档、机关和RPC路径仍以源地图为根。
## @trace SCENE-001, SCENE-002
const CONTEXT_SCRIPT = preload("res://script/map/map_context.gd")


static func get_map_root(tree: SceneTree) -> Node:
	if tree == null:
		return null
	var session: Node = tree.root.get_node_or_null("GameSession")
	if session != null:
		var map: Variant = session.get("active_map")
		if is_instance_valid(map):
			return map as Node
		if tree.current_scene == session:
			return null
	return tree.current_scene


static func get_map_scene_path(tree: SceneTree) -> String:
	var scene: Node = get_map_root(tree)
	return scene.scene_file_path if is_instance_valid(scene) else ""


static func find_actor_container(scene: Variant) -> Node2D:
	if not is_instance_valid(scene):
		return null
	if is_instance_of(scene, CONTEXT_SCRIPT):
		var explicit: Node2D = scene.get_actor_container()
		if is_instance_valid(explicit):
			return explicit
	return find_legacy_actor_container(scene)


static func find_legacy_actor_container(node: Variant) -> Node2D:
	if not is_instance_valid(node):
		return null
	if node is Node2D and "decor" in node.name.to_lower():
		return node as Node2D
	for child: Node in node.get_children():
		var found: Node2D = find_legacy_actor_container(child)
		if found != null:
			return found
	return null


static func find_preplaced_player(scene: Variant, allow_unready: bool = true) -> CharacterBody2D:
	if not is_instance_valid(scene):
		return null
	var tree: SceneTree = scene.get_tree() if scene.is_inside_tree() else null
	if tree != null:
		for node: Node in tree.get_nodes_in_group("player"):
			if node is CharacterBody2D and scene.is_ancestor_of(node):
				return node as CharacterBody2D
	if allow_unready:
		var preplaced: Node = scene.find_child("Player", true, false)
		if preplaced is CharacterBody2D:
			return preplaced as CharacterBody2D
	return null
