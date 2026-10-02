extends RefCounted

## ── 架构定位 ──
## 系统：成就 ｜ 层：玩法（**纯静态类，不是 autoload** —— 避免动 project.godot 的启动清单）
## 联机：解锁在 Host 侧结算；ED 弹窗由 Host 汇总后广播（两端同一份列表）
## 职责：成就目录 / 进度累计 / 解锁判定 / 持久化（`user://achievements.json`）。
## 依赖：Global（新游戏入口）、ChapterStats（击杀归属）、CampaignEnding（ED 弹窗）。
##
## 【为什么进度按座位分开存】
## 用户 2026-10-02 要求「多人模式下要显示其他玩家跟自己的成就」→ 计数必须**归属到人**，
## 而不是只留一个全队总数。键 = `"座位:成就id"`；座位 -1 = **全队成就**（通关/无伤这类）。

const SAVE_PATH := "user://achievements.json"
## 实际使用的存档路径。默认即 SAVE_PATH；**可覆盖**（隔离测试 / 将来多存档位都靠它）。
static var save_path: String = SAVE_PATH

## ── 首批成就目录（2026-10-02 与用户确认：只做第一章可判定的子集）──
## 原作 26 个里有 12 个依赖第二/三战役与 Realism 模式，等那些内容做出来再补。
## kind 说明：clear_campaign=通关战役 / solo_clear=单人通关 / no_damage_clear=无伤通关 /
##   no_save_clear=不存档通关 / speed_clear=限时通关 / 其余为计数型（target = 目标次数）。
const CATALOG: Array[Dictionary] = [
	{"id": "clear_attack", "name": "俺達には明日があるんだ", "desc": "通关第一战役（突袭）",
		"kind": "clear_campaign", "target": 1},
	{"id": "instakill_100", "name": "手加減なし", "desc": "用即死攻击击杀 100 体",
		"kind": "instant_kill", "target": 100},
	{"id": "backstab_100", "name": "必殺仕事人", "desc": "发动必杀（背刺）100 次",
		"kind": "backstab", "target": 100},
	{"id": "counter_100", "name": "カウンター免許皆伝", "desc": "发动反击 100 次",
		"kind": "counter", "target": 100},
	{"id": "pills_10", "name": "ダメ。ゼッタイ。", "desc": "使用治疗品 10 次",
		"kind": "heal_item", "target": 10},
	{"id": "kill_1000", "name": "大量虐殺紀行", "desc": "单次游玩击杀 1000 体",
		"kind": "kill", "target": 1000},
	{"id": "left_1_dead", "name": "Left 1 Dead", "desc": "单人通关一次战役",
		"kind": "solo_clear", "target": 1},
	{"id": "untouchable", "name": "アンタッチャブル", "desc": "全程无伤通关一次战役",
		"kind": "no_damage_clear", "target": 1},
	{"id": "no_save", "name": "人生プレイ", "desc": "战役中一次都没存档并通关",
		"kind": "no_save_clear", "target": 1},
	{"id": "speedrun", "name": "シベリア超特急", "desc": "10 分钟内通关一次战役",
		"kind": "speed_clear", "target": 1, "limit_seconds": 600},
]
const TEAM_SEAT: int = -1

# ═══════════════════════════════════════
# 状态（静态：进程内跨场景保留）
# ═══════════════════════════════════════
static var _progress: Dictionary = {}   ## "座位:id" → 累计值
static var _unlocked: Dictionary = {}   ## "座位:id" → 解锁时刻（毫秒，仅作记录）
static var _pending: Array = []         ## [{seat, id}] 本次会话新解锁，ED 弹窗消费后清空
static var _loaded: bool = false

## 单次游玩统计（begin_campaign 时重置）
static var _session_kills: Dictionary = {}      ## 座位 → 本局击杀
static var _session_damaged: bool = false       ## 本局是否受过伤（无伤成就）
static var _session_saved: bool = false         ## 本局是否存过档
static var _session_start_msec: int = 0


## ── 目录查询 ──
static func catalog_entry(id: String) -> Dictionary:
	for e: Dictionary in CATALOG:
		if str(e.get("id", "")) == id:
			return e
	return {}


static func target_of(id: String) -> int:
	return int(catalog_entry(id).get("target", 1))


static func name_of(id: String) -> String:
	return str(catalog_entry(id).get("name", id))


static func desc_of(id: String) -> String:
	return str(catalog_entry(id).get("desc", ""))


## 该成就是否「全队型」（通关/无伤/速通等）—— UI 上单独归类。
static func is_team_achievement(id: String) -> bool:
	var kind: String = str(catalog_entry(id).get("kind", ""))
	return kind.ends_with("_clear")


static func progress_of(seat: int, id: String) -> int:
	return int(_progress.get(_key(seat, id), 0))


static func is_unlocked(seat: int, id: String) -> bool:
	return _unlocked.has(_key(seat, id))


## 全员任一解锁即算「已达成」（标题里的成就页按此显示，避免同一成就在不同座位重复列）。
static func is_unlocked_any(id: String) -> bool:
	for k: String in _unlocked.keys():
		if k.ends_with(":" + id):
			return true
	return false


static func unlocked_count() -> int:
	var n: int = 0
	for e: Dictionary in CATALOG:
		if is_unlocked_any(str(e.get("id", ""))):
			n += 1
	return n


# ═══════════════════════════════════════
# 对外事件入口（各系统在既有钩子上调一行即可）
# ═══════════════════════════════════════

## 新战役开始（Global.init_new_game 调用）：清本局统计。
static func begin_campaign() -> void:
	load_progress()
	_session_kills.clear()
	_session_damaged = false
	_session_saved = false
	_session_start_msec = Time.get_ticks_msec()
	_pending.clear()
	print("[成就] 本局开始（已解锁 %d/%d）" % [unlocked_count(), CATALOG.size()])


