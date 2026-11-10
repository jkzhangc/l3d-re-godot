extends Node

## 诊断探针（窗口渲染）：把本批新增/改动的界面渲染成 PNG，肉眼核对版式。
##   · 游戏模式选择
##   · 竞速记录页 / 游玩统计页（临时塞几条假记录，不改玩家的真实数据）
##   · 标题画面设置页（加了「血液颜色 / 血液特效」两行，确认没被挤出窗口）
## 用法："$GD" --path <项目> res://tools/new_ui_shot_probe.tscn
## 产物在 user://ui_probe_new/。

const MODE_MENU := preload("res://script/ui/game_mode_menu.gd")
const RECORDS_MENU := preload("res://script/ui/records_menu.gd")
const TITLE_SCENE := "res://scene/title_screen.tscn"
const OUT_DIR := "user://ui_probe_new"

var _backup_records: Array = []
var _backup_stats: Dictionary = {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_backup_records = Global.speedrun_records.duplicate(true)
	_backup_stats = Global.play_stats.duplicate(true)

	## ① 游戏模式
	var mode: Control = MODE_MENU.new()
	add_child(mode)
	for i in range(6):
		await get_tree().process_frame
	_save("game_mode.png")
	mode.queue_free()
	await get_tree().process_frame

	## ② 记录页：塞两条假记录 + 一组假统计
	Global.speedrun_records = [
		{"campaign": "突袭", "campaign_id": "assault", "difficulty": 1, "cleared": true,
			"seconds": 754.3, "deaths": 2, "kills": 431, "at": "2026-11-10 14:20:00"},
		{"campaign": "夜行猎手", "campaign_id": "night_hunter", "difficulty": 2, "cleared": false,
			"seconds": 1830.0, "deaths": 5, "kills": 902, "at": "2026-11-10 13:02:00"},
	]
	Global.play_stats = {
		"runs": 12, "clears": 7, "seconds": 11520, "kills": 4231, "headshots": 912,
		"deaths": 23, "damage_dealt": 1234567.0, "damage_taken": 456789.0, "healing_items": 88,
	}
	for page: int in [0, 1]:
		var menu: Control = RECORDS_MENU.new()
		menu.set("page", page)
		add_child(menu)
		for i in range(6):
			await get_tree().process_frame
		_save("records_%d.png" % page)
		menu.queue_free()
		await get_tree().process_frame

	Global.speedrun_records = _backup_records
	Global.play_stats = _backup_stats

	## ③ 标题画面设置页
	var packed: PackedScene = load(TITLE_SCENE) as PackedScene
	if packed != null:
		var title: Control = packed.instantiate() as Control
		add_child(title)
		for i in range(20):
			await get_tree().process_frame
		title.call("_enter_settings")
		for i in range(6):
			await get_tree().process_frame
		_save("title_settings.png")
		title.call("_exit_settings")
		for i in range(4):
			await get_tree().process_frame
		## 「其他」二级页：新增「竞速记录 / 游玩统计」两行后确认没被挤出窗口
		title.call("_enter_other_menu")
		for i in range(6):
			await get_tree().process_frame
		_save("title_other.png")
		title.queue_free()

	## ④ 血效配色（同一帧动画，红 / 绿 / 紫 各一张，确认着色器真的换了色相）
	await _shoot_blood(0, "blood_red.png")
	await _shoot_blood(1, "blood_green.png")
	await _shoot_blood(2, "blood_purple.png")
	await _shoot_blood(3, "blood_gray.png")

	## ⑤ 竞速 HUD 计时器（中下方）
	Global.run_mode = Global.RUN_MODE_SPEEDRUN
	var cs: Node = get_node_or_null("/root/ChapterStats")
	if cs != null and cs.has_method("reset_campaign"):
		cs.call("reset_campaign")
	var packed_hud: PackedScene = load("res://scene/ui/combat_hud.tscn") as PackedScene
	if packed_hud != null:
		## ★HUD 的根是 CanvasLayer，不是 Control —— 按 Control 转型会得到 null。
		var hud: Node = packed_hud.instantiate()
		add_child(hud)
		for i in range(30):
			await get_tree().process_frame
		_save("hud_timer.png")
		hud.queue_free()
	Global.run_mode = Global.RUN_MODE_STANDARD
	if cs != null and cs.has_method("stop_campaign_clock"):
		cs.call("stop_campaign_clock")

	print("=== 截图目录：%s ===" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit(0)


## 把「命中喷血」动画摆到画面中央，等它播到血花最大的一帧再截图。
func _shoot_blood(option: int, file_name: String) -> void:
	Global.blood_color_option = option
	Global.blood_enabled = true
	var anim: Node = (load("res://anim/anim_effect_hit.tscn") as PackedScene).instantiate()
	anim.set("auto_free", false)
	anim.set("looping", true)
	add_child(anim)
	(anim as Node2D).position = Vector2(640, 480)
	(anim as Node2D).scale = Vector2(2.5, 2.5)
	for i in range(20):
		await get_tree().process_frame
	_save(file_name)
	anim.queue_free()
	await get_tree().process_frame


func _save(file_name: String) -> void:
	var tex := get_viewport().get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	img.save_png(OUT_DIR.path_join(file_name))
