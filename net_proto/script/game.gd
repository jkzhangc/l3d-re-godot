extends Node2D
## 游戏场景根 —— Host 权威世界 / 客户端纯渲染视图。
##
## Host：
##   - 玩家/敌人/子弹的生成、模拟、销毁全部发生在这里（或子实体节点上）
##   - 通过 MultiplayerSpawner.spawn(data) 广播生成事件
## Client：
##   - 只接收 spawn 广播（spawn_function 实例化）与同步器属性更新
##   - 上发输入（player.gd 的 RPC），不做任何世界模拟

const PLAYER_SCENE := preload("res://object/player.tscn")
const ENEMY_SCENE := preload("res://object/enemy.tscn")
const BULLET_SCENE := preload("res://object/bullet.tscn")

const ARENA_RECT := Rect2(-900.0, -550.0, 1800.0, 1100.0)
const ENEMY_SPAWN_INTERVAL := 4.0

@onready var entities: Node2D = $Entities
@onready var enemies: Node2D = $Enemies
@onready var bullets: Node2D = $Bullets
@onready var player_spawner: MultiplayerSpawner = $Entities/PlayerSpawner
@onready var enemy_spawner: MultiplayerSpawner = $Enemies/EnemySpawner
@onready var bullet_spawner: MultiplayerSpawner = $Bullets/BulletSpawner
@onready var camera: Camera2D = $Camera2D

var wave := 0
var kills := 0

var _enemy_counter := 0
var _enemy_spawn_timer := 2.0
var _auto_test := ""


func _ready() -> void:
	# 背景 64×64 拉伸铺满 3600×2200 竞技场
	$World/Ground.scale = Vector2(3600.0 / 64.0, 2200.0 / 64.0)
	player_spawner.spawn_function = _spawn_player_entity
	enemy_spawner.spawn_function = _spawn_enemy_entity
	bullet_spawner.spawn_function = _spawn_bullet_entity

	if Net.is_host:
		Net.peer_left.connect(_on_peer_left)
		# 只生成 Host 自己；其他玩家等各自 request_game_ready 再生成
		# （保证 spawn 广播在客户端进入场景、spawner 就绪之后才发出，避免丢失）
		_spawn_player_for(Net.my_peer_id)
	else:
		# 客户端：向 Host 报告就绪（Host 幂等处理）并请求快照
		if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
			# 无网络时仅用于无头自检（不会真正进入联机）
			print("[Game] 未连接网络，进入观察模式（仅无头自检）")
		else:
			request_game_ready.rpc_id(1)

	# 无头自动联机测试的诊断入口（-- --net-test=host/client）
	var user_args := OS.get_cmdline_user_args()
	if "--net-test=host" in user_args:
		_auto_test = "host"
	elif "--net-test=client" in user_args:
		_auto_test = "client"
	if not _auto_test.is_empty():
		_run_auto_test()


func _exit_tree() -> void:
	if Net.is_host:
		Net.peer_left.disconnect(_on_peer_left)


func _process(delta: float) -> void:
	# 相机跟随本地玩家（所有端各自跟随自己）
	var me := entities.get_node_or_null(str(Net.my_peer_id)) as Node2D
	if me:
		camera.global_position = me.global_position

	if not Net.is_host:
		return
	# ---- 仅 Host：世界模拟 ----
	_enemy_spawn_timer -= delta
	if _enemy_spawn_timer <= 0.0:
		_enemy_spawn_timer = ENEMY_SPAWN_INTERVAL
		_spawn_enemy()


# ---------------------------------------------------------------- spawn_function（两端执行）

func _spawn_player_entity(data: Variant) -> Node:
	var p: Node2D = PLAYER_SCENE.instantiate()
	p.name = str(data)
	return p


func _spawn_enemy_entity(data: Variant) -> Node:
	var e: Node2D = ENEMY_SCENE.instantiate()
	e.name = "E_%s" % str(data)
	return e


func _spawn_bullet_entity(data: Variant) -> Node:
	var b: Node2D = BULLET_SCENE.instantiate()
	if data is Dictionary:
		b.setup(
			data.get("origin", Vector2.ZERO),
			data.get("dir", Vector2.RIGHT),
			float(data.get("speed", 0.0)),
			int(data.get("owner", 1)),
		)
	return b


