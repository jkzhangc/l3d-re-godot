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


static func spawn(td: ThrowableData, start: Vector2, end: Vector2, scene_context: Node, authoritative: bool = true, damage_players: bool = true) -> void:
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
	var scene := tree.current_scene
	scene.add_child(proj)
	proj.global_position = start
	proj._setup_sprite()
	if td.throw_sound:
		## pitch 来自 ThrowableData.throw_sound_pitch（<=0 = 原调；手雷/炸药/燃烧瓶 tres 定 1.4）
		Global.play_sfx_managed(td.throw_sound, scene, false, maxf(td.throw_sound_pitch, 0.01))


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
	_t += delta
	var k: float = clampf(_t / FLY_DURATION, 0.0, 1.0)
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
	if k >= 1.0:
		_land()


func _land() -> void:
	if _td.explode_sound:
		Global.play_sfx_managed(_td.explode_sound, get_tree().current_scene)
	if _td.explode_effect_anim:
		VXAnimSprite.play_scene(_td.explode_effect_anim, global_position, get_tree().current_scene)
	if _authoritative and _td.explosion_radius > 0:
		_explode()
	if _authoritative and _td.flash_radius > 0:
		_apply_flash()
	if _td.fire_radius > 0:
		FirePatch.spawn(global_position, _td.fire_radius, _td.fire_duration, _td.damage, _td.fire_tick_interval, _td.fire_char_idx, _td.fire_ambient_sound, get_tree().current_scene, _authoritative, _damage_players)
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
	var overlay := NightOverlay.find_in_scene(get_tree().current_scene)
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
	for e: Node in get_tree().get_nodes_in_group("enemy"):
		if e is Node2D and (e as Node2D).global_position.distance_to(global_position) <= radius_px:
			if (e as Node2D).has_method("take_damage"):
				var dir: Vector2 = (e as Node2D).global_position - global_position
				(e as Node2D).take_damage(_td.damage, 200.0, dir.normalized(), false, 0.3, 0.2, get_instance_id(), _td.element)
	## 可爆破墙体（blast_wall）：只有 breaks_blast_wall=true 的投掷物（炸药）计入破坏；
	## 手雷等炸得响但炸不开（2026-09-16 用户定稿）。
	## 只有 Host/单机的授权爆炸会走到这里（_authoritative 前提），Client 只看 flag 广播的表现。
	for w: Node in get_tree().get_nodes_in_group("blast_wall"):
		if w is Node2D and (w as Node2D).has_method("apply_explosion"):
			(w as Node2D).call("apply_explosion", global_position, radius_px, _td.breaks_blast_wall)
