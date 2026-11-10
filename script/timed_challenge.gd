extends Node

## ── 架构定位 ──
## 系统：限时挑战 ｜ 层：单例（autoload: TimedChallenge）
## 联机：不参与 —— `is_active()` 在联机会话里恒为 false（限时挑战只在单人流程出现）
## 职责：限时挑战的「时间银行」：
##   · 每张**非安全屋**地图一份固定预算（`LEVEL_LIMITS`，按文件名关键字查表）；
##   · 击杀敌人换时间：普通击杀 +0.1s；连杀每满 10 人再加 0.5 / 1.0 / 1.5 秒……；
##   · 倒计时归零 → `expired` 信号 + 弹出 `ui/challenge_fail.gd`（回标题记账）；
##   · 安全屋停表且不显示计时器，回关卡时接着那关**上一次的余额**。
## 依赖：Global.run_mode（RUN_MODE_TIMED）、ChapterStats（关卡入口 / 击杀）、Players（无）
##
## 【为什么按关卡存余额，而不是整局一条命 / 也不是每关重发】
##   · 每关重发：死一次回安全屋再进 = 白拿一份新时限，等于用死亡刷时间；
##   · 整局一条命：安全屋不耗时的设定就失去意义（在屋里存装备也要扣整局预算）。
##   → 每关一份余额、存进 `_level_remaining`，重进同一关是**接着**而不是刷新；
##     只有换到另一张关卡图才拿那张图的预算。
##
## 【计时口径】用 `Time.get_ticks_msec()` 墙钟而不是累加 delta：与 `ChapterStats` 的
##   战役墙钟同源（`Engine.time_scale` 不缩放它），暂停时本节点不跑所以天然停表。

## 本关时间耗尽（只发一次）。收尾由本文件 `_show_fail()` 挂的界面负责。
signal expired

## 每击杀一人的基础加时（秒）。用户口径（2026-11-10）：杀一只丧尸 +0.1s。
const TIME_PER_KILL: float = 0.1
## 连杀台阶：每满 COMBO_STEP 人，额外加一次 COMBO_BONUS × 台阶数。
const COMBO_STEP: int = 10
const COMBO_BONUS: float = 0.5
## 连杀中断窗口（秒）：两次击杀间隔超过它就从 0 重新数。
const COMBO_WINDOW: float = 3.0
## 关卡开局横幅显示时长（秒）。
const BANNER_DURATION: float = 4.0
## 认不出关卡时的兜底时限。
const DEFAULT_LIMIT: float = 180.0

## 关卡时限表（按**文件名包含**匹配，键的顺序就是匹配顺序 —— 长的写前面）。
## 标定依据：地图体积 + 该关目标（门口 / 入口这类过场图给短，内部 / 公园给长）。
const LEVEL_LIMITS: Dictionary = {
	"电视台内-一楼": 210.0,
	"电视台内": 120.0,
	"电视台外": 150.0,
	"公司楼顶": 180.0,
	"实验室走廊": 150.0,
	"列车台": 200.0,
	"学校门口": 120.0,
	"学校内部": 300.0,
	"矿洞": 240.0,
	"街道": 240.0,
	"公园入口": 120.0,
	"公园": 300.0,
	"R市": 270.0,
}

const CHALLENGE_FAIL := preload("res://script/ui/challenge_fail.gd")

## 当前关卡的剩余秒数（HUD 直读）。
var remaining: float = 0.0
## 当前关卡的初始预算（HUD 横幅用）。
var level_limit: float = 0.0
## 当前所在关卡场景路径（安全屋里保留上一关的路径，供回关时对账）。
var level_path: String = ""
## 是否正在走表（安全屋 / 菜单 / 结算页为 false）。
var running: bool = false
## 本局是否因时间到而失败（写进记录）。
var timed_out: bool = false
## 连杀计数与剩余窗口。
var combo: int = 0
var combo_left: float = 0.0
## 本局最长连杀（记录用）。
var best_combo: int = 0
## 本局到达过的**不同**非安全屋关卡数（记录里的进度）。
var levels_entered: int = 0
## 最近一次加时的数值与经过时间（HUD 用来闪一下 +0.5s）。
var last_bonus: float = 0.0
var last_bonus_age: float = 99.0
## 关卡开局横幅剩余秒数。
var banner_seconds: float = 0.0

