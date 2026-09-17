extends Node2D
## 镜头跟随回归 —— headless 验证。
##
## 【为什么存在】GameInit._align_actor_layers() 会把玩家 reparent 进敌人的 y 排序容器；
## remove_child 发出的 tree_exiting 会让 PhantomCamera2D 关掉 _should_follow，
## 且重新入树不会恢复 —— 症状就是"镜头永远钉在原地不跟随"（2026-09-10 实际发生过）。
## 本测试把「reparent 后镜头仍能跟随玩家」钉成回归项。
##
## 用法："$GD" --headless --path <项目> res://tools/camera_follow_test.tscn

const MAP := preload("res://scene/maps/突袭-第一关-街道.tscn")

var _checks: int = 0
var _fails: int = 0


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("[PASS] %s" % label)
	else:
		_fails += 1
		print("[FAIL] %s" % label)


func _ready() -> void:
	add_child(MAP.instantiate())
	for i in range(60):
		await get_tree().physics_frame

	var ps: Array[Node] = get_tree().get_nodes_in_group("player")
	_check(not ps.is_empty(), "场景里有玩家")
	var player: Node2D = ps[0]
	_check(player.get_parent() != null and "decor" in str(player.get_parent().name).to_lower(),
		"层级对齐生效：玩家父节点 = %s" % str(player.get_parent().get_path()))
	_check(Players.all_entities().size() >= 1, "reparent 后玩家仍在 Players 注册表（重注册生效）")

	var cam: Camera2D = get_viewport().get_camera_2d()
	_check(cam != null, "存在活动相机")
	var pcam: Node = cam.get_node_or_null("PhantomCamera2D") if cam else null
	_check(pcam != null and is_instance_valid(pcam.get("follow_target")),
		"pcam.follow_target 有效")

	# 玩家瞬移 800px → 相机必须在 1.5s 内跟到位（阻尼 follow_speed=6）
	var before: Vector2 = cam.global_position if cam else Vector2.ZERO
	player.global_position += Vector2(800, 0)
	for i in range(90):
		await get_tree().physics_frame
	var moved: float = (cam.global_position - before).length() if cam else 0.0
	_check(moved > 500.0, "瞬移 800px 后相机跟随移动了 %.0f px（>500）" % moved)
	_check((cam.global_position - player.global_position).length() < 8.0,
		"阻尼收敛：相机与玩家最终距离 %.2f px（<8）" % float((cam.global_position - player.global_position).length()))

	print("=== CAMERA_FOLLOW_TEST: %d/%d checks passed ===" % [_checks - _fails, _checks])
	get_tree().quit(0 if _fails == 0 else 1)
