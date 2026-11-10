extends Node

## 角色 / 状态资料界面布局检查（2026-11-10）。
## 用法：godot --headless --path . res://tools/profile_ui_check.tscn
##
## 守三件事：
##  1. 收藏馆页签 = 角色 / 状态 / 5 个物品分类，资料页条目齐全且恒为可见（不出现 ???）；
##  2. 角色详情把简介 / 可装备武器 / 特性 / 技能都排进详情区（不越过 body 高度）；
##  3. 角色选择信息窗里安雄的技能行有内容（不再显示「——」），且折行后不顶出窗口。

const COLLECTION := preload("res://script/ui/collection_menu.gd")
const PLAYER := preload("res://script/player.gd")
const SELECT_SCENE := "res://scene/character_select.tscn"

var _fail := 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
		return
	_fail += 1
	print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _check_true(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("  OK   %s%s" % [label, "" if detail.is_empty() else "（%s）" % detail])
		return
	_fail += 1
	print("  FAIL %s%s" % [label, "" if detail.is_empty() else "（%s）" % detail])


func _ready() -> void:
	await get_tree().process_frame
	await _check_collection()
	await _check_character_select()
	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)


# ═══════════════════════════════════════
# 1) 收藏馆：页签 / 条目 / 详情不越界
# ═══════════════════════════════════════

func _check_collection() -> void:
	print("=== 1) 收藏馆页签 ===")
	var menu: Control = COLLECTION.new()
	add_child(menu)
	await get_tree().process_frame
	await get_tree().process_frame

	var groups: Array = menu.get("_groups")
	var entries: Dictionary = menu.get("_entries")
	_check("页签数量", groups.size(), 7)
	_check("第 1 页", str(groups[0]), "角色")
	_check("第 2 页", str(groups[1]), "状态")
	_check("角色条目数", (entries["角色"] as Array).size(), 5)
	_check("状态条目数", (entries["状态"] as Array).size(), 8)
	_check("状态页恒可见（不看收集进度）", bool(menu.call("_is_unlocked", (entries["状态"] as Array)[0])), true)

	print("=== 2) 每个页签逐项刷新详情，检查高度 ===")
	var detail_root: Control = menu.get("_detail_root") as Control
	var body_h: float = detail_root.size.y
	for gi: int in range(groups.size()):
		var g: String = str(groups[gi])
		var list: Array = entries[g]
		menu.call("_select_tab", gi)
		var worst: float = 0.0
		var worst_idx: int = -1
		for i: int in range(list.size()):
			(menu.get("_sel") as Dictionary)[g] = i
			menu.call("_refresh_detail")
			await get_tree().process_frame
			var bottom: float = _detail_bottom(menu)
			## 接近满高就点名；真超界就逐行打出来，方便定位是哪条资料写长了。
			if bottom > body_h * 0.9:
				print("    - %s 第 %d 项（%s）bottom=%.0f" % [g, i + 1, str((list[i] as Dictionary).get("name", "?")), bottom])
			if bottom > body_h + 0.5:
				print(_detail_dump(menu))
			if bottom > worst:
				worst = bottom
				worst_idx = i
		print("  · %s：最深 %.0f / 可用 %.0f（第 %d 项）" % [g, worst, body_h, worst_idx + 1])
		_check_true("%s 详情不越界" % g, worst <= body_h + 0.5)

	print("=== 3) 详情文案抽查 ===")
	menu.call("_select_tab", 0)
	(menu.get("_sel") as Dictionary)["角色"] = 4
	menu.call("_refresh_detail")
	await get_tree().process_frame
	var anyu_text: String = _detail_text(menu)
	_check_true("安雄详情含「安雄魂」", anyu_text.contains("安雄魂"))
	_check_true("安雄详情含「可装备武器」", anyu_text.contains("可装备武器"))
	_check_true("安雄详情含「自爆无效」", anyu_text.contains("自爆无效"))
	_check_true("安雄详情含定位「爆破手」", anyu_text.contains("爆破手"))

	menu.call("_select_tab", 1)
	var statuses: Array = entries["状态"]
	var heat_idx: int = -1
	for i: int in range(statuses.size()):
		if str((statuses[i] as Dictionary).get("id", "")) == "heat":
			heat_idx = i
	_check_true("状态页含 heat", heat_idx >= 0)
	(menu.get("_sel") as Dictionary)["状态"] = maxi(0, heat_idx)
	menu.call("_refresh_detail")
	await get_tree().process_frame
	var heat_text: String = _detail_text(menu)
	_check_true("过热用中文名", heat_text.contains("过热"))
	_check_true("过热写明获得方式", heat_text.contains("获得："))
	_check_true("过热写明效果", heat_text.contains("禁止见切"))
	_check_true("过热写明不能换人", heat_text.contains("不能换人"))
	## HUD 短名也要点明这条，否则玩家只会看到「过热」却不知道为什么按不了切人。
	_check_true("状态栏短名点明禁换人", String(PLAYER.BUFF_LABELS.get("heat", "")).contains("换人"))

	menu.queue_free()
	await get_tree().process_frame


