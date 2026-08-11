extends Node2D
## 敌人实体 —— 纯 Host 模拟；客户端不生成，只接收生成广播 + position/hp/alive 同步。

const SPEED := 110.0
const ATTACK_RANGE := 42.0
const ATTACK_COOLDOWN := 1.0
const ATTACK_DAMAGE := 10.0
const BODY_DAMAGE := 15.0
const ARENA_RECT := Rect2(-900.0, -550.0, 1800.0, 1100.0)

# 避免依赖全局类名缓存（无 .godot 时 class_name 不可解析）
const NetVisuals := preload("res://script/net/visuals.gd")

var hp := 50.0
var alive := true

var _attack_cd := 0.0


func _ready() -> void:
	position = Vector2(randf_range(-800.0, 800.0), randf_range(-480.0, 480.0))
	$Sprite.texture = NetVisuals.square_texture(Color(0.72, 0.30, 0.55), 26)
	_setup_synchronizer()


func _process(delta: float) -> void:
	# 表现层：倒地隐藏（存活由 Host 同步）
	visible = alive
	if not Net.is_host or not alive:
		return
	# ---- 仅 Host：追击 / 攻击（位置由同步器高频广播）----
	var target := _nearest_player()
	if target == null:
		return
	position += (target.global_position - global_position).normalized() * SPEED * delta
	position = position.clamp(ARENA_RECT.position, ARENA_RECT.end)
	_attack_cd -= delta
	if _attack_cd <= 0.0 and global_position.distance_to(target.global_position) <= ATTACK_RANGE:
		_attack_cd = ATTACK_COOLDOWN
		target.take_damage(ATTACK_DAMAGE, self)


func is_alive() -> bool:
	return alive


## 被子弹命中（仅 Host 的子弹会调用）。
func take_damage(dmg: float) -> void:
	if not alive:
		return
	hp -= dmg
	if hp <= 0.0:
		hp = 0.0
		alive = false
		var game := get_tree().current_scene
		if game and game.has_method("on_enemy_killed"):
			game.on_enemy_killed(self)


func _nearest_player() -> Node:
	var game := get_tree().current_scene
	if game == null:
		return null
	var entities := game.get_node_or_null("Entities")
	if entities == null:
		return null
	var best: Node = null
	var best_d := INF
	for p in entities.get_children():
		if p is Node2D and p.get("alive") == true:
			var d := global_position.distance_squared_to((p as Node2D).global_position)
			if d < best_d:
				best_d = d
				best = p
	return best


func _setup_synchronizer() -> void:
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Sync"
	add_child(sync)
	var cfg := SceneReplicationConfig.new()
	# 位置：ALWAYS（unreliable 高频）
	cfg.add_property(NodePath("^position"))
	cfg.property_set_replication_mode(
		NodePath("^position"),
		SceneReplicationConfig.ReplicationMode.REPLICATION_MODE_ALWAYS
	)
	cfg.property_set_spawn(NodePath("^position"), true)
	# HP / 存活：ON_CHANGE（reliable）
	cfg.add_property(NodePath("^hp"))
	cfg.property_set_replication_mode(
		NodePath("^hp"),
		SceneReplicationConfig.ReplicationMode.REPLICATION_MODE_ON_CHANGE
	)
	cfg.property_set_spawn(NodePath("^hp"), true)
	cfg.add_property(NodePath("^alive"))
	cfg.property_set_replication_mode(
		NodePath("^alive"),
		SceneReplicationConfig.ReplicationMode.REPLICATION_MODE_ON_CHANGE
	)
	cfg.property_set_spawn(NodePath("^alive"), true)
	sync.replication_config = cfg
