extends Node

## 诊断探针：把收藏馆的「角色 / 状态」两页渲染成 PNG，肉眼核对版式。
## 版式的**数值**回归由 tools/profile_ui_check.tscn 守（headless 可跑），本探针只管「好不好看」。
## ★必须**窗口渲染**运行（headless 拿不到 viewport 纹理）：
##   "$GD" --path <项目> res://tools/collection_shot_probe.tscn
## 产物在 user://collection_probe/，路径由脚本打印。

const MENU := preload("res://script/ui/collection_menu.gd")
const OUT_DIR := "user://collection_probe"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var menu: Control = MENU.new()
	add_child(menu)
	for i in range(6):
		await get_tree().process_frame

	for case: Dictionary in [{"tab": 0, "name": "character"}, {"tab": 1, "name": "status"}]:
		menu.call("_select_tab", int(case["tab"]))
		for i in range(4):
			await get_tree().process_frame
		_save("%s.png" % str(case["name"]))

	## 状态页 · 过热（要看清「不能换人」这一条）
	menu.call("_select_tab", 1)
	var statuses: Array = (menu.get("_entries") as Dictionary)["状态"]
	for i in range(statuses.size()):
		if String((statuses[i] as Dictionary).get("id", "")) == "heat":
			(menu.get("_sel") as Dictionary)["状态"] = i
	menu.call("_refresh_detail")
	for i in range(4):
		await get_tree().process_frame
	_save("status_heat.png")
	## 角色页最后一格 = 安雄
	menu.call("_select_tab", 0)
	(menu.get("_sel") as Dictionary)["角色"] = 4
	menu.call("_refresh_detail")
	for i in range(4):
		await get_tree().process_frame
	_save("character_yasuo.png")

	## 武器页留一张对照（确认物品详情没被改动影响）
	menu.call("_select_tab", 2)
	for i in range(4):
		await get_tree().process_frame
	_save("weapon.png")

	menu.queue_free()
	await get_tree().process_frame

	## 角色选择信息窗：安雄（技能 / 觉醒两行的实际观感）
	var packed: PackedScene = load("res://scene/character_select.tscn") as PackedScene
	if packed != null:
		var cs: Control = packed.instantiate() as Control
		add_child(cs)
		for i in range(10):
			await get_tree().process_frame
		var chars: Array = cs.get("_available_characters")
		for i in range(chars.size()):
			if String((chars[i] as CharacterData).character_id) == "yasuo":
				cs.set("_cursor_idx", i)
		cs.call("_refresh_all")
		for i in range(4):
			await get_tree().process_frame
		_save("character_select_yasuo.png")

	print("=== 截图目录：%s ===" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit(0)


func _save(file_name: String) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	img.save_png(OUT_DIR.path_join(file_name))
