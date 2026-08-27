class_name ThrowableProjectile extends Node2D
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
		Global.play_sfx_managed(td.throw_sound, scene)


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
	if _td.fire_radius > 0:
		FirePatch.spawn(global_position, _td.fire_radius, _td.fire_duration, _td.damage, _td.fire_tick_interval, _td.fire_char_idx, _td.fire_ambient_sound, get_tree().current_scene, _authoritative, _damage_players)
	queue_free()


func _explode() -> void:
	var radius_px: float = _td.explosion_radius * TILE_SIZE + 16.0
	for e: Node in get_tree().get_nodes_in_group("enemy"):
		if e is Node2D and (e as Node2D).global_position.distance_to(global_position) <= radius_px:
			if (e as Node2D).has_method("take_damage"):
				var dir: Vector2 = (e as Node2D).global_position - global_position
				(e as Node2D).take_damage(_td.damage, 200.0, dir.normalized(), false, 0.3, 0.2, get_instance_id())