# ---------------------------------------------------------------- Host：生成 / 清理

func _spawn_player_for(peer_id: int) -> void:
	if not Net.is_host:
		return
	if entities.get_node_or_null(str(peer_id)) != null:
		return  # 幂等：中途加入的客户端可能重复请求
	player_spawner.spawn(peer_id)
	print("[Game] 已为 peer %d 生成玩家实体" % peer_id)


func _spawn_enemy() -> void:
	enemy_spawner.spawn(_enemy_counter)
	_enemy_counter += 1
	wave += 1


func _on_peer_left(peer_id: int) -> void:
	var p := entities.get_node_or_null(str(peer_id))
	if p:
		entities.remove_child(p)
		p.queue_free()
		print("[Game] 玩家 %d 掉线，删除实体" % peer_id)


## 玩家主动发起的子弹生成入口（player.gd 调用，仅 Host 生效）。
func add_bullet(origin: Vector2, dir: Vector2, speed: float, owner: int) -> void:
	if not Net.is_host:
		return
	bullet_spawner.spawn({
		"origin": origin,
		"dir": dir,
		"speed": speed,
		"owner": owner,
	})


## 敌人死亡入口（enemy.gd 调用，仅 Host 生效）。
func on_enemy_killed(e: Node2D) -> void:
	if not Net.is_host:
		return
	kills += 1
	enemies.remove_child(e)
	e.queue_free()


func arena_contains(pos: Vector2) -> bool:
	return ARENA_RECT.has_point(pos)


# ---------------------------------------------------------------- 无头自动联机测试

## 自动测试诊断：Host 先退（6s），Client 后退（8s），避免 Host 把掉线客户端的实体清掉。
func _run_auto_test() -> void:
	var delay := 8.0 if _auto_test == "client" else 6.0
	await get_tree().create_timer(delay).timeout
	if _auto_test == "client":
		var me := entities.get_node_or_null(str(Net.my_peer_id))
		var names: Array[String] = []
		for c in entities.get_children():
			names.append(str(c.name))
		print("[AUTO] client 诊断: my_peer_id=%d Entities=%s" % [Net.my_peer_id, names])
		if me == null:
			print("[AUTO] client FAIL: 自己的实体不存在（spawn_function / 同步链路未生效）")
			get_tree().quit(1)
			return
		print("[AUTO] client 诊断: 实体=%s hp=%s position=%s" % [me.name, me.get("hp"), me.position])
		print("[AUTO] client PASS")
		get_tree().quit(0)
	else:
		var players := entities.get_child_count()
		var enemy_count: int = enemies.get_child_count()
		var names: Array[String] = []
		for c in entities.get_children():
			names.append(str(c.name))
		print("[AUTO] host 诊断: Entities=%s(%d) Enemies=%d" % [names, players, enemy_count])
		var ok := players >= 2 and enemy_count >= 1
		print("[AUTO] host %s" % ("PASS" if ok else "FAIL"))
		get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- RPC

## 客户端 → Host：我进入游戏场景了，请确保已为我生成实体 + 发快照。
@rpc("any_peer", "call_remote", "reliable")
func request_game_ready() -> void:
	if not Net.is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	_spawn_player_for(sender)
	var snapshot := {
		"wave": wave,
		"kills": kills,
		"message": "欢迎，%s！当前波次 %d" % [Net.get_player_name(sender), wave],
	}
	receive_snapshot.rpc_id(sender, snapshot)
	print("[Game] 已向 peer %d 发送快照" % sender)


## Host → 指定客户端：加入快照。
@rpc("authority", "call_remote", "reliable")
func receive_snapshot(snapshot: Dictionary) -> void:
	wave = int(snapshot.get("wave", 0))
	kills = int(snapshot.get("kills", 0))
	var msg: String = str(snapshot.get("message", ""))
	if not msg.is_empty():
		announce_local(msg)


## Host → 所有端：系统消息（call_local 保证 Host 自己也能看到）。
@rpc("authority", "call_local", "reliable")
func announce(text: String) -> void:
	announce_local(text)


func announce_local(text: String) -> void:
	var hud := get_node_or_null("HUD")
	if hud:
		hud.show_message(text)
