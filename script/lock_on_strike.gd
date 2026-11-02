class_name LockOnStrike extends Node2D

## ── 架构定位 ──
## 系统：锁定打击（便携式地对空导弹）｜ 层：玩法（Node2D）
## 联机：Host 权威生成（伤害只在这边算）；Client 用 `setup_visual()` 复刻**纯表现**版本
##       （准星 + 延时爆炸特效，不产生伤害、不碰碰撞）
## 职责：发射瞬间锁定范围内敌人 → 在**锁定瞬间的位置**播准星行走图 → 延时到点逐个定点爆炸。
## 依赖：BulletData（全部参数）、WeaponData（射程回退）、object/bullet.tscn（爆炸结算复用）

## 【设计口径（2026-11-02 用户定稿）】
##   · 锁定半径以**玩家**为圆心，默认沿用武器 attack_range（320）；
##   · 最多同时锁定 5 个，**面朝方向优先**（扇形内先按距离取，不足再补扇形外最近的）；
##   · 图标用行走图 `スティンガーターゲット` 的角色格 0，按 0→1→2→1 踏步；
##   · 图标**钉在锁定瞬间的位置**（不跟随敌人），1 秒后就在图标处爆炸；
##   · 范围内一个目标都没有 → 由开火状态在进入攻击动画前拦下（不扣弹、播空弹音效）。
##
## 【为什么爆炸不写在这里】爆点结算完全复用 bullet.gd 的 `detonate_at()` ——
## 即死对 Boss 的降级、爆风外圈、自爆玩家、可爆破墙、爆炸特效/音效、章节统计
## 只有一份实现，锁定打击只是"不会飞的爆点"。

const WALK := preload("res://script/vx_walk_sheet.gd")
const BULLET_SCENE := preload("res://object/bullet.tscn")
const HitResolver := preload("res://script/hit_resolver.gd")

## 准星踏步帧序：VX Ace 行走图每格 3 帧（0=左踏 1=立 2=右踏），与角色行走同节奏。
const MARKER_STEP_FRAMES: Array[int] = [0, 1, 2, 1]
## 准星绘制层级：高于角色精灵（角色 z_index=1）与玩家名牌（30）之下不冲突，
## 取 20 与联机救援指示器同档 —— 只求"压在人物身上"，不抢 UI。
const MARKER_Z_INDEX: int = 20

var _bd: BulletData = null
var _wd: WeaponData = null
var _shooter: Node2D = null
var _damage: float = 0.0
var _instant_kill: bool = false
var _targets: Array[Node2D] = []

var _markers: Array[Sprite2D] = []
## 锁定瞬间的爆点快照（与图标同一坐标；图标素材缺失时爆炸点仍有效）。
var _points: Array[Vector2] = []
var _delay_left: float = 0.0
var _frame_idx: int = 0
var _frame_timer: float = 0.0
var _exploded: bool = false
## true = 联机 Client 的纯表现版本：只播准星与爆炸特效，不生成伤害弹。
var _visual_only: bool = false


## 由开火方调用（add_child 之前）。`targets` 已由 collect_targets() 在**开火帧**算好，
## 避免"预检有目标 → 发射帧重算又没了"的二次选取不一致。
func setup(bd: BulletData, wd: WeaponData, shooter: Node2D, damage: float,
		instant_kill: bool, targets: Array[Node2D]) -> void:
	_bd = bd
	_wd = wd
	_shooter = shooter
	_damage = damage
	_instant_kill = instant_kill
	_targets = targets
	_delay_left = maxf(bd.lock_on_delay, 0.0) if bd != null else 0.0
	_frame_timer = bd.lock_on_marker_frame_duration if bd != null else 0.12


## 联机 Client 用：Host 已确认锁定点坐标，本端只复刻表现（准星 + 延时爆炸特效）。
## **不产生任何伤害/碰撞** —— 伤害结算永远只在 Host。
func setup_visual(bd: BulletData, points: Array[Vector2]) -> void:
	_visual_only = true
	_bd = bd
	_points = points.duplicate()
	_delay_left = maxf(bd.lock_on_delay, 0.0) if bd != null else 0.0
	_frame_timer = bd.lock_on_marker_frame_duration if bd != null else 0.12


