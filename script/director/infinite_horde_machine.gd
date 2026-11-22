@tool
extends Node2D

## ── 架构定位 ──
## 系统：导演/刷怪 ｜ 层：玩法（Node2D，地图标记）
## 联机：Host 权威（刷怪 + 阶段）；Client 只同步倒计时与强度，不本地刷怪。
## 职责：无限尸潮 —— 地图里放下该节点，载入后自动进入预备倒计时；
##       倒计时归零开始**无限**刷怪，默认不播尸潮 BGM（与防守战区分）。
## 依赖：Director（spawn_horde_nodes / set_director_suspended）、CombatHud（倒计时）、
##       NetworkWorld（阶段/强度 RPC）、Players（人数缩放）。
##
## 【与 HoldoutMachine 的区别】
##   - 无需玩家交互，进图自动开始；
##   - 没有结束条件（无限），只能靠换图/节点释放收场；
##   - 默认没有 BGM；油桶容器可在装满后调 `set_intensity()` 提升数量与频率。
##
## 【可编辑】所有参数导出，地图作者/创意工坊可直接改。

const MAP_SCENE_QUERY = preload("res://script/map/map_locator.gd")
const HUD := preload("res://script/ui/combat_hud.gd")
## 固定刷怪点的收集（与防守战同一口径，见 holdout_spawn_point.gd::collect_points）
const SPAWN_POINT := preload("res://script/director/holdout_spawn_point.gd")

@export_group("启动")
@export var auto_start: bool = true
@export_range(0.0, 300.0, 0.1) var prepare_duration: float = 30.0
## 开刷前多少秒播「即将开始」音效（与防守战同款口径）
@export_range(0.0, 30.0, 0.1) var alert_lead_time: float = 2.0
@export var prepare_sound: AudioStream
@export var alert_sound: AudioStream
## 开刷后是否挂起常规导演编排（默认开：避免普通尸潮/节奏与无限模式打架）
@export var suspend_director: bool = true

@export_group("刷怪")
@export var spawn_per_wave: int = 4
@export_range(0.5, 60.0, 0.1) var spawn_interval: float = 3.0
## 场上同时存活上限（0 = 不限制）
@export var max_active: int = 0
## 尸潮期间丧尸是否切狂暴形态（クリムゾンヘッド）。
## 与难度附加参数「尸潮狂暴」是**与**关系：任一关闭 → 只锁定追击、不变红。
@export var horde_berserk: bool = true

@export_group("刷怪点")
## 地图里摆 `HoldoutSpawnPoint` 后，每批敌人按点位**轮转均分**（与防守战同一套点位、
## 同一套落点安全校验与出生演出）；一个都没摆则沿用原来的"屏幕外刷"。
## 点位可以放在本节点子树里，也可以散在场景任意位置（全图兜底扫描）。
@export var use_spawn_points: bool = true

@export_group("强度（油桶容器调用）")
@export_range(0.1, 10.0, 0.05) var count_multiplier: float = 1.0
@export_range(0.1, 5.0, 0.01) var interval_multiplier: float = 1.0

signal horde_started
signal intensity_changed(count_mult: float, interval_mult: float)

enum Phase { IDLE = 0, PREPARE = 1, ACTIVE = 2 }

