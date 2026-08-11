extends Node2D
## 子弹实体 —— 纯 Host 模拟；客户端只接收生成广播（生成后无需再同步状态）。
## 客户端副本完全不模拟，纯等 3 秒超时或边界删除（由 Host 广播 despawn）。

const BODY_DAMAGE := 15.0
const LIFETIME := 3.0
const ARENA_RECT := Rect2(-900.0, -550.0, 1800.0, 1100.0)

# 避免依赖全局类名缓存（无 .godot 时 class_name 不可解析）
const NetVisuals := preload("res://script/net/visuals.gd")

var velocity := Vector2.ZERO
var owner_id := 1

var _time := 0.0


## Host 生成时（spawn_function）设置初始参数 —— 两端都会执行。
func setup(origin: Vector2, dir: Vector2, speed: float, owner: int) -> void:
	position = origin
	velocity = dir * speed
	owner_id = owner
	$Sprite.texture = NetVisuals.square_texture(Color(0.95, 0.90, 0.35), 10)


func _physics_process(delta: float) -> void:
	if not Net.is_host:
		return  # 客户端副本不模拟
	position += velocity * delta
	_time += delta
	var game := get_tree().current_scene
	if _time > LIFETIME or not game.arena_contains(global_position):
		_despawn()
		return
	var hit := _hit_enemy()
	if hit:
		hit.take_damage(BODY_DAMAGE)
		_despawn()


func _hit_enemy() -> Node:
	var game := get_tree().current_scene
	if game == null:
		return null
	var enemies := game.get_node_or_null("Enemies")
	if enemies == null:
		return null
	for e in enemies.get_children():
		if not e.has_method("is_alive") or not e.is_alive():
			continue
		if global_position.distance_to(e.global_position) <= 30.0:
			return e
	return null


func _despawn() -> void:
	var parent := get_parent()
	if parent:
		parent.remove_child(self)  # 触发 spawner 广播 despawn
	queue_free()