func _ready() -> void:
	if not _visual_only:
		_snapshot_targets()
	_spawn_markers()
	_play_beep()
	set_process(true)


func _process(delta: float) -> void:
	if _exploded:
		return
	_advance_marker_frames(delta)
	_delay_left -= delta
	if _delay_left <= 0.0:
		_detonate_all()


# ═══════════════════════════════════════
# 目标选取
# ═══════════════════════════════════════

## 取锁定目标：半径内、可受伤、未死亡；**面朝扇形内优先**（各自按距离升序），
## 不足上限时用扇形外的最近目标补齐。
## `cone_degrees` = 扇形总张角（度）；<=0 或朝向为零向量 → 纯最近优先。
## 返回顺序 = 实际锁定顺序（上限截断后）。
static func collect_targets(tree: SceneTree, origin: Vector2, facing: Vector2,
		radius: float, max_targets: int, cone_degrees: float) -> Array[Node2D]:
	var out: Array[Node2D] = []
	if tree == null or radius <= 0.0:
		return out
	var limit: int = maxi(1, max_targets)
	var half_cone: float = deg_to_rad(clampf(cone_degrees, 0.0, 360.0) * 0.5)
	var forward: Vector2 = facing.normalized() if facing != Vector2.ZERO else Vector2.ZERO
	var in_cone: Array[Dictionary] = []
	var outside: Array[Dictionary] = []

	for node: Node in HitResolver.damage_targets(tree):
		if node is not Node2D or not is_instance_valid(node):
			continue
		var entity := node as Node2D
		if entity.get("_is_dead") == true or entity.get("_is_dying") == true:
			continue
		if not entity.has_method("take_damage"):
			continue
		var dist: float = origin.distance_to(entity.global_position)
		if dist > radius:
			continue
		var entry: Dictionary = {"node": entity, "dist": dist}
		if forward != Vector2.ZERO and half_cone > 0.0:
			var to_target: Vector2 = entity.global_position - origin
			if to_target != Vector2.ZERO and absf(forward.angle_to(to_target)) <= half_cone:
				in_cone.append(entry)
				continue
		outside.append(entry)

	in_cone.sort_custom(_sort_by_distance)
	outside.sort_custom(_sort_by_distance)
	var ordered: Array[Dictionary] = []
	ordered.append_array(in_cone)
	ordered.append_array(outside)
	for i: int in range(mini(limit, ordered.size())):
		out.append(ordered[i]["node"] as Node2D)
	return out


static func _sort_by_distance(a: Dictionary, b: Dictionary) -> bool:
	return float(a["dist"]) < float(b["dist"])


# ═══════════════════════════════════════
# 准星图标
# ═══════════════════════════════════════

func _spawn_markers() -> void:
	if _bd == null:
		push_warning("[锁定打击] BulletData 为空，跳过")
		return
	var tex: Texture2D = _bd.lock_on_marker_texture
	if tex == null:
		push_warning("[锁定打击] 未配置 lock_on_marker_texture：仍会爆炸，但锁定点不显示图标")
	for point: Vector2 in _points:
		if tex == null:
			continue
		var spr := Sprite2D.new()
		spr.name = "LockMarker"
		spr.texture = tex
		spr.region_enabled = true
		spr.centered = true
		spr.z_index = MARKER_Z_INDEX
		spr.region_rect = WALK.region_rect(tex, _bd.lock_on_marker_char_index,
			_bd.lock_on_marker_facing, MARKER_STEP_FRAMES[0])
		add_child(spr)
		spr.global_position = point
		_markers.append(spr)


## 锁定瞬间快照：图标与爆点用同一坐标（用户口径：不跟随敌人）。
## 先快照再建显示节点 —— 即使图标素材没配，爆炸点也不会丢。
func _snapshot_targets() -> void:
	if _bd == null:
		return
	for target: Node2D in _targets:
		if not is_instance_valid(target):
			continue
		_points.append(_marker_center(target))


