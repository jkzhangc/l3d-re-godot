class_name ThrowableProjectile extends Node2D

## ── 架构定位 ──
## 系统：投掷投射物 ｜ 层：玩法（Node2D）
## 联机：authoritative 才结算
## 职责：投掷物抛物线与旋转表现，落地后爆炸（手雷）或生成火海（燃烧瓶）。
## 依赖：ThrowableData、FirePatch

## 投掷物投射物 — 抛物线飞向终点（带旋转），落地后爆炸（手雷）或生成火海（燃烧瓶）
## authoritative=true 才会执行落地爆炸/火海伤害；Client 镜像必须关闭权威逻辑，避免每台机器重复结算。
const FLY_DURATION: float = 0.5
const TILE_SIZE: int = 32
## 调试用爆炸范围环（TAB 打开 `Global.debug_visuals` 后才真的生成）。
## ⚠ 投掷物爆炸走**本文件**，枪械爆炸走 `bullet.gd` —— 两条独立路径，两边都要接，
## 否则"调试环只对手雷不显示"或反之。
const DEBUG_BLAST_RING := preload("res://script/debug_blast_ring.gd")
## 直线类投掷物（飞刀）的撞墙判据：与传送落点/刷怪点共用同一套图块碰撞解析。
const SPOT_RESOLVER := preload("res://script/director/spawn_spot_resolver.gd")

var _td: ThrowableData = null
var _start: Vector2 = Vector2.ZERO
var _end: Vector2 = Vector2.ZERO
var _t: float = 0.0
var _sprite: Sprite2D = null
var _shadow: Sprite2D = null
var _arc_height: float = 0.0   ## 抛物线最高点（像素）
var _spin_speed: float = 0.0    ## 旋转速度（弧度/秒）
var _authoritative: bool = true
var _damage_players: bool = true
var _source_owner: Node = null
## 只有确认来源是玩家时才置 true；未知/敌人来源一律 false，避免把敌方火海误判成友伤。
var _source_is_player_origin: bool = false
var _explosion_applied: bool = false
## 直击类（飞刀）：已命中的敌人 instance_id → 贯穿时不重复结算。
var _hit_ids: Dictionary = {}
## `_land()` 只允许执行一次（直击提前落地后，同帧不再跑终点分支）。
var _landed: bool = false
const HitResolver := preload("res://script/hit_resolver.gd")


static func spawn(td: ThrowableData, start: Vector2, end: Vector2, scene_context: Node, authoritative: bool = true, damage_players: bool = true, source_owner: Node = null) -> void:
	if not is_instance_valid(scene_context):
		return
	var tree := scene_context.get_tree()
	if tree == null or tree.current_scene == null:
		return
	var proj := ThrowableProjectile.new()
	proj._td = td
	proj._start = start
	proj._end = end
	proj._authoritative = authoritative
	proj._damage_players = damage_players
	proj._source_owner = source_owner if is_instance_valid(source_owner) else (scene_context if HitResolver.is_player(scene_context) else null)
	proj._source_is_player_origin = HitResolver.is_player(proj._source_owner) if is_instance_valid(proj._source_owner) else false
	var scene := tree.current_scene
	scene.add_child(proj)
	proj.global_position = start
	proj._setup_sprite()
	if td.throw_sound:
		## pitch 来自 ThrowableData.throw_sound_pitch（<=0 = 原调；手雷/炸药/燃烧瓶 tres 定 1.4）
		## 世界坐标定位（2026-10-20）：投掷音随距离衰减，声源=投掷起点。
		Global.play_sfx_managed(td.throw_sound, scene, true, maxf(td.throw_sound_pitch, 0.01), start)


func _setup_sprite() -> void:
	_sprite = Sprite2D.new()
	_sprite.z_index = 3
	_arc_height = _td.arc_height if _td else 0.0
	_spin_speed = _td.spin_speed if _td else 0.0
	var tex: Texture2D = _td.projectile_texture if _td.projectile_texture else _td.icon
	if tex:
		_sprite.texture = tex
		# 地面阴影（同纹理，压扁 + 半透明，落在直线地面位置）
		_shadow = Sprite2D.new()
		_shadow.z_index = 2
		_shadow.texture = tex
		_shadow.modulate = Color(0.0, 0.0, 0.0, 0.35)
		_shadow.scale = Vector2(1.0, 0.5)
		add_child(_shadow)
	add_child(_sprite)