## 每关剩余余额（scene_path -> 秒）。重进同一关接着用，不刷新。
var _level_remaining: Dictionary = {}
var _last_msec: int = 0
var _fail_layer: CanvasLayer = null

## 时间到是否弹「挑战失败」界面。自动测试把它关掉，只验证 `timed_out` 与信号，
## 否则测试进程会被那个界面暂停住（界面自己 `get_tree().paused = true`）。
var fail_ui_enabled: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_INHERIT
	set_process(true)


func _notification(what: int) -> void:
	## 暂停期间 _process 不跑；解除暂停后不能把暂停时长一次性补扣 → 基准点归零。
	if what == NOTIFICATION_PAUSED or what == NOTIFICATION_UNPAUSED:
		_last_msec = 0


# ═══════════════════════════════════════
# 对外查询
# ═══════════════════════════════════════

## 本局是不是限时挑战（且不在联机会话里）。
func is_active() -> bool:
	if not bool(Global.is_timed_challenge()):
		return false
	var net: Node = get_node_or_null("/root/Net")
	if net != null and net.has_method("is_online_session") and bool(net.call("is_online_session")):
		return false
	return true


## 场景是不是安全屋（安全屋不计时）。
static func is_safe_house_scene(scene_path: String) -> bool:
	if scene_path.is_empty():
		return false
	var base: String = scene_path.get_file()
	return base.contains("安全屋") or base.to_lower().contains("safe")


## 该关卡的时间预算。
static func limit_for(scene_path: String) -> float:
	var base: String = scene_path.get_file()
	for key: String in LEVEL_LIMITS:
		if base.contains(key):
			return float(LEVEL_LIMITS[key])
	return DEFAULT_LIMIT


## 给记录用的快照（Global.finish_run 在 reset 之前取）。
func snapshot() -> Dictionary:
	return {
		"levels": levels_entered,
		"best_combo": best_combo,
		"timed_out": timed_out,
		"remaining": remaining,
	}


## HUD 横幅文案（关卡开局 4 秒内显示）。
func banner_text() -> String:
	if banner_seconds <= 0.0:
		return ""
	return "限时 %s　击杀 +%.1fs" % [Global.format_limit_time(level_limit), TIME_PER_KILL]


# ═══════════════════════════════════════
# 状态流转
# ═══════════════════════════════════════

## 新局 / 回标题：清空全部状态。
func reset() -> void:
	remaining = 0.0
	level_limit = 0.0
	level_path = ""
	running = false
	timed_out = false
	combo = 0
	combo_left = 0.0
	best_combo = 0
	levels_entered = 0
	last_bonus = 0.0
	last_bonus_age = 99.0
	banner_seconds = 0.0
	_level_remaining.clear()
	_last_msec = 0
	_remove_fail_layer()


## 进入一张关卡图（`ChapterStats.begin_chapter` 调 —— 它是换图的唯一入口）。
## 安全屋走 `enter_safehouse()`；同一关重进（死亡回安全屋再回来）**接着**上次的余额。
func on_level_entered(scene_path: String) -> void:
	if not is_active():
		return
	if is_safe_house_scene(scene_path):
		enter_safehouse()
		return
	if timed_out:
		## 已经判负、正在等玩家按键回标题：别再把表打起来。
		return
	var limit: float = limit_for(scene_path)
	if not _level_remaining.has(scene_path):
		_level_remaining[scene_path] = limit
		levels_entered += 1
	level_path = scene_path
	level_limit = limit
	remaining = float(_level_remaining[scene_path])
	combo = 0
	combo_left = 0.0
	last_bonus_age = 99.0
	banner_seconds = BANNER_DURATION
	running = true
	_last_msec = 0
	print("[限时挑战] %s：限时 %.0f 秒（本关余额 %.1f 秒，已到达 %d 关）" % [
		scene_path.get_file(), limit, remaining, levels_entered])