var _phase: int = Phase.IDLE
var _timer: float = 0.0
var _spawn_timer: float = 0.0
var _alert_played: bool = false
var _remote: bool = false
var _hud_shown: bool = false
var _net_world: Node = null
var _net_sync_timer: float = 0.0
var _suspended_director: bool = false
## 固定刷怪点缓存（开刷时收集一次；点位是静态的地图资产，运行期不变）。
var _spawn_points: Array = []
## 批次轮转序号：让每批从不同点位起算，避免总是同一端出兵。
var _wave_index: int = 0
## 是否已打开导演的尸潮窗口（关闭时只清自己开的那一次）。
var _window_opened: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group(&"infinite_horde_machine")
	_remote = _is_client()
	_net_world = _find_network_world()
	if _net_world != null:
		if _net_world.has_signal("infinite_horde_state_received"):
			_net_world.connect("infinite_horde_state_received", _on_net_state)
		if _net_world.has_signal("infinite_horde_intensity_received"):
			_net_world.connect("infinite_horde_intensity_received", _on_net_intensity)
	if not _remote and auto_start:
		start_prepare.call_deferred()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _remote:
		return
	match _phase:
		Phase.PREPARE:
			_timer -= delta
			if not _alert_played and _timer <= alert_lead_time:
				_alert_played = true
				_play_sound(alert_sound)
			if _timer <= 0.0:
				_begin_active()
			_drive_hud(Phase.PREPARE, maxf(_timer, 0.0), prepare_duration)
		Phase.ACTIVE:
			_spawn_timer -= delta
			if _spawn_timer <= 0.0:
				_spawn_wave()
				_spawn_timer = maxf(0.1, spawn_interval * interval_multiplier)
		_:
			pass
	if _net_world != null:
		_net_sync_timer += delta
		if _net_sync_timer >= 0.5:
			_net_sync_timer = 0.0
			_broadcast_state()


## 开始预备倒计时（幂等）。油桶容器/脚本也可手动调。
func start_prepare() -> void:
	if _remote or _phase != Phase.IDLE:
		return
	_phase = Phase.PREPARE
	_timer = maxf(0.0, prepare_duration)
	_alert_played = _timer <= alert_lead_time
	_play_sound(prepare_sound)
	if _timer <= 0.0:
		_begin_active()
		return
	_drive_hud(Phase.PREPARE, _timer, prepare_duration)
	_broadcast_state()


func _begin_active() -> void:
	if _phase == Phase.ACTIVE:
		return
	_phase = Phase.ACTIVE
	_timer = 0.0
	_spawn_timer = 0.0
	_wave_index = 0
	_collect_spawn_points()
	_play_sound(alert_sound)
	_drive_hud(Phase.ACTIVE, 0.0, 0.0)
	_suspend_director_once()
	## ⚠ 必须在挂起之后开窗：`set_director_suspended(true)` 若正好打断常规尸潮，
	## 会强制进 cooldown 并清掉 `_horde_rage`；先开窗等于白开。
	_open_horde_window()
	_spawn_wave()
	_broadcast_state()
	horde_started.emit()


## 打开导演的「尸潮窗口」（2026-11-22 用户反馈：无限尸潮的丧尸不追人、不变狂暴）。
## 窗口内：新刷敌人由 `spawn_enemy` 直接锁定最近玩家，场上已有敌人也补锁；
## 狂暴形态 = `horde_berserk` ∧ 难度附加参数「尸潮狂暴」。
func _open_horde_window() -> void:
	var director: Node = get_node_or_null("/root/Director")
	if director == null or not director.has_method("set_external_horde_window"):
		return
	director.call("set_external_horde_window", true, horde_berserk)
	_window_opened = true
	print("[InfiniteHorde] 尸潮窗口开启（锁定追击，狂暴=%s）" % str(horde_berserk))


func _close_horde_window() -> void:
	if not _window_opened:
		return
	_window_opened = false
	var director: Node = get_node_or_null("/root/Director")
	if director != null and director.has_method("set_external_horde_window"):
		director.call("set_external_horde_window", false, false)


## 油桶容器装满后调用：提升数量倍率 / 缩短间隔。
func set_intensity(count_mult: float, interval_mult_value: float, broadcast: bool = true) -> void:
	count_multiplier = maxf(0.1, count_mult)
	interval_multiplier = clampf(interval_mult_value, 0.1, 5.0)
	intensity_changed.emit(count_multiplier, interval_multiplier)
	if broadcast and not _remote and _net_world != null \
			and _net_world.has_method("broadcast_infinite_horde_intensity"):
		_net_world.call("broadcast_infinite_horde_intensity", count_multiplier, interval_multiplier)


func is_active() -> bool:
	return _phase == Phase.ACTIVE


