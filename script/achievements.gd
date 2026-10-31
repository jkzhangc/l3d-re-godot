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

## ── 成就目录 ──
## 首批（2026-10-02）只做第一章可判定的子集；**2026-10-29 用户要求补全第二战役 + 不存档通关**。
## 原作 26 个里仍未做的：第三战役 Dead Island（未实装）、Realism 模式 3 条、Boss 狩猎 4 条、
##   「暴君十必杀」「三人抱燃料罐」「不放下拾取物」等章节专属条件 —— 缺对应系统/数据，不先挂空条目。
## kind 说明：clear_campaign*=通关战役 / solo_clear=单人通关 / no_damage_clear=无伤通关 /
##   speed_clear=限时通关 / no_save_clear=不存档通关 / gentleman_clear=不惊动女巫通关 /
##   其余为计数型（target = 目标次数）。
## ★2026-10-03 曾删除「不存档通关」（当时没有手动存档，判定永不触发）；
##   2026-10-29 手动存档（20 槽 `user://saves/`）已实装 → 按原作恢复，钩子见 `SaveManager`。
const CATALOG: Array[Dictionary] = [
	## ── 通关型（全队，座位 -1）──
	{"id": "clear_attack", "name": "明天仍在等着我们", "desc": "通关第一战役（突袭）",
		"kind": "clear_campaign", "target": 1},
	{"id": "clear_night_hunter", "name": "太勉强了吧", "desc": "通关第二战役（夜行猎手）",
		"kind": "clear_campaign_night_hunter", "target": 1},
	{"id": "left_1_dead", "name": "Left 1 Dead", "desc": "单人通关一次战役",
		"kind": "solo_clear", "target": 1},
	{"id": "untouchable", "name": "不可触碰", "desc": "全程无伤通关一次战役",
		"kind": "no_damage_clear", "target": 1},
	{"id": "speedrun", "name": "西伯利亚超特急", "desc": "10 分钟内通关一次战役",
		"kind": "speed_clear", "target": 1, "limit_seconds": 600},
	{"id": "gentleman", "name": "绅士", "desc": "全程不惊动女巫通关一次战役",
		"kind": "gentleman_clear", "target": 1},
	{"id": "dark_finale", "name": "我们是暗夜族", "desc": "夜行猎手终章不打开照明通关",
		"kind": "dark_finale_clear", "target": 1},
	{"id": "no_save", "name": "人生只有一次", "desc": "全程不存档通关一次战役",
		"kind": "no_save_clear", "target": 1},
	## ── 计数型（按座位归属）──
	{"id": "instakill_100", "name": "毫不留情", "desc": "用即死攻击击杀 100 体",
		"kind": "instant_kill", "target": 100},
	{"id": "backstab_100", "name": "必杀专家", "desc": "发动必杀（背刺）100 次",
		"kind": "backstab", "target": 100},
	{"id": "counter_100", "name": "反击大师", "desc": "发动反击 100 次",
		"kind": "counter", "target": 100},
	{"id": "pills_10", "name": "不行。绝对不行。", "desc": "使用治疗品 10 次",
		"kind": "heal_item", "target": 10},
	{"id": "kill_1000", "name": "大量杀戮纪行", "desc": "单次游玩击杀 1000 体",
		"kind": "kill", "target": 1000},
	{"id": "swallow_female", "name": "三流色情片", "desc": "猎人γ 吞下女性角色",
		"kind": "swallow_female", "target": 1},
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
static var _session_saved: bool = false         ## 本局是否用过存档（保存或读档 → 不存档成就不给）
static var _session_witch_startled: bool = false ## 本局是否惊动过女巫（绅士成就）
static var _session_lights_used: bool = false   ## 本局是否开过照明（暗夜族成就）
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
	return kind.ends_with("_clear") or kind.begins_with("clear_campaign")


static func progress_of(seat: int, id: String) -> int:
	return int(_progress.get(_key(_norm_seat(seat), id), 0))


static func is_unlocked(seat: int, id: String) -> bool:
	return _unlocked.has(_key(_norm_seat(seat), id))


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
	_session_witch_startled = false
	_session_lights_used = false
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


## 本局用过存档（保存或读档成功时由 SaveManager 调用）。
## 原作「人生プレイ」= 战役内不存档通关；**读过档也算用档** —— 否则读一个中段档再通关白送成就。
static func on_save_used() -> void:
	_session_saved = true


## 惊动女巫。原作「ジェントルマン」= 不刺激女巫通关（攻击 / 接近都算）。
## 两个调用点：Enemy.startle_witch（贴脸 / 刺激值满 / 普通受击）与 take_damage 的
## 「一击打死女巫」早退分支（不走 startle_witch，也必须记上）。
static func on_witch_startled() -> void:
	_session_witch_startled = true


## 打开过照明（InteractiveSwitchNode.is_light_switch 的开关被拨到「开」时调用）。
## 原作「オレたちクラヤミ族」= 夜行猎手终章不打开照明存活下来。
static func on_lights_used() -> void:
	_session_lights_used = true


## ハンターγ 丸呑み命中女性角色（原作「三流ポルノ」）。按被吞玩家的座位归属。
static func on_female_swallowed(seat: int) -> void:
	_add(seat, "swallow_female", 1)


## 战役通关结算（CampaignEnding.start 调用）。
## `seat_count` = 本局实际参战人数（1 = 单人）。
## `campaign_id` = 当前战役 id（"assault" / "night_hunter"）—— 战役专属通关成就靠它区分。
static func finish_campaign(seat_count: int, campaign_id: String = "") -> void:
	var elapsed: float = float(Time.get_ticks_msec() - _session_start_msec) / 1000.0
	## 战役专属：第一战役只认 assault；campaign_id 为空（旧调用/测试）时按旧行为给第一战役。
	if campaign_id.is_empty() or campaign_id == "assault":
		_add(TEAM_SEAT, "clear_campaign", 1)
	if campaign_id == "night_hunter":
		_add(TEAM_SEAT, "clear_campaign_night_hunter", 1)
	if seat_count <= 1:
		_add(TEAM_SEAT, "solo_clear", 1)
	if not _session_damaged:
		_add(TEAM_SEAT, "no_damage_clear", 1)
	## 不存档通关：本局从未保存/读取过存档。
	if not _session_saved:
		_add(TEAM_SEAT, "no_save_clear", 1)
	## 绅士：全程没有惊动过女巫（攻击 / 接近刺激都走 startle_witch）。
	if not _session_witch_startled:
		_add(TEAM_SEAT, "gentleman_clear", 1)
	## 暗夜族：第二战役终章全程没打开照明。
	if campaign_id == "night_hunter" and not _session_lights_used:
		_add(TEAM_SEAT, "dark_finale_clear", 1)
	## 速通：目标值是「限时秒数」而不是解锁阈值 → 达标时直接把进度写成 1（=达成）。
	## 早期写成 `_add(..., 0)` 是错的：amount=0 不涨进度、永远够不到 target。
	var limit: float = float(catalog_entry("speedrun").get("limit_seconds", 600.0))
	if elapsed <= limit:
		_progress[_key(TEAM_SEAT, "speedrun")] = 1
		_check_unlock(TEAM_SEAT, "speedrun")
	print("[成就] 通关结算：战役=%s 用时 %.0fs  受伤=%s  存档=%s  惊动女巫=%s  人数=%d"
		% [campaign_id if not campaign_id.is_empty() else "（未知）", elapsed,
			str(_session_damaged), str(_session_saved), str(_session_witch_startled), seat_count])
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
	## ★2026-10-31 用户要求：**单人局不分 1P/2P** —— 一个人操作 4 个角色时，
	## 进度若按座位分开，会出现「换个角色打就重新计数」和成就页列出 1P/2P 的观感。
	## 联机仍然按座位归属（多人要能互相看到对方成就）。
	seat = _norm_seat(seat)
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


# ═══════════════════════════════════════
# 单机归并（2026-10-31 用户要求：单人不分 1P/2P）
# ═══════════════════════════════════════
## 单机下所有计数一律归到 `TEAM_SEAT`（-1）；联机保持按座位归属。
## 历史进度（键形如 `"0:kill"`）在首次单机访问时**并进全队键**，不丢。
static var _single_seat_migrated: bool = false


static func _is_online() -> bool:
	var loop: MainLoop = Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return false
	var root: Node = (loop as SceneTree).root
	var net: Node = root.get_node_or_null("Net") if root != null else null
	return net != null and net.has_method("is_online_session") and bool(net.call("is_online_session"))


## 单机 → 全队座位；联机原样返回。
static func _norm_seat(seat: int) -> int:
	if _is_online():
		return seat
	_migrate_single_player_progress()
	return TEAM_SEAT


## 把历史上的「座位 0/1/2/3」进度并进全队键（每个进程只跑一次）。
## ⚠ 只在**非联机会话**下触发（`_norm_seat` 唯一调用点），所以联机中的按座位数据不会被误并；
##   代价是：玩家过去在联机里累计的「按座位」历史会一次性并成全队（一次性、不可逆）。
##   认为这是用户要的语义 —— 成就是账号个人数据，座位只是为了"看到队友的"。
static func _migrate_single_player_progress() -> void:
	if _single_seat_migrated:
		return
	_single_seat_migrated = true
	var moved: int = 0
	for k: Variant in _progress.keys().duplicate():
		var parts: PackedStringArray = str(k).split(":", false, 1)
		if parts.size() != 2 or int(parts[0]) < 0:
			continue
		var team_key: String = _key(TEAM_SEAT, parts[1])
		_progress[team_key] = int(_progress.get(team_key, 0)) + int(_progress[k])
		_progress.erase(k)
		moved += 1
	for k: Variant in _unlocked.keys().duplicate():
		var parts: PackedStringArray = str(k).split(":", false, 1)
		if parts.size() != 2 or int(parts[0]) < 0:
			continue
		var team_key: String = _key(TEAM_SEAT, parts[1])
		if not _unlocked.has(team_key):
			_unlocked[team_key] = _unlocked[k]
		_unlocked.erase(k)
		moved += 1
	if moved > 0:
		print("[成就] 单机归并：%d 条按座位的旧记录已并入全队（不再区分 1P/2P）" % moved)
		_remap_pending_seats()
		save_progress()


## 待展示列表里的座位同样归并，否则 ED 弹窗仍会显示「1P 解锁」。
static func _remap_pending_seats() -> void:
	for item: Variant in _pending:
		if item is Dictionary and int((item as Dictionary).get("seat", 0)) >= 0:
			(item as Dictionary)["seat"] = TEAM_SEAT


## 清空全部进度（内存 + 待展示 + 本局统计）。用途：隔离测试环境、或将来"重置成就"功能。
## ⚠ 不动磁盘文件；要一并清盘请在调用后再 save_progress()。
static func reset_all_progress() -> void:
	_progress = {}
	_unlocked = {}
	_pending = []
	_session_kills.clear()
	_session_damaged = false
	_session_saved = false
	_session_witch_startled = false
	_session_lights_used = false


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