## 停表但**保留**本局数据（ED 结算 / 记录写完之后调）。
## ★为什么需要：ED（credits）不是地图场景，不会触发 `enter_safehouse()` ——
##   没有这一步，倒计时会在制作人名单里继续跑，跑到底还会冒出「时间到」。
func stop() -> void:
	_stash()
	running = false
	banner_seconds = 0.0
	combo = 0
	combo_left = 0.0
	_last_msec = 0


## 进入安全屋：停表 + 把当前余额存回这一关。
func enter_safehouse() -> void:
	_stash()
	running = false
	combo = 0
	combo_left = 0.0
	banner_seconds = 0.0
	_last_msec = 0


## 玩家击杀了一个敌人（`ChapterStats.record_kill` 调）。
func on_enemy_killed() -> void:
	if not running or not is_active():
		return
	combo += 1
	combo_left = COMBO_WINDOW
	best_combo = maxi(best_combo, combo)
	var bonus: float = TIME_PER_KILL
	if combo % COMBO_STEP == 0:
		## 连杀台阶：10 人 +0.5、20 人 +1.0、30 人 +1.5……（台阶本身也叠在基础加时上）
		bonus += COMBO_BONUS * float(combo / COMBO_STEP)
	remaining += bonus
	_level_remaining[level_path] = remaining
	last_bonus = bonus
	last_bonus_age = 0.0


func _stash() -> void:
	if not level_path.is_empty():
		_level_remaining[level_path] = remaining


func _process(delta: float) -> void:
	if last_bonus_age < 99.0:
		last_bonus_age += delta
	if banner_seconds > 0.0:
		banner_seconds = maxf(0.0, banner_seconds - delta)
	if not running:
		_last_msec = 0
		return
	if not is_active():
		running = false
		return
	var now: int = Time.get_ticks_msec()
	if _last_msec <= 0:
		_last_msec = now
		return
	var dt: float = float(now - _last_msec) / 1000.0
	_last_msec = now
	if dt <= 0.0:
		return
	advance_time(dt)


## 扣时间 + 连 kill 窗口衰减 + 到点判负。`_process` 用墙钟算出 dt 后调它；
## 自动测试可以直接喂一个 dt（不必真的等 5 分钟）。
func advance_time(dt: float) -> void:
	if not running or dt <= 0.0:
		return
	remaining -= dt
	## 每帧回写余额：`on_level_entered` 重进同一关时读的就是它 ——
	## 少这一步，关内耗掉的时间会被「上一次写进字典的旧值」盖回去（测试踩过）。
	_level_remaining[level_path] = remaining
	if combo_left > 0.0:
		combo_left -= dt
		if combo_left <= 0.0:
			combo_left = 0.0
			combo = 0
	if remaining > 0.0:
		return
	remaining = 0.0
	running = false
	timed_out = true
	_level_remaining[level_path] = 0.0
	print("[限时挑战] 时间到！到达 %d 关 / 最长连杀 %d" % [levels_entered, best_combo])
	expired.emit()
	if fail_ui_enabled:
		_show_fail()


# ═══════════════════════════════════════
# 失败界面
# ═══════════════════════════════════════

## 挂到自己的子节点上（autoload 不随场景切换销毁，界面也就不会丢）。
## 用 CanvasLayer 而不是裸 Control：触摸层在 layer 110，必须盖在它上面。
func _show_fail() -> void:
	if _fail_layer != null and is_instance_valid(_fail_layer):
		return
	var layer := CanvasLayer.new()
	layer.name = "ChallengeFailLayer"
	layer.layer = 120
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	var ui: Control = CHALLENGE_FAIL.new()
	layer.add_child(ui)
	_fail_layer = layer


func _remove_fail_layer() -> void:
	if _fail_layer != null and is_instance_valid(_fail_layer):
		_fail_layer.queue_free()
	_fail_layer = null