func _process(delta: float) -> void:
	if _landed:
		return
	_t += delta
	var k: float = clampf(_t / FLY_DURATION, 0.0, 1.0)
	var from: Vector2 = global_position
	global_position = _start.lerp(_end, k)
	# 抛物线：屏幕空间高度弧线（起点/终点为 0，中点最高）
	if _sprite:
		var height: float = sin(k * PI) * _arc_height
		_sprite.position.y = -height
		_sprite.rotation += _spin_speed * delta
		# 阴影随高度缩小变淡
		if _shadow:
			var hf: float = clampf(1.0 - height / (_arc_height + 1.0), 0.4, 1.0)
			_shadow.scale = Vector2(hf, hf * 0.5)
			_shadow.modulate.a = 0.35 * hf
	## ★直击类（飞刀，2026-10-27）：沿途命中 / 撞墙即停。
	## 判定在**所有端**都跑 —— Host/单机结算伤害，Client 只靠它停在同一个位置。
	if _td != null and _td.direct_hit_radius > 0.0:
		if _direct_hit_step(from, global_position):
			return
	if k >= 1.0:
		_land()


# ═══════════════════════════════════════
# 直击（飞刀 / direct_hit_radius > 0 的投掷物）
# ═══════════════════════════════════════

## 一帧的直击判定。返回 true = 本次已经落地（调用方不要再跑终点落地）。
## 抛物线类（手雷/燃烧瓶）`direct_hit_radius = 0`，根本不会进这里。
func _direct_hit_step(from: Vector2, to: Vector2) -> bool:
	if _td.direct_hit_stop_on_wall and _crosses_wall(from, to):
		global_position = from
		_land()
		return true
	var hit: Node2D = _nearest_enemy_on_segment(from, to)
	while hit != null:
		_hit_ids[hit.get_instance_id()] = true
		if _authoritative:
			_apply_direct_hit(hit, from, to)
		if not _td.direct_hit_pierce:
			## 单体：停在命中的敌人身上（视觉上也"扎进去"），随后消失。
			global_position = hit.global_position
			_land()
			return true
		hit = _nearest_enemy_on_segment(from, to)
	return false


## 命中伤害：与爆炸同源（`damage` / `element`），但**不是爆炸** ——
## 末位 source_is_explosive=false，不会打断 Tank 的霸体、也不触发爆炸类特效。
func _apply_direct_hit(target: Node2D, from: Vector2, to: Vector2) -> void:
	if not target.has_method("take_damage"):
		return
	var dir: Vector2 = to - from
	if dir.length_squared() < 0.0001:
		dir = Vector2.DOWN
	target.call("take_damage", _td.damage, 120.0, dir.normalized(), false, 0.2, 0.1,
		get_instance_id(), _td.element, false)


