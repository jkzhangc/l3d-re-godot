extends Node
## 临时诊断：窗口渲染核对尸体层级（headless 无法渲染，渐变/TileMap 都取不到图像）。
## 用法："$GD" --path <项目> res://tools/corpse_layer_probe.tscn
##
## 产出两张 4 倍放大的裁剪图（统一以玩家屏幕位置为中心）：
##   a_player_only.png  只有玩家（基线）
##   b_with_corpse.png  在该位置放一具尸体（略偏南，旧逻辑下 y_sort 会把它画在玩家之上）
## 判定：b 图里玩家应仍完整可见并压在尸体之上；尸体自身也应可见（没被地面图块盖住）。

const MAP := preload("res://scene/maps/突袭-第一关-街道.tscn")
const ENEMY_SCENE := preload("res://object/enemy.tscn")
const OUT_DIR := "user://ui_probe"
const CROP := Vector2i(140, 160)


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var scene: Node = MAP.instantiate()
	add_child(scene)
	for i in range(90):
		await get_tree().process_frame

	var player: Node2D = scene.find_child("Player", true, false) as Node2D
	var decor: Node2D = scene.find_child("DecorLayer", true, false) as Node2D
	if player == null or decor == null:
		printerr("[尸体层级探针] 找不到玩家或 DecorLayer")
		get_tree().quit(1)
		return

	# 冻住玩家，保证两张图取景一致
	var psm: Node = player.get_node_or_null("StateMachine")
	if psm:
		psm.set_process(false)
		psm.set_physics_process(false)
	for i in range(10):
		await get_tree().process_frame

	var center: Vector2i = Vector2i(player.get_global_transform_with_canvas().origin)
	_save_crop("a_player_only.png", center)

	var e: Node2D = ENEMY_SCENE.instantiate() as Node2D
	decor.add_child(e)
	e.global_position = player.global_position + Vector2(0, 10)
	for i in range(10):
		await get_tree().process_frame
	e._die(false)
	for i in range(40):
		await get_tree().process_frame

	var par := e.get_parent()
	print("[尸体层级探针] 尸体父节点=%s z_index=%d 位置=%s | 玩家=%s" % [
		str(par.name) if par else "无", e.z_index, str(e.global_position), str(player.global_position)])
	_save_crop("b_with_corpse.png", center)
	print("[尸体层级探针] 图片目录 %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit(0)


func _save_crop(file_name: String, center: Vector2i) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		printerr("[尸体层级探针] 取不到视口纹理")
		return
	var img := tex.get_image()
	if img == null:
		return
	var rect := Rect2i(center - CROP / 2, CROP)
	rect.position.x = clampi(rect.position.x, 0, maxi(0, img.get_width() - rect.size.x))
	rect.position.y = clampi(rect.position.y, 0, maxi(0, img.get_height() - rect.size.y))
	var crop := img.get_region(rect)
	crop.resize(crop.get_width() * 4, crop.get_height() * 4, Image.INTERPOLATE_NEAREST)
	crop.save_png(OUT_DIR.path_join(file_name))
