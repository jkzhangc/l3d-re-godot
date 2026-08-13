class_name ThrowableProjectile extends Node2D
## 投掷物投射物 — 直线飞向终点，落地后爆炸（手雷）或生成火海（燃烧瓶）

const FLY_DURATION: float = 0.5
const TILE_SIZE: int = 32

var _td: ThrowableData = null
var _start: Vector2 = Vector2.ZERO
var _end: Vector2 = Vector2.ZERO
var _t: float = 0.0
var _sprite: Sprite2D = null


static func spawn(td: ThrowableData, start: Vector2, end: Vector2, thrower: Node2D) -> void:
	var proj := ThrowableProjectile.new()
	proj._td = td
	proj._start = start
	proj._end = end
	var scene := thrower.get_tree().current_scene
	scene.add_child(proj)
	proj.global_position = start
	proj._setup_sprite()
	if td.throw_sound:
		Global.play_sfx_managed(td.throw_sound, scene)


func _setup_sprite() -> void:
	_sprite = Sprite2D.new()
	_sprite.z_index = 3
	var tex: Texture2D = _td.projectile_texture if _td.projectile_texture else _td.icon
	if tex:
		_sprite.texture = tex
	add_child(_sprite)


func _process(delta: float) -> void:
	_t += delta
	var k: float = clampf(_t / FLY_DURATION, 0.0, 1.0)
	global_position = _start.lerp(_end, k)
	if k >= 1.0:
		_land()


func _land() -> void:
	if _td.explode_sound:
		Global.play_sfx_managed(_td.explode_sound, get_tree().current_scene)
	if _td.explosion_radius > 0:
		_explode()
	if _td.fire_radius > 0:
		FirePatch.spawn(global_position, _td.fire_radius, _td.fire_duration, _td.damage, get_tree().current_scene)
	queue_free()


func _explode() -> void:
	var radius_px: float = _td.explosion_radius * TILE_SIZE + 16.0
	for e: Node in get_tree().get_nodes_in_group("enemy"):
		if e is Node2D and (e as Node2D).global_position.distance_to(global_position) <= radius_px:
			if (e as Node2D).has_method("take_damage"):
				var dir: Vector2 = (e as Node2D).global_position - global_position
				(e as Node2D).take_damage(_td.damage, 200.0, dir.normalized(), false, 0.3, 0.2, get_instance_id())