func _detail_bottom(menu: Control) -> float:
	var root: Control = menu.get("_detail_root") as Control
	var bottom: float = 0.0
	for child: Node in root.get_children():
		if child is Control:
			var c: Control = child
			bottom = maxf(bottom, c.position.y + c.size.y)
	return bottom


func _detail_dump(menu: Control) -> String:
	var root: Control = menu.get("_detail_root") as Control
	var rows: Array[String] = []
	for child: Node in root.get_children():
		if child is Control:
			var c: Control = child
			var txt: String = (c as Label).text if c is Label else "<%s>" % c.get_class()
			rows.append("      y=%.0f h=%.0f bottom=%.0f  %s" % [c.position.y, c.size.y, c.position.y + c.size.y, txt])
	return "\n".join(rows)


func _detail_text(menu: Control) -> String:
	var root: Control = menu.get("_detail_root") as Control
	var parts: Array[String] = []
	for child: Node in root.get_children():
		if child is Label:
			parts.append((child as Label).text)
	return "".join(parts)


# ═══════════════════════════════════════
# 4) 角色选择信息窗：安雄的技能行
# ═══════════════════════════════════════

func _check_character_select() -> void:
	print("=== 4) 角色选择信息窗（安雄） ===")
	var packed: PackedScene = load(SELECT_SCENE) as PackedScene
	if packed == null:
		_check_true("载入角色选择场景", false)
		return
	var root: Control = packed.instantiate() as Control
	add_child(root)
	for i: int in range(8):
		await get_tree().process_frame

	var chars: Array = root.get("_available_characters")
	var idx: int = -1
	for i: int in range(chars.size()):
		if String((chars[i] as CharacterData).character_id) == "yasuo":
			idx = i
	_check_true("找到安雄", idx >= 0)
	if idx < 0:
		root.queue_free()
		return

	var window_h: float = (root.get_node("InfoWindow") as Control).size.y
	var labels: Array = root.get("_info_labels")
	var skill: GradientLabel = labels[4]
	var awaken: GradientLabel = labels[5]

	## 全部角色都过一遍：技能行折行后觉醒行会下移，任何一个人都不能顶出信息窗。
	for i: int in range(chars.size()):
		var cd: CharacterData = chars[i]
		root.set("_cursor_idx", i)
		root.call("_refresh_all")
		await get_tree().process_frame
		var bottom: float = awaken.position.y + awaken.size.y
		print("  · %s：技能 %.0fpx / 觉醒底部 %.0f / 窗口 %.0f" % [
			cd.character_name, skill.size.y, bottom, window_h])
		_check_true("%s 信息窗不越界" % cd.character_name, bottom <= window_h)

	root.set("_cursor_idx", idx)
	root.call("_refresh_all")
	await get_tree().process_frame
	print("  · 安雄技能行：%s" % skill.text)
	print("  · 安雄觉醒行：%s" % awaken.text)
	_check_true("技能行含安雄魂", skill.text.contains("安雄魂"))
	_check_true("技能行不再只有占位符", not skill.text.contains("——"))
	_check_true("技能行只有一行", skill.size.y <= 40.0, "%.0fpx" % skill.size.y)
	_check_true("觉醒行说明安雄没有觉醒", awaken.text.contains("无"))

	root.queue_free()
	await get_tree().process_frame
