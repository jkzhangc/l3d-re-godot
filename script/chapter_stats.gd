extends Node

## ── 架构定位 ──
## 系统：章节统计 ｜ 层：单例（autoload: ChapterStats）
## 联机：按座位号分别累计；**客户端一律吃 Host 广播的权威快照**（见文件末尾「联机同步」）
## 职责：记录章节结算所需数据（击杀/爆头/造成与承受伤害/使用治疗品）与计时。
##       另维护「战役累计」（跨章节不清零，供终章 ED 排名段使用，2026-09-14）。
## 依赖：由子弹、近战、受伤流程按座位号写入

## 章节统计（autoload: ChapterStats）。
## 记录 L4D2 章节结算界面所需的基础数据，并按 Players 座位分别统计。

## 客户端收到 Host 的统计快照 → 结算页 / ED 名单战报据此重排（2026-09-27）。
signal remote_stats_applied

const EMPTY_STATS: Dictionary = {
	"kills": 0,
	"headshots": 0,
	"damage_dealt": 0.0,
	"damage_taken": 0.0,
	"healing_items": 0,
}

## 战役累计（跨章节保留；多一列 deaths 供终章 ED「谁死了最多」排名）。
const EMPTY_CAMPAIGN_STATS: Dictionary = {
	"kills": 0,
	"headshots": 0,
	"damage_dealt": 0.0,
	"damage_taken": 0.0,
	"healing_items": 0,
	"deaths": 0,
}

var chapter_scene: String = ""
var chapter_title: String = ""
var started_msec: int = 0
var finished_elapsed_seconds: float = -1.0
var stats_by_seat: Dictionary = {}
## 战役累计（begin_chapter 不清零；只有 init_new_game 的 reset_campaign 清）
var stats_campaign_by_seat: Dictionary = {}
## ★客户端：Host 广播来的权威快照（非空时优先于本地值）。见文件末尾「联机同步」。
var _remote_payload: Dictionary = {}


func begin_chapter(scene_path: String, display_title: String = "") -> void:
	chapter_scene = scene_path
	chapter_title = display_title
	started_msec = Time.get_ticks_msec()
	finished_elapsed_seconds = -1.0
	stats_by_seat = {}
	_remote_payload.clear()   ## 新章节 → 丢弃上一章的远端快照
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
	var camp: Dictionary = _ensure_campaign_seat(seat_index)
	camp["damage_dealt"] = float(camp["damage_dealt"]) + amount


func record_damage_taken(seat_index: int, amount: float) -> void:
	if amount <= 0.0:
		return
	var data: Dictionary = _ensure_seat(seat_index)
	data["damage_taken"] = float(data["damage_taken"]) + amount
	var camp: Dictionary = _ensure_campaign_seat(seat_index)
	camp["damage_taken"] = float(camp["damage_taken"]) + amount


func record_kill(seat_index: int, headshot: bool = false) -> void:
	var data: Dictionary = _ensure_seat(seat_index)
	data["kills"] = int(data["kills"]) + 1
	if headshot:
		data["headshots"] = int(data["headshots"]) + 1
	var camp: Dictionary = _ensure_campaign_seat(seat_index)
	camp["kills"] = int(camp["kills"]) + 1
	if headshot:
		camp["headshots"] = int(camp["headshots"]) + 1


func record_healing_item(seat_index: int) -> void:
	var data: Dictionary = _ensure_seat(seat_index)
	data["healing_items"] = int(data["healing_items"]) + 1
	var camp: Dictionary = _ensure_campaign_seat(seat_index)
	camp["healing_items"] = int(camp["healing_items"]) + 1


## 真死亡（喷雾救不回来、也没队友可切）计一次，供终章 ED 排名。
func record_death(seat_index: int) -> void:
	var camp: Dictionary = _ensure_campaign_seat(seat_index)
	camp["deaths"] = int(camp["deaths"]) + 1


func get_elapsed_seconds() -> float:
	## 客户端：以 Host 广播的用时为准（本端计时起点与 Host 有一帧级偏差，且可能漏过
	## ensure_chapter —— 见 game_init 联机分支的注释）。
	if not _remote_payload.is_empty():
		return maxf(0.0, float(_remote_payload.get("elapsed", 0.0)))
	if finished_elapsed_seconds >= 0.0:
		return finished_elapsed_seconds
	if started_msec <= 0:
		return 0.0
	return maxf(0.0, float(Time.get_ticks_msec() - started_msec) / 1000.0)


func get_stats_for_seat(seat_index: int) -> Dictionary:
	var remote: Dictionary = _remote_seat_dict("stats", seat_index)
	if not remote.is_empty():
		return remote
	return _ensure_seat(seat_index).duplicate(true)


