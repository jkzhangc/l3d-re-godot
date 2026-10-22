extends Node

## ── 架构定位 ──
## 系统：防守战 ｜ 层：玩法（Node，一次性演出器，挂在被生成的敌人身上）
## 联机：仅单机 / Host 播放；Client 的镜像实体靠快照插值跟随（不需要也不允许本地播放）
## 职责：把一只刚生成的敌人从出生点搬到落点（跳 / 坠落），演出期间冻结其 AI，落地僵直结束后交还。
## 依赖：enemy 的 StateMachine 子节点、`update_facing_from_direction()`、`_is_dead`；
##       Global.play_sfx_managed（音效）

## 【设计要点】
## 1) 「冻结」= 关掉 `StateMachine` 与敌人自身的 `_process/_physics_process`。
##    状态机是独立子节点、有自己的 `_process/_physics_process`，只关敌人本体不够。
##    冻结期间敌人**仍然可被攻击**（HurtArea 不在冻结范围），这是有意的：
##    登场表演不该变成无敌帧。
## 2) 位移用**直接写 global_position**，不走 move_and_slide —— 跳跃要能越过墙体/缝隙，
##    物理位移会被墙挡住。落点已由 Director 过 SpawnSpotResolver 验证为可站格。
## 3) 演出中被击杀：立刻落到落点并解冻，避免尸体冻在半空。
## 4) 结束即 `queue_free()`：本节点只活一次，不留常驻开销。

## 与 `holdout_spawn_point.gd::EntryMode` 一一对应（走 Dictionary 协议，不共享类型）
const MODE_NONE: int = 0
const MODE_JUMP: int = 1
const MODE_DROP: int = 2

const PHASE_FLY: int = 0    ## 飞行中
const PHASE_HOLD: int = 1   ## 落地僵直

## ── 配置（由 configure() 在 add_child 之前写入）──
var mode: int = MODE_NONE
var to: Vector2 = Vector2.ZERO       ## 落点（全局坐标，已解析为可站格）
var duration: float = 0.6
var arc_height: float = 48.0
var land_hold: float = 0.25
var start_sound: AudioStream = null
var land_sound: AudioStream = null

# ── 运行时 ──
var _enemy: Node2D = null
var _body: CharacterBody2D = null
var _state_machine: Node = null
var _start: Vector2 = Vector2.ZERO
var _elapsed: float = 0.0
var _hold_left: float = 0.0
var _phase: int = PHASE_FLY
var _finished: bool = false
var _enemy_process_was_on: bool = true
var _enemy_physics_was_on: bool = true
var _sm_process_was_on: bool = true
var _sm_physics_was_on: bool = true


## 写入演出配置。必须在 `add_child()` **之前**调用（`_ready` 立刻开始播放）。
## cfg 字段：mode / to / duration / arc_height / land_hold / sound / land_sound
func configure(cfg: Dictionary) -> void:
	mode = int(cfg.get("mode", MODE_NONE))
	to = cfg.get("to", Vector2.ZERO) if cfg.get("to", Vector2.ZERO) is Vector2 else Vector2.ZERO
	duration = maxf(float(cfg.get("duration", 0.6)), 0.02)
	arc_height = maxf(float(cfg.get("arc_height", 48.0)), 0.0)
	land_hold = maxf(float(cfg.get("land_hold", 0.25)), 0.0)
	var s: Variant = cfg.get("sound", null)
	start_sound = s as AudioStream
	var ls: Variant = cfg.get("land_sound", null)
	land_sound = ls as AudioStream


func _ready() -> void:
	_enemy = get_parent() as Node2D
	if _enemy == null or not is_instance_valid(_enemy) or mode == MODE_NONE:
		queue_free()
		return
	_body = _enemy as CharacterBody2D
	_start = _enemy.global_position
	_freeze()
	## 演出期间朝向移动方向（俯视角下"扑/跳过来"比背对玩家更像演出）
	if _enemy.has_method("update_facing_from_direction"):
		var dir: Vector2 = to - _start
		if dir.length() > 1.0:
			_enemy.update_facing_from_direction(dir)
	_play_sound(start_sound)
	_apply_progress(0.0)


func _process(delta: float) -> void:
	if _enemy == null or not is_instance_valid(_enemy):
		queue_free()
		return
	if _is_enemy_dead():
		## 演出中被击杀：落地 + 解冻，让死亡流程照常跑
		_finish(true)
		return
	match _phase:
		PHASE_FLY:
			_elapsed += delta
			var k: float = _elapsed / duration
			_apply_progress(k)
			if k >= 1.0:
				_land()
		PHASE_HOLD:
			_hold_left -= delta
			if _hold_left <= 0.0:
				_finish(false)


# ═══════════════════════════════════════
# 位移
# ═══════════════════════════════════════

## k ∈ [0,1] → 敌人的屏幕坐标。公式与 `holdout_spawn_point.gd::_draw_entry_preview` 同源。
func _apply_progress(k: float) -> void:
	var t: float = clampf(k, 0.0, 1.0)
	match mode:
		MODE_JUMP:
			## 两端贴地、中点最高（负 y = 屏幕上方）
			var base: Vector2 = _start.lerp(to, t)
			_enemy.global_position = base + Vector2(0.0, -arc_height * sin(PI * t))
		MODE_DROP:
			## 从落点正上方的空中垂直坠落，末段加速
			_enemy.global_position = Vector2(to.x, lerpf(to.y - arc_height, to.y, t * t))
		_:
			_enemy.global_position = to


func _land() -> void:
	_elapsed = 0.0
	_enemy.global_position = to
	_play_sound(land_sound)
	if land_hold > 0.0:
		_phase = PHASE_HOLD
		_hold_left = land_hold
	else:
		_finish(false)


# ═══════════════════════════════════════
# 冻结 / 解冻
# ═══════════════════════════════════════

func _freeze() -> void:
	_state_machine = _enemy.get_node_or_null("StateMachine")
	if _state_machine != null:
		_sm_process_was_on = _state_machine.is_processing()
		_sm_physics_was_on = _state_machine.is_physics_processing()
		_state_machine.set_process(false)
		_state_machine.set_physics_process(false)
	_enemy_process_was_on = _enemy.is_processing()
	_enemy_physics_was_on = _enemy.is_physics_processing()
	_enemy.set_process(false)
	_enemy.set_physics_process(false)
	if _body != null:
		_body.velocity = Vector2.ZERO


## `snap` = 演出被打断（敌人已死）：同样落点后再解冻，不留悬空尸体。
func _finish(snap: bool) -> void:
	if _finished:
		return
	_finished = true
	if _enemy != null and is_instance_valid(_enemy):
		_enemy.global_position = to
		if _state_machine != null and is_instance_valid(_state_machine):
			_state_machine.set_process(_sm_process_was_on)
			_state_machine.set_physics_process(_sm_physics_was_on)
		_enemy.set_process(_enemy_process_was_on)
		_enemy.set_physics_process(_enemy_physics_was_on)
		if snap and _body != null:
			_body.velocity = Vector2.ZERO
	queue_free()


# ═══════════════════════════════════════
# 工具
# ═══════════════════════════════════════

## 只读敌人身上的 `_is_dead`（敌人脚本的私有状态，避免为演出单独开公开 API）。
func _is_enemy_dead() -> bool:
	var dead: Variant = _enemy.get("_is_dead")
	return dead == true


func _play_sound(stream: AudioStream) -> void:
	if stream == null:
		return
	var g: Node = get_node_or_null("/root/Global")
	if g == null or not g.has_method("play_sfx_managed"):
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	g.play_sfx_managed(stream, tree.current_scene)
