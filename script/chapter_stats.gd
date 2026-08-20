extends Node
## 章节统计（autoload: ChapterStats）。
## 记录 L4D2 章节结算界面所需的基础数据，并按 Players 座位分别统计。

const EMPTY_STATS: Dictionary = {
	"kills": 0,
	"headshots": 0,
	"damage_dealt": 0.0,
	"damage_taken": 0.0,
	"healing_items": 0,
}

var chapter_scene: String = ""
var chapter_title: String = ""
var started_msec: int = 0
var finished_elapsed_seconds: float = -1.0
var stats_by_seat: Dictionary = {}


func begin_chapter(scene_path: String, display_title: String = "") -> void:
	chapter_scene = scene_path
	chapter_title = display_title
	started_msec = Time.get_ticks_msec()
	finished_elapsed_seconds = -1.0
	stats_by_seat = {}
	_ensure_all_seats()
	print("[ChapterStats] 开始章节: %s" % scene_path)


func ensure_chapter(scene_path: String) -> void:
	if started_msec <= 0 or chapter_scene != scene_path:
		begin_chapter(scene_path)


func finish_chapter() -> void:
	if finished_elapsed_seconds >= 0.0:
		return
	if started_msec <= 0:
		started_msec = Time.get_ticks_msec()
	finished_elapsed_seconds = maxf(0.0, float(Time.get_ticks_msec() - started_msec) / 1000.0)
	_ensure_all_seats()
	print("[ChapterStats] 章节完成，用时 %.1f 秒" % finished_elapsed_seconds)


func record_damage_dealt(seat_index: int, amount: float) -> void:
	if amount <= 0.0:
		return
	var data: Dictionary = _ensure_seat(seat_index)
	data["damage_dealt"] = float(data["damage_dealt"]) + amount


func record_damage_taken(seat_index: int, amount: float) -> void:
	if amount <= 0.0:
		return
	var data: Dictionary = _ensure_seat(seat_index)
	data["damage_taken"] = float(data["damage_taken"]) + amount


func record_kill(seat_index: int, headshot: bool = false) -> void:
	var data: Dictionary = _ensure_seat(seat_index)
	data["kills"] = int(data["kills"]) + 1
	if headshot:
		data["headshots"] = int(data["headshots"]) + 1


func record_healing_item(seat_index: int) -> void:
	var data: Dictionary = _ensure_seat(seat_index)
	data["healing_items"] = int(data["healing_items"]) + 1


func get_elapsed_seconds() -> float:
	if finished_elapsed_seconds >= 0.0:
		return finished_elapsed_seconds
	if started_msec <= 0:
		return 0.0
	return maxf(0.0, float(Time.get_ticks_msec() - started_msec) / 1000.0)


func get_stats_for_seat(seat_index: int) -> Dictionary:
	return _ensure_seat(seat_index).duplicate(true)


func get_totals() -> Dictionary:
	_ensure_all_seats()
	var total: Dictionary = EMPTY_STATS.duplicate(true)
	for value: Variant in stats_by_seat.values():
		var data: Dictionary = value as Dictionary
		for key: String in EMPTY_STATS:
			total[key] = float(total[key]) + float(data.get(key, 0))
	total["kills"] = int(total["kills"])
	total["headshots"] = int(total["headshots"])
	total["healing_items"] = int(total["healing_items"])
	return total


func _ensure_all_seats() -> void:
	for i: int in range(Players.seat_count()):
		_ensure_seat(i)


func _ensure_seat(seat_index: int) -> Dictionary:
	if seat_index < 0:
		seat_index = 0
	if not stats_by_seat.has(seat_index):
		stats_by_seat[seat_index] = EMPTY_STATS.duplicate(true)
	return stats_by_seat[seat_index] as Dictionary