## 线段的圆判定：返回**离起点最近**的未命中敌人（贯穿时逐个消费）。
## 用线段而不是点：最高速（8 格 / 0.5s ≈ 512px/s）每帧位移约 8.5px，点判定在
## 低帧率下会漏掉擦身而过的敌人。
func _nearest_enemy_on_segment(from: Vector2, to: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d: float = INF
	## 目标组走 HitResolver.damage_targets：真敌人 + 训练木偶（木偶不在 "enemy" 组里）。
	for n: Node in HitResolver.damage_targets(get_tree()):
		if not (n is Node2D) or not is_instance_valid(n):
			continue
		## `enemy` 组历史上也包含玩家（见 item_manager 的注释）→ 必须排除；
		## `is_removed` 覆盖 `_is_dead` / `_is_dying`（尸体与濒死都不该再吃直击）。
		if HitResolver.is_player(n) or HitResolver.is_removed(n):
			continue
		var e: Node2D = n as Node2D
		if _hit_ids.has(e.get_instance_id()):
			continue
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(e.global_position, from, to)
		if closest.distance_to(e.global_position) > _td.direct_hit_radius:
			continue
		var d: float = from.distance_to(closest)
		if d < best_d:
			best = e
			best_d = d
	return best


## 撞墙：只查**图块碰撞**（房间墙/家具都由图块表达；节点式门另有自己的碰撞，不在此列）。
## 逐 8px 采样 —— 飞行每帧位移 ≤ ~9px，不会跨过一整格(32px)漏判。
func _crosses_wall(from: Vector2, to: Vector2) -> bool:
	var anchor: Node2D = get_tree().current_scene as Node2D
	if anchor == null or not is_instance_valid(anchor):
		return false
	var distance: float = from.distance_to(to)
	if distance < 0.01:
		return false
	var steps: int = maxi(1, int(ceil(distance / 8.0)))
	for i: int in range(1, steps + 1):
		var p: Vector2 = from.lerp(to, float(i) / float(steps))
		if SPOT_RESOLVER.is_tile_blocked(anchor, p):
			return true
	return false



func _land() -> void:
	if _landed:
		return
	_landed = true
	if _td.explode_sound:
		## 世界坐标定位（2026-10-20）：爆炸音随距离衰减，声源=落点。
		## 播放器挂场景而非本节点 —— 投掷物随后释放，挂自身会被一起回收掐断声音。
		Global.play_sfx_managed(_td.explode_sound, get_tree().current_scene, true, 1.0, global_position)
	if _td.explode_effect_anim:
		VXAnimSprite.play_scene(_td.explode_effect_anim, global_position, get_tree().current_scene)
	## ★调试可视化（2026-10-01 用户需求）：把这一炸的实际范围画出来并停留 2 秒。
	## 半径按 play 侧同一公式换算（`格 × 32 + 16`），两端都画（`_land` 在所有端都会跑）。
	if _td.explosion_radius > 0:
		DEBUG_BLAST_RING.show_ring(global_position,
			float(_td.explosion_radius) * float(TILE_SIZE) + 16.0, get_tree().current_scene)
	if _authoritative and _td.explosion_radius > 0:
		_explode()
	if _authoritative and _td.flash_radius > 0:
		_apply_flash()
	if _td.fire_radius > 0:
		## ★灼烧属性跟随投掷物（2026-10-27）：此前 FirePatch 写死 FIRE，酸瓶的火海也会把敌人点燃。
		## element=0（旧数据未配属性）回退 FIRE，保持燃烧瓶既有表现。
		var fire_element: int = _td.element if _td.element != WeaponData.Element.NONE else WeaponData.Element.FIRE
		FirePatch.spawn(global_position, _td.fire_radius, _td.fire_duration, _td.damage, _td.fire_tick_interval, _td.fire_char_idx, _td.fire_ambient_sound, get_tree().current_scene, _authoritative, _damage_players, _source_owner, false, _td.fire_light_extra_px, _td.fire_light_intensity, _td.fire_light_color, _td.fire_light_flicker, _td.fire_ember_amount,
			{"scale": _td.fire_shadow_scale, "range": _td.fire_shadow_range, "opacity": _td.fire_shadow_opacity}, fire_element)
	queue_free()


## 闪光弹：范围内敌人 0 伤害长硬直（怯み/致盲）；夜间视界短暂照亮；玩家白屏。
## 表现（白屏/照亮）在所有端都播——闪光不看阵营，豁免自己没有意义。
func _apply_flash() -> void:
	var radius_px: float = _td.flash_radius * TILE_SIZE + 16.0
	for e: Node in get_tree().get_nodes_in_group("enemy"):
		if e is Node2D and (e as Node2D).global_position.distance_to(global_position) <= radius_px:
			if (e as Node2D).has_method("take_damage"):
				var dir: Vector2 = (e as Node2D).global_position - global_position
				# 0 伤害 + 长硬直：走 take_damage 的 hitstun 通道（雷/氷同款），source_id=0 跳过去重
				(e as Node2D).take_damage(0.0, 0.0, dir.normalized(), false, 0.0, _td.flash_stun_duration)
	var overlay := NightOverlay.find_any(self)
	if overlay:
		overlay.flash(_td.flash_light_duration)
	if _td.flash_screen_duration > 0.0:
		_screen_white_flash(_td.flash_screen_duration)


func _screen_white_flash(duration: float) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 96   ## 黑幕(90)之上、ED名单(95)同层带
	var rect := ColorRect.new()
	rect.color = Color(1, 1, 1, 0.9)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	get_tree().current_scene.add_child(layer)
	var tw := rect.create_tween()
	tw.tween_property(rect, "color:a", 0.0, duration)
	tw.tween_callback(layer.queue_free)


func _explode() -> void:
	var radius_px: float = _td.explosion_radius * TILE_SIZE + 16.0
	## 目标组 = 真敌人 + 训练木偶（见 HitResolver.DAMAGE_TARGET_GROUPS）。
	for e: Node in HitResolver.damage_targets(get_tree()):
		if e is Node2D and (e as Node2D).global_position.distance_to(global_position) <= radius_px:
			if (e as Node2D).has_method("take_damage"):
				var dir: Vector2 = (e as Node2D).global_position - global_position
				## 2026-10-30 爆炸震慑：击退 420 + 位移结束后 2s 硬直（统一常量）。
				## 末位 true = 爆炸家族：Tank 也会被投掷物爆炸击退/硬直（用户定稿：只有爆炸类可打断）
				(e as Node2D).take_damage(_td.damage,
					HitResolver.EXPLOSION_KNOCKBACK_FORCE, dir.normalized(), false,
					HitResolver.EXPLOSION_KNOCKBACK_STUN, HitResolver.EXPLOSION_HITSTUN_SEC,
					get_instance_id(), _td.element, true)
	## 可爆破墙体（blast_wall）：只有 breaks_blast_wall=true 的投掷物（炸药）计入破坏；
	## 手雷等炸得响但炸不开（2026-09-16 用户定稿）。
	## 只有 Host/单机的授权爆炸会走到这里（_authoritative 前提），Client 只看 flag 广播的表现。
	for w: Node in get_tree().get_nodes_in_group("blast_wall"):
		if w is Node2D and (w as Node2D).has_method("apply_explosion"):
			(w as Node2D).call("apply_explosion", global_position, radius_px, _td.breaks_blast_wall)
