extends Node

## 竞速记录 / 游玩统计 / 限时挑战 / 游戏模式 / 血腥和谐 的回归检查（2026-11-10）。
## 用法：godot --headless --path . res://tools/records_check.tscn
##
## 守五件事：
##  1. `Global.format_run_time` 的两种口径（<1h 与 >=1h）；
##  2. 一局结束会记账：竞速模式写一条记录、两种模式都累计总统计；重复调用不重复记；
##  3. 竞速记录 / 游玩统计两页都能建出来（有数据 / 空数据两种情况）；
##  4. 游戏模式菜单能建出来，三个选项都在；
##  5. 血效识别 + 血液颜色设置能挂上重上色材质；
##  6. 限时挑战：关卡时限查表、击杀加时（含连杀台阶）、重进同一关不刷新、
##     安全屋停表、时间到判负、记账字段、记录页能建出来。
##
## ⚠ 本检查会调用 `Global.finish_run()`，它会 `save_config()`。所以先备份
##    `speedrun_records` / `timed_records` / `play_stats`，跑完原样写回 —— 不动玩家真实记录。

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


## 浮点断言：加时 0.1 这类值不能按位比较（240.1 与 240.0+0.1 末位可能不同）。
func _check_near(label: String, got: float, want: float, eps: float = 0.0001) -> void:
	if absf(got - want) <= eps:
		print("  OK   %s = %.4f" % [label, got])
		return
	_fail += 1
	print("  FAIL %s = %.4f（期望 %.4f）" % [label, got, want])


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
	var backup_timed: Array = Global.timed_records.duplicate(true)
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
	_check("三个模式选项", item_labels.size(), 3)
	_check("第一项 = 标准模式", str((item_labels[0] as Label).text), "标准模式")
	_check("第二项 = 计时竞速", str((item_labels[1] as Label).text), "计时竞速")
	_check("第三项 = 限时挑战", str((item_labels[2] as Label).text), "限时挑战")
	_check_true("模式说明非空", str(Global.RUN_MODE_DESCS[0]).length() > 10)
	## 三行选项 + 4 行说明不能压到底部提示：面板高度是硬编码的，加项时必须复核。
	_check_true("模式面板放得下三行", float(mode_menu.get("PANEL_SIZE").y) >= 520.0)
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

	print("=== 6) 限时挑战 ===")
	var timed: Node = get_node_or_null("/root/TimedChallenge")
	_check_true("TimedChallenge 自动加载存在", timed != null)
	if timed != null:
		timed.set("fail_ui_enabled", false)   ## 别让「挑战失败」界面把测试进程暂停住
		Global.run_mode = Global.RUN_MODE_TIMED
		_check_true("限时挑战 = 无存档模式", Global.is_no_save_mode())
		Global.run_mode = Global.RUN_MODE_SPEEDRUN
		_check_true("竞速也是无存档模式", Global.is_no_save_mode())
		Global.run_mode = Global.RUN_MODE_STANDARD
		_check_true("标准模式可以存档", not Global.is_no_save_mode())
		Global.run_mode = Global.RUN_MODE_TIMED

		_check("街道时限", TimedChallenge.limit_for("res://scene/maps/突袭-第一关-街道.tscn"), 240.0)
		_check("学校内部时限", TimedChallenge.limit_for("res://scene/maps/突袭-第二关-学校内部.tscn"), 300.0)
		_check("公园入口优先于公园", TimedChallenge.limit_for("res://scene/maps/夜行猎手-第二关-公园入口.tscn"), 120.0)
		_check("未知关卡兜底", TimedChallenge.limit_for("res://scene/maps/测试-敌人试验场.tscn"), 180.0)
		_check_true("安全屋可识别",
			TimedChallenge.is_safe_house_scene("res://scene/maps/突袭-第一关-开头安全屋-户外.tscn"))
		_check_true("街道不是安全屋",
			not TimedChallenge.is_safe_house_scene("res://scene/maps/突袭-第一关-街道.tscn"))

		const STREET := "res://scene/maps/突袭-第一关-街道.tscn"
		const SCHOOL := "res://scene/maps/突袭-第二关-学校内部.tscn"
		Global.begin_run()   ## 会把 TimedChallenge 一并 reset
		## ★走真实入口：`ChapterStats.begin_chapter` 是换图的唯一钩子 ——
		##   直接调 TimedChallenge 会漏检「钩子忘了接」这种最要命的接线错误。
		ChapterStats.begin_chapter(STREET)
		_check_near("开局余额 = 本关时限", float(timed.get("remaining")), 240.0)
		_check("开局在走表", bool(timed.get("running")), true)
		_check("到达关卡数 1", int(timed.get("levels_entered")), 1)

		## 同样走真实入口：`record_kill` 是所有击杀（子弹 / 近战）的唯一漏斗。
		ChapterStats.record_kill(0, false)
		_check_near("单杀 +0.1s（经 record_kill 钩子）", float(timed.get("remaining")), 240.1)
		for i: int in range(9):
			timed.call("on_enemy_killed")
		## 第 10 杀：9 次基础加时（0.9）+ 10 连杀台阶（+0.5）
		_check_near("10 连杀共 +1.5s", float(timed.get("remaining")), 241.5)
		_check("连杀计数 10", int(timed.get("combo")), 10)
		_check("最长连杀 10", int(timed.get("best_combo")), 10)

		timed.call("advance_time", 3.5)   ## 超过 3 秒连杀窗口
		_check("连杀窗口过期归零", int(timed.get("combo")), 0)
		_check_near("扣时生效", float(timed.get("remaining")), 238.0)

		var before: float = float(timed.get("remaining"))
		timed.call("on_level_entered", STREET)
		_check_near("重进同一关不刷新余额", float(timed.get("remaining")), before)
		_check("重进不重复计关卡", int(timed.get("levels_entered")), 1)

		timed.call("enter_safehouse")
		_check("安全屋停表", bool(timed.get("running")), false)

		## ★死亡复活回归（2026-11-10 用户实测「复活后倒计时不见了」）：
		## 死回安全屋再回到**同一张图**时，`ChapterStats.ensure_chapter()` 会 early-return
		## （chapter_scene 没变 → 不调 begin_chapter）→ TimedChallenge 收不到通知、
		## running 一直 false。修法是 GameInit 每次进图显式再通知一次。
		var left_over: float = float(timed.get("remaining"))
		ChapterStats.ensure_chapter(STREET)
		_check_true("ensure_chapter 对同一关不重开章节",
			String(ChapterStats.chapter_scene) == STREET)
		timed.call("on_level_entered", STREET)
		_check("回到同一关：倒计时恢复", bool(timed.get("running")), true)
		_check_near("恢复后的余额 = 离开时的余额", float(timed.get("remaining")), left_over)
		_check("回到同一关不重复计进度", int(timed.get("levels_entered")), 1)

		## 同一关被通知两次（begin_chapter + GameInit）不能重置连杀
		timed.call("on_enemy_killed")
		var combo_before_dup: int = int(timed.get("combo"))
		timed.call("on_level_entered", STREET)
		_check("重复通知不重置连杀", int(timed.get("combo")), combo_before_dup)

		## 源码级：GameInit 必须保留这条显式通知（删了就会静默复发）
		var gi_src: String = ""
		if FileAccess.file_exists("res://script/game_init.gd"):
			var gf := FileAccess.open("res://script/game_init.gd", FileAccess.READ)
			if gf != null:
				gi_src = gf.get_as_text()
				gf.close()
		_check_true("GameInit 显式通知 TimedChallenge", gi_src.contains("on_level_entered"))

		timed.call("enter_safehouse")
		timed.call("on_level_entered", SCHOOL)
		_check_near("换关拿新预算", float(timed.get("remaining")), 300.0)
		_check("到达关卡数 2", int(timed.get("levels_entered")), 2)

		timed.call("advance_time", 9999.0)
		_check("时间到判负", bool(timed.get("timed_out")), true)
		_check("时间到即停表", bool(timed.get("running")), false)
		_check_near("剩余归零", float(timed.get("remaining")), 0.0)

		## 记账：刚才这局（2 关 + 时间到）要原样写进 timed_records
		Global.timed_records.clear()
		Global.finish_run(false)
		_check("限时挑战写一条记录", Global.timed_records.size(), 1)
		if Global.timed_records.size() == 1:
			var tr: Dictionary = Global.timed_records[0]
			_check("记录：时间到", bool(tr.get("timed_out", false)), true)
			_check("记录：到达 2 关", int(tr.get("levels", 0)), 2)
			_check("记录：最长连杀 10", int(tr.get("best_combo", 0)), 10)
			_check("记录：未通关", bool(tr.get("cleared", true)), false)
		## finish_run 里必须把表停掉 —— 否则制作人名单（ED）期间倒计时还在跑，
		## 跑到底会在名单上冒出「时间到」。
		_check("结算后停表", bool(timed.get("running")), false)

		## 最佳成绩：通关的一局要压过「到达更深但没通关」的一局
		Global.timed_records.push_front({
			"campaign": "突袭", "campaign_id": "assault", "difficulty": 1,
			"cleared": true, "timed_out": false, "seconds": 900.0,
			"kills": 90, "deaths": 1, "levels": 2, "best_combo": 12, "at": "",
		})
		var best: Dictionary = Global.timed_best_for("assault")
		_check("最佳成绩优先通关", bool(best.get("cleared", false)), true)

		var page2: Control = RECORDS_MENU.new()
		page2.set("page", 2)
		add_child(page2)
		for i in range(3):
			await get_tree().process_frame
		_check_true("限时挑战记录页有文字", _count_labels(page2) >= 5, "%d 行" % _count_labels(page2))
		page2.queue_free()
		await get_tree().process_frame

		var saved_timed: Array = Global.timed_records.duplicate(true)
		Global.timed_records.clear()
		var page2_empty: Control = RECORDS_MENU.new()
		page2_empty.set("page", 2)
		add_child(page2_empty)
		await get_tree().process_frame
		_check_true("空限时记录页也能开", _count_labels(page2_empty) >= 3)
		page2_empty.queue_free()
		Global.timed_records = saved_timed
		await get_tree().process_frame

		timed.call("reset")
		Global.run_mode = Global.RUN_MODE_STANDARD

	## 还原玩家真实记录（本检查期间写进 config 的测试数据）
	Global.speedrun_records = backup_records
	Global.timed_records = backup_timed
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