## 「嘀嘀嘀」锁定提示音：一次开火只播一次，按**第一个锁定点**定位（联机远端可听距离衰减）。
## 素材（ピピピピ 1.4s）比锁定窗口长时按比例提调，让最后一声正好落在爆炸点上。
func _play_beep() -> void:
	if _bd == null or _bd.lock_on_beep_sound == null:
		return
	var tree := get_tree()
	var scene: Node = tree.current_scene if tree else null
	if scene == null:
		return
	var at: Vector2 = _points[0] if not _points.is_empty() else global_position
	var pitch: float = 1.0
	var length: float = _bd.lock_on_beep_sound.get_length()
	if length > 0.0 and _bd.lock_on_delay > 0.05 and length > _bd.lock_on_delay:
		pitch = clampf(length / _bd.lock_on_delay, 1.0, 2.0)
	Global.play_sfx_managed(_bd.lock_on_beep_sound, scene, true, pitch, at)


## 准星落点 = 目标受击盒中心（敌人大都有 hurtbox_offset，默认 (0,-8)）——
## 也就是子弹实际命中的位置，不同体型的敌人都能压在身上；训练木偶之类没有该字段的
## 目标退回节点原点，再由 `lock_on_marker_offset` 微调。
func _marker_center(target: Node2D) -> Vector2:
	var center: Vector2 = target.global_position
	var hb: Variant = target.get("hurtbox_offset")
	if hb is Vector2:
		center += hb as Vector2
	return center + _bd.lock_on_marker_offset


func _advance_marker_frames(delta: float) -> void:
	if _bd == null or _bd.lock_on_marker_texture == null:
		return
	var dur: float = maxf(_bd.lock_on_marker_frame_duration, 0.01)
	_frame_timer -= delta
	while _frame_timer <= 0.0:
		_frame_timer += dur
		_frame_idx = (_frame_idx + 1) % MARKER_STEP_FRAMES.size()
		var rect: Rect2 = WALK.region_rect(_bd.lock_on_marker_texture,
			_bd.lock_on_marker_char_index, _bd.lock_on_marker_facing,
			MARKER_STEP_FRAMES[_frame_idx])
		for m: Sprite2D in _markers:
			if is_instance_valid(m):
				m.region_rect = rect


# ═══════════════════════════════════════
# 定点爆炸
# ═══════════════════════════════════════

func _detonate_all() -> void:
	_exploded = true
	if _visual_only:
		## Client：只播爆炸表现（与 Host 同一份 BulletData 的特效/音效）。
		for p: Vector2 in _points:
			_play_explosion_fx(p)
	else:
		for p: Vector2 in _points:
			_detonate_point(p)
	for m: Sprite2D in _markers:
		if is_instance_valid(m):
			m.queue_free()
	_markers.clear()
	_points.clear()
	queue_free()


## Client 的爆炸表现：特效 + 音效，不结算伤害（与 bullet.gd::_explode 的表现层同源数据）。
func _play_explosion_fx(point: Vector2) -> void:
	if _bd == null:
		return
	var tree := get_tree()
	var scene: Node = tree.current_scene if tree else null
	if scene == null:
		return
	if _bd.explode_effect_anim:
		VXAnimSprite.play_scene(_bd.explode_effect_anim, point, scene)
	if _bd.explode_sound:
		Global.play_sfx_managed(_bd.explode_sound, scene, true, 1.0, point)


## 在 `center` 引爆一发"不会飞的子弹"：参数由 BulletData 统一构建，
## 爆炸语义全部走 bullet.gd::_explode()（即死/外圈/自爆/墙体/特效/音效）。
func _detonate_point(center: Vector2) -> void:
	if _bd == null:
		return
	if not HitResolver.is_damage_authority():
		return
	var bullet: Node2D = BULLET_SCENE.instantiate()
	var params: Dictionary = _bd.build_setup_params(_wd, _damage, _instant_kill)
	params["direction"] = Vector2.DOWN
	params["shooter"] = _shooter
	## 只借用结算逻辑，不需要飞行外观（否则会在爆点闪一帧火箭贴图）。
	params["texture"] = null
	if bullet.has_method("setup"):
		bullet.setup(params)
	var host: Node = get_tree().current_scene if get_tree() else null
	if host == null:
		bullet.queue_free()
		return
	host.add_child(bullet)
	if bullet.has_method("detonate_at"):
		bullet.detonate_at(center)


## 测试 / 调试用：当前所有锁定点的世界坐标（= 图标位置 = 爆点）。
func get_marker_positions() -> Array[Vector2]:
	return _points.duplicate()