## ── 战役累计（终章 ED 排名用）──
func get_campaign_stats_for_seat(seat_index: int) -> Dictionary:
	var remote: Dictionary = _remote_seat_dict("campaign", seat_index)
	if not remote.is_empty():
		return remote
	return _ensure_campaign_seat(seat_index).duplicate(true)


func get_campaign_totals() -> Dictionary:
	if not _remote_payload.is_empty():
		var remote_total: Variant = _remote_payload.get("campaign_totals")
		if remote_total is Dictionary and not (remote_total as Dictionary).is_empty():
			return (remote_total as Dictionary).duplicate(true)
	return _sum_table(stats_campaign_by_seat, EMPTY_CAMPAIGN_STATS,
		["kills", "headshots", "healing_items", "deaths"])


## 新游戏开局清零（Global.init_new_game 调用）。
func reset_campaign() -> void:
	stats_campaign_by_seat.clear()
	_remote_payload.clear()
	print("[ChapterStats] 战役累计统计已清零")


func get_totals() -> Dictionary:
	if not _remote_payload.is_empty():
		var remote_total: Variant = _remote_payload.get("totals")
		if remote_total is Dictionary and not (remote_total as Dictionary).is_empty():
			return (remote_total as Dictionary).duplicate(true)
	_ensure_all_seats()
	return _sum_table(stats_by_seat, EMPTY_STATS, ["kills", "headshots", "healing_items"])


func _sum_table(table: Dictionary, template: Dictionary, int_keys: Array) -> Dictionary:
	var total: Dictionary = template.duplicate(true)
	for value: Variant in table.values():
		var data: Dictionary = value as Dictionary
		for key: String in template:
			total[key] = float(total[key]) + float(data.get(key, 0))
	for key: String in int_keys:
		total[key] = int(total[key])
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


func _ensure_campaign_seat(seat_index: int) -> Dictionary:
	if seat_index < 0:
		seat_index = 0
	if not stats_campaign_by_seat.has(seat_index):
		stats_campaign_by_seat[seat_index] = EMPTY_CAMPAIGN_STATS.duplicate(true)
	return stats_campaign_by_seat[seat_index] as Dictionary


# ═══════════════════════════════════════
# 联机同步（2026-09-27）
# ═══════════════════════════════════════
## 为什么必须有这一段：客户端的击杀 / 伤害 / 治疗**从不本地累计** —— 开火只发
## fire_request，真正命中的「权威弹」在 Host 上生成并调 record_*。因此客户端本地的
## stats 恒为 0 → 章节结算页每个数值显示 0、ED 名单的「幸存者战报」整段空白
##（用户实测："每个章节总结客户端玩家里都不正常显示击杀怪那些的数值"，
##  "制作人名单表内容客户端跟主机好像不一样"）。
## 做法：**拉取式**。客户端在展示前 request → Host 回一份权威快照 → 客户端只渲染。
## 用拉取而不是「Host 定期推」，是因为它天然对齐时序：不依赖两端结算页创建的先后。
func build_sync_payload() -> Dictionary:
	return {
		"stats": stats_by_seat.duplicate(true),
		"campaign": stats_campaign_by_seat.duplicate(true),
		"totals": _sum_table(stats_by_seat, EMPTY_STATS, ["kills", "headshots", "healing_items"]),
		"campaign_totals": _sum_table(stats_campaign_by_seat, EMPTY_CAMPAIGN_STATS,
			["kills", "headshots", "healing_items", "deaths"]),
		"elapsed": get_elapsed_seconds(),
		"chapter_scene": chapter_scene,
	}


## 客户端调用：向 Host 要一份权威快照。单机 / Host 自身是空操作（本地就是权威）。
func request_sync_from_host() -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return
	request_sync.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func request_sync() -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender <= 0:
		return
	apply_sync.rpc_id(sender, build_sync_payload())


@rpc("authority", "call_remote", "reliable")
func apply_sync(payload: Dictionary) -> void:
	_remote_payload = payload
	var seat_count: int = (payload.get("stats", {}) as Dictionary).size() \
		if payload.get("stats") is Dictionary else 0
	print("[ChapterStats] 收到 Host 统计快照：%d 个座位 / 用时 %.1fs" % [
		seat_count, float(payload.get("elapsed", 0.0))])
	remote_stats_applied.emit()


func _remote_seat_dict(bucket: String, seat_index: int) -> Dictionary:
	if _remote_payload.is_empty():
		return {}
	var table: Variant = _remote_payload.get(bucket)
	if not (table is Dictionary):
		return {}
	var entry: Variant = (table as Dictionary).get(seat_index)
	if entry is Dictionary:
		return (entry as Dictionary).duplicate(true)
	return {}
