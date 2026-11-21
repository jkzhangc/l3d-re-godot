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
	_play_sound(alert_sound)
	_drive_hud(Phase.ACTIVE, 0.0, 0.0)
	_suspend_director_once()
	_spawn_wave()
	_broadcast_state()
	horde_started.emit()


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
	director.call("spawn_horde_nodes", count, decor)


func _suspend_director_once() -> void:
	if not suspend_director or _suspended_director:
		return
	var director: Node = get_node_or_null("/root/Director")
	if director != null and director.has_method("set_director_suspended"):
		director.call("set_director_suspended", true)
		_suspended_director = true


func _exit_tree() -> void:
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