func _spawn_wave() -> void:
	var director: Node = get_node_or_null("/root/Director")
	if director == null:
		return
	var count: int = maxi(1, int(round(float(spawn_per_wave) * count_multiplier)))
	count = Players.scale_spawn_count(count)
	if max_active > 0:
		var alive: int = get_tree().get_nodes_in_group("enemy").size()
		count = mini(count, maxi(0, max_active - alive))
	if count <= 0:
		return
	var root: Node = MAP_SCENE_QUERY.get_map_root(get_tree())
	var decor: Node = root.find_child("DecorLayer", true, false) if root != null else null
	if decor == null:
		return
	## 固定点位优先：`spawn_horde_nodes_at_positions` 与防守战同源 ——
	## 内部会做「玩家画面内屏蔽」「落点可站性校验」「出生演出」，
	## 被屏蔽的点位自动退回屏幕外刷法，本批总数不会缺。
	if use_spawn_points and not _spawn_points.is_empty() \
			and director.has_method("spawn_horde_nodes_at_positions"):
		director.call("spawn_horde_nodes_at_positions", _spawn_points, count, decor, _wave_index)
		_wave_index += 1
		return
	director.call("spawn_horde_nodes", count, decor)


## 收集固定刷怪点（本节点子树优先、整张地图兜底）。开刷时调用一次。
## ⚠ 地图根可能取不到：`MapLocator.get_map_root()` 在 F6 / 工具场景 / 无会话宿主下
##   返回 null（`current_scene` 尚未装配）。此时退回 `current_scene` → `get_parent()`，
##   否则"点位摆在机器旁边"这种最常见摆法会被静默当成"没有点位"。
func _collect_spawn_points() -> void:
	_spawn_points = []
	if not use_spawn_points:
		return
	var tree: SceneTree = get_tree()
	var root: Node = MAP_SCENE_QUERY.get_map_root(tree)
	if root == null and tree != null:
		root = tree.current_scene
	if root == null:
		root = get_parent()
	_spawn_points = SPAWN_POINT.collect_points(self, root)
	if _spawn_points.is_empty():
		print("[InfiniteHorde] 未找到 HoldoutSpawnPoint，沿用屏幕外刷法")
	else:
		print("[InfiniteHorde] 使用 %d 个固定刷怪点（轮转均分）" % _spawn_points.size())


func _suspend_director_once() -> void:
	if not suspend_director or _suspended_director:
		return
	var director: Node = get_node_or_null("/root/Director")
	if director != null and director.has_method("set_director_suspended"):
		director.call("set_director_suspended", true)
		_suspended_director = true


func _exit_tree() -> void:
	## 换图 / 节点释放：先退尸潮窗口，再撤销导演挂起（顺序与开启相反）。
	_close_horde_window()
	if _suspended_director:
		var director: Node = get_node_or_null("/root/Director")
		if director != null and director.has_method("set_director_suspended"):
			director.call("set_director_suspended", false)


func _play_sound(stream: AudioStream) -> void:
	if stream == null:
		return
	Global.play_sfx_managed(stream, self)


func _drive_hud(phase: int, remaining: float, total: float) -> void:
	var hud: Node = HUD.find_in_scene(self)
	if hud == null:
		return
	if not _hud_shown:
		hud.call("show_holdout")
		_hud_shown = true
	hud.call("update_holdout", phase, remaining, total)
	if phase == Phase.ACTIVE and total <= 0.0:
		## 无限模式不显示数字（与防守战 EXTERNAL 同口径）
		pass


func _broadcast_state() -> void:
	if _net_world == null or not _net_world.has_method("broadcast_infinite_horde_state"):
		return
	_net_world.call("broadcast_infinite_horde_state", _phase, maxf(_timer, 0.0))


func _on_net_state(phase: int, remaining: float) -> void:
	if not _remote:
		return
	_phase = phase
	_timer = remaining
	if phase == Phase.PREPARE:
		_drive_hud(Phase.PREPARE, remaining, maxf(prepare_duration, remaining))
	elif phase == Phase.ACTIVE:
		if not _alert_played:
			_alert_played = true
			_play_sound(alert_sound)
		_drive_hud(Phase.ACTIVE, 0.0, 0.0)


func _on_net_intensity(count_mult: float, interval_mult_value: float) -> void:
	if _remote:
		set_intensity(count_mult, interval_mult_value, false)


func _is_client() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") \
		and bool(net.is_online_session()) and not bool(net.get("is_host"))


func _find_network_world() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.find_child("NetworkWorld", true, false)
