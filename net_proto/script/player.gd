extends Node2D
## 玩家实体 —— Host 权威模拟；客户端只上报输入 + 渲染同步结果。
##
## 关键约定（联机系统架构设计.md）：
##   - 节点名 = peer_id（Entities/<peer_id>）
##   - position / hp / alive 通过 MultiplayerSynchronizer 从 Host 同步
##   - 客户端对本实体无任何写权限（移动只在 Host 端发生）

const SPEED := 240.0
const FIRE_COOLDOWN := 0.25
const BULLET_SPEED := 520.0
const BULLET_SCENE := preload("res://object/bullet.tscn")
const ARENA_RECT := Rect2(-900.0, -550.0, 1800.0, 1100.0)

# 避免依赖全局类名缓存（无 .godot 时 class_name 不可解析）
const NetVisuals := preload("res://script/net/visuals.gd")

const PLAYER_COLORS := [
	Color(0.25, 0.85, 0.35),  # 绿 = Host
	Color(0.30, 0.55, 0.95),  # 蓝
	Color(0.92, 0.35, 0.30),  # 红
	Color(0.92, 0.78, 0.25),  # 黄
]

var peer_id := 1
var hp := 100.0
var alive := true

# Host 权威状态（由输入驱动 / 由客户端 RPC 驱动）
var input_dir := Vector2.ZERO
var firing := false
var fire_cd := 0.0

var _prev_firing := false
var _prev_alive := true

@onready var _sprite: Sprite2D = $Sprite


func _ready() -> void:
	peer_id = int(name)
	_sprite.texture = NetVisuals.square_texture(
		PLAYER_COLORS[(peer_id - 1) % PLAYER_COLORS.size()], 28
	)
	_setup_synchronizer()


func _process(delta: float) -> void:
	# 表现层：存活时显示 / 倒地隐藏（alive 由 Host 同步）
	if alive != _prev_alive:
		visible = alive
		_prev_alive = alive
	if Net.is_host:
		_simulate(delta)
	else:
		_send_local_input()


# ---------------------------------------------------------------- Host 分支：唯一的世界模拟

func _simulate(delta: float) -> void:
	if not alive:
		return
	# Host 自己的玩家：直接读本地输入（零延迟）
	if peer_id == Net.my_peer_id:
		input_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
		firing = Input.is_action_pressed("fire")
	# 移动（Host 权威，客户端副本只接收 position 同步）
	position += input_dir * SPEED * delta
	position = position.clamp(ARENA_RECT.position, ARENA_RECT.end)
	# 开火（冷却由 Host 统一控制，天然免疫连点作弊）
	fire_cd -= delta
	if firing and fire_cd <= 0.0:
		_try_fire()


# ---------------------------------------------------------------- 客户端分支：只上报输入

func _send_local_input() -> void:
	if peer_id != Net.my_peer_id or not alive:
		return

	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return  # 无网络（无头自检）时不上报输入
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var is_firing := Input.is_action_pressed("fire")
	submit_input.rpc_id(1, dir, is_firing)
	# 按下的瞬间额外发一次可靠开火请求（移动输入是 unreliable，事件必须可靠）
	if is_firing and not _prev_firing:
		fire_request.rpc_id(1)
	_prev_firing = is_firing


# ---------------------------------------------------------------- RPC（客户端 → Host）

## 客户端 → Host：移动/开火状态（高频，unreliable）。
@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_input(dir: Vector2, is_firing: bool) -> void:
	if not Net.is_host:
		return
	input_dir = dir
	firing = is_firing


## 客户端 → Host：开火请求（低频，reliable）。
@rpc("any_peer", "call_remote", "reliable")
func fire_request() -> void:
	if not Net.is_host:
		return
	_try_fire()


# ---------------------------------------------------------------- Host：战斗

func _try_fire() -> void:
	if not alive or fire_cd > 0.0:
		return
	fire_cd = FIRE_COOLDOWN
	var game := get_tree().current_scene
	if game == null or not game.has_method("add_bullet"):
		return
	game.add_bullet(global_position, _aim_dir(), BULLET_SPEED, peer_id)


## Host 计算开火方向：向最近存活敌人射击；无敌人时沿移动方向。
func _aim_dir() -> Vector2:
	var dir := input_dir
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	var best: Node = null
	var best_d := INF
	var enemies_node := _enemies_node()
	if enemies_node:
		for e in enemies_node.get_children():
			if not e.has_method("is_alive") or not e.is_alive():
				continue
			var d := global_position.distance_squared_to(e.global_position)
			if d < best_d:
				best_d = d
				best = e
	if best:
		dir = (best.global_position - global_position).normalized()
	return dir.normalized()


func _enemies_node() -> Node2D:
	var game := get_tree().current_scene
	if game == null:
		return null
	return game.get_node_or_null("Enemies") as Node2D


## 被敌人攻击（仅 Host 的敌人 AI 会调用，因此只会发生在 Host）。
func take_damage(dmg: float, _source) -> void:
	if not alive:
		return
	hp -= dmg
	if hp <= 0.0:
		hp = 0.0
		alive = false
		_die()


func _die() -> void:
	var game := get_tree().current_scene
	if game and game.has_method("announce"):
		game.announce.rpc("%s 倒下了！" % Net.get_player_name(peer_id))
	# 3 秒后自动复活（Host 定时逻辑）
	var t := get_tree().create_timer(3.0)
	t.timeout.connect(_respawn)


func _respawn() -> void:
	if alive:
		return
	alive = true
	hp = 100.0
	position = Vector2(randf_range(-500.0, 500.0), randf_range(-350.0, 350.0))
	var game := get_tree().current_scene
	if game and game.has_method("announce"):
		game.announce.rpc("%s 复活了！" % Net.get_player_name(peer_id))


# ---------------------------------------------------------------- 同步配置

func _setup_synchronizer() -> void:
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Sync"
	add_child(sync)
	var cfg := SceneReplicationConfig.new()
	# 位置：ALWAYS（unreliable 高频，每帧）
	cfg.add_property(NodePath("^position"))
	cfg.property_set_replication_mode(
		NodePath("^position"),
		SceneReplicationConfig.ReplicationMode.REPLICATION_MODE_ALWAYS
	)
	cfg.property_set_spawn(NodePath("^position"), true)
	# HP / 存活：ON_CHANGE（reliable，变化时）
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
