extends Node

## 竞速记录 / 游玩统计 / 游戏模式 / 血腥和谐 的回归检查（2026-11-10）。
## 用法：godot --headless --path . res://tools/records_check.tscn
##
## 守五件事：
##  1. `Global.format_run_time` 的两种口径（<1h 与 >=1h）；
##  2. 一局结束会记账：竞速模式写一条记录、两种模式都累计总统计；重复调用不重复记；
##  3. 竞速记录 / 游玩统计两页都能建出来（有数据 / 空数据两种情况）；
##  4. 游戏模式菜单能建出来，两个选项都在；
##  5. 血效识别 + 血液颜色设置能挂上重上色材质。
##
## ⚠ 本检查会调用 `Global.finish_run()`，它会 `save_config()`。所以先备份
##    `speedrun_records` / `play_stats` 两个字段，跑完原样写回 —— 不动玩家真实记录。

const RECORDS_MENU := preload("res://script/ui/records_menu.gd")
const MODE_MENU := preload("res://script/ui/game_mode_menu.gd")
const HIT_ANIM := preload("res://anim/anim_effect_hit.tscn")

var _fail := 0


func _check(label: String, got, want) -> void:
	if typeof(got) == typeof(want) and is_same(got, want):
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

	print("=== 1) 时长格式 ===")
	_check("65.4 秒", Global.format_run_time(65.4), "01:05.4")
	_check("600 秒", Global.format_run_time(600.0), "10:00.0")
	_check("3723 秒（跨小时）", Global.format_run_time(3723.0), "1:02:03")
	_check("0 秒", Global.format_run_time(0.0), "00:00.0")
	_check("总时长 3h12m", Global.format_total_playtime(11520), "3 小时 12 分")
	_check("总时长 12m", Global.format_total_playtime(720), "12 分")

	print("=== 2) 一局结束记账 ===")
	var backup_records: Array = Global.speedrun_records.duplicate(true)
	var backup_stats: Dictionary = Global.play_stats.duplicate(true)
	Global.speedrun_records.clear()
	Global.play_stats = {}
	Global.run_mode = Global.RUN_MODE_SPEEDRUN
	Global.begin_run()
	Global.finish_run(true)
	_check("竞速记录 +1", Global.speedrun_records.size(), 1)
	var rec: Dictionary = Global.speedrun_records[0]
	_check("记录：已通关", bool(rec.get("cleared", false)), true)
	_check("记录：带用时字段", rec.has("seconds"), true)
	_check("总统计：局数 1", int(Global.play_stats.get("runs", 0)), 1)
	_check("总统计：通关 1", int(Global.play_stats.get("clears", 0)), 1)
	Global.finish_run(true)
	_check("重复结算不再记（幂等）", Global.speedrun_records.size(), 1)

	Global.begin_run()
	Global.finish_run(false)
	_check("未通关也记一条", Global.speedrun_records.size(), 2)
	_check("未通关记录 cleared=false", bool((Global.speedrun_records[0] as Dictionary).get("cleared", true)), false)
	_check("总统计：局数 2 / 通关仍 1", "%d/%d" % [
		int(Global.play_stats.get("runs", 0)), int(Global.play_stats.get("clears", 0))], "2/1")

	Global.run_mode = Global.RUN_MODE_STANDARD
	Global.begin_run()
	Global.finish_run(true)
	_check("标准模式不写竞速记录", Global.speedrun_records.size(), 2)
	_check("标准模式也累计总统计（局数 3）", int(Global.play_stats.get("runs", 0)), 3)

	print("=== 3) 报表页 ===")
	var page0: Control = RECORDS_MENU.new()
	page0.set("page", 0)
	add_child(page0)
	for i in range(3):
		await get_tree().process_frame
	_check_true("竞速记录页建出来了", page0.get_child_count() > 0)
	var labels0: int = _count_labels(page0)
	_check_true("竞速记录页有文字", labels0 >= 5, "%d 行" % labels0)
	page0.queue_free()
	await get_tree().process_frame

	var saved: Array = Global.speedrun_records.duplicate(true)
	var saved_stats: Dictionary = Global.play_stats.duplicate(true)
	Global.speedrun_records.clear()
	Global.play_stats = {}
	var page0_empty: Control = RECORDS_MENU.new()
	page0_empty.set("page", 0)
	add_child(page0_empty)
	await get_tree().process_frame
	_check_true("空记录页也能开", _count_labels(page0_empty) >= 2)
	page0_empty.queue_free()
	Global.speedrun_records = saved
	Global.play_stats = saved_stats
	await get_tree().process_frame

	var page1: Control = RECORDS_MENU.new()
	page1.set("page", 1)
	add_child(page1)
	for i in range(3):
		await get_tree().process_frame
	var labels1: int = _count_labels(page1)
	_check_true("游玩统计页有文字", labels1 >= 10, "%d 行" % labels1)
	page1.queue_free()
	await get_tree().process_frame

	print("=== 4) 游戏模式菜单 ===")
	var mode_menu: Control = MODE_MENU.new()
	add_child(mode_menu)
	for i in range(3):
		await get_tree().process_frame
	var item_labels: Array = mode_menu.get("_item_labels")
	_check("两个模式选项", item_labels.size(), 2)
	_check("第一项 = 标准模式", str((item_labels[0] as Label).text), "标准模式")
	_check("第二项 = 计时竞速", str((item_labels[1] as Label).text), "计时竞速")
	_check_true("模式说明非空", str(Global.RUN_MODE_DESCS[0]).length() > 10)
	mode_menu.queue_free()
	await get_tree().process_frame

	print("=== 5) 血腥和谐 ===")
	var hit: Node = HIT_ANIM.instantiate()
	var tex: Texture2D = hit.get("texture") as Texture2D
	_check_true("命中特效被识别为血效", VXAnimSprite.is_blood_texture(tex), str(tex.resource_path.get_file()))
	_check_true("枪口特效不算血效",
		not VXAnimSprite.is_blood_texture(load("res://art/Animations/ハンドガン発射.png") as Texture2D))
	var old_color: int = Global.blood_color_option
	var old_enabled: bool = Global.blood_enabled
	Global.blood_color_option = 1
	add_child(hit)
	await get_tree().process_frame
	_check_true("绿血：挂上重上色材质", hit.material is ShaderMaterial)
	hit.queue_free()
	await get_tree().process_frame

	Global.blood_color_option = 0
	var hit2: Node = HIT_ANIM.instantiate()
	add_child(hit2)
	await get_tree().process_frame
	_check_true("默认红：不挂材质", hit2.material == null)
	hit2.queue_free()
	Global.blood_enabled = false
	var hit3: Node = HIT_ANIM.instantiate()
	add_child(hit3)
	await get_tree().process_frame
	_check_true("血液特效关闭：节点隐藏", not (hit3 as CanvasItem).visible)
	hit3.queue_free()
	Global.blood_enabled = old_enabled
	Global.blood_color_option = old_color

	## 还原玩家真实记录（本检查期间写进 config 的测试数据）
	Global.speedrun_records = backup_records
	Global.play_stats = backup_stats
	Global.save_config()

	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)


func _count_labels(root: Node) -> int:
	var n: int = 0
	if root is Label:
		n += 1
	for child: Node in root.get_children():
		n += _count_labels(child)
	return n