## 击杀一体（座位来源：ChapterStats.record_kill）。`instant` = 即死攻击击杀。
static func on_kill(seat: int, instant: bool = false) -> void:
	_session_kills[seat] = int(_session_kills.get(seat, 0)) + 1
	_add(seat, "kill", 1)              ## kill_1000：累计到目标值即解锁
	if instant:
		_add(seat, "instant_kill", 1)  ## instakill_100：即死击杀单独计


## 发动一次必杀（背刺）。注意是「发动」不是「击杀」（原作成就：必杀 100 次）。
static func on_backstab(seat: int) -> void:
	_add(seat, "backstab", 1)


## 发动一次见切反击。
static func on_counter(seat: int) -> void:
	_add(seat, "counter", 1)


## 使用一次治疗品。
static func on_heal_item(seat: int) -> void:
	_add(seat, "heal_item", 1)


## 玩家受到伤害（无伤成就的判定依据）。
static func on_player_damaged() -> void:
	_session_damaged = true


## 用了一次存档（不存档成就的判定依据）。
static func on_save_used() -> void:
	_session_saved = true


## 战役通关结算（CampaignEnding.start 调用）。
## `seat_count` = 本局实际参战人数（1 = 单人）。
static func finish_campaign(seat_count: int) -> void:
	var elapsed: float = float(Time.get_ticks_msec() - _session_start_msec) / 1000.0
	_add(TEAM_SEAT, "clear_campaign", 1)
	if seat_count <= 1:
		_add(TEAM_SEAT, "solo_clear", 1)
	if not _session_damaged:
		_add(TEAM_SEAT, "no_damage_clear", 1)
	if not _session_saved:
		_add(TEAM_SEAT, "no_save_clear", 1)
	## 速通：目标值是「限时秒数」而不是解锁阈值 → 达标时直接把进度写成 1（=达成）。
	## 早期写成 `_add(..., 0)` 是错的：amount=0 不涨进度、永远够不到 target。
	var limit: float = float(catalog_entry("speedrun").get("limit_seconds", 600.0))
	if elapsed <= limit:
		_progress[_key(TEAM_SEAT, "speedrun")] = 1
		_check_unlock(TEAM_SEAT, "speedrun")
	print("[成就] 通关结算：用时 %.0fs  受伤=%s  存过档=%s  人数=%d"
		% [elapsed, str(_session_damaged), str(_session_saved), seat_count])
	save_progress()


## 取出并清空本次待展示的解锁（ED 弹窗调用；**取走即清**，保证只展示一次）。
static func take_pending() -> Array:
	var out: Array = _pending.duplicate()
	_pending.clear()
	return out


## 只查看待展示条数（**不取走**）。调用方要先判断"有没有"，再决定是否开弹窗。
static func pending_count() -> int:
	return _pending.size()


# ═══════════════════════════════════════
# 进度与解锁
# ═══════════════════════════════════════

## 加进度；跨过目标值即解锁并记入待展示列表。
## `amount = 0` 表示「只按当前值判定一次」（速通/1000 杀这类由外部先写值）。
static func _add(seat: int, kind: String, amount: int) -> void:
	var id: String = _id_of_kind(kind)
	if id.is_empty() or _unlocked.has(_key(seat, id)):
		return                      ## 已解锁：不再累计（成就是一次性的）
	if amount != 0:
		var k: String = _key(seat, id)
		_progress[k] = int(_progress.get(k, 0)) + amount
	_check_unlock(seat, id)


## 达到目标值即解锁并记入待展示列表（幂等；速通这类由外部先写进度再调本函数）。
static func _check_unlock(seat: int, id: String) -> void:
	var k: String = _key(seat, id)
	if _unlocked.has(k) or int(_progress.get(k, 0)) < target_of(id):
		return
	_unlocked[k] = Time.get_ticks_msec()
	_pending.append({"seat": seat, "id": id})
	print("[成就] ★解锁：%s（座位 %s）" % [name_of(id), "全队" if seat == TEAM_SEAT else str(seat + 1)])
	save_progress()


static func _id_of_kind(kind: String) -> String:
	for e: Dictionary in CATALOG:
		if str(e.get("kind", "")) == kind:
			return str(e.get("id", ""))
	return ""


static func _key(seat: int, id: String) -> String:
	return "%d:%s" % [seat, id]


## 清空全部进度（内存 + 待展示 + 本局统计）。用途：隔离测试环境、或将来"重置成就"功能。
## ⚠ 不动磁盘文件；要一并清盘请在调用后再 save_progress()。
static func reset_all_progress() -> void:
	_progress = {}
	_unlocked = {}
	_pending = []
	_session_kills.clear()
	_session_damaged = false
	_session_saved = false


## 强制重新从磁盘读取（正常启动只读一次，这是给测试/切换存档位用的显式入口）。
static func reload_progress() -> void:
	_loaded = false
	load_progress()


# ═══════════════════════════════════════
# 持久化（user://achievements.json —— 刻意**不写 config.json**：
# 那是被 git 跟踪的文件，往里塞成就进度会让工作区每次游玩都变脏）
# ═══════════════════════════════════════
static func load_progress() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(save_path):
		return
	var f: FileAccess = FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(text) if text else null
	if data is Dictionary:
		_progress = (data as Dictionary).get("progress", {})
		_unlocked = (data as Dictionary).get("unlocked", {})


static func save_progress() -> void:
	var f: FileAccess = FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_warning("[成就] 存档写入失败: %s" % save_path)
		return
	f.store_string(JSON.stringify({"progress": _progress, "unlocked": _unlocked}, "\t"))
	f.close()
