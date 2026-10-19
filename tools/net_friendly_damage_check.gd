extends Node

## 友伤行为回归：真实 Player.take_damage + 真实 Net 房间设置 + 真实玩家节点。
## 入口：godot --headless --path <项目目录> res://tools/net_friendly_damage_check.tscn
## 不加载地图、不连接公网、不写存档或配置；临时房间使用随机本机 UDP 端口。
const PlayerScene := preload("res://object/player.tscn")
const HitResolver := preload("res://script/hit_resolver.gd")
const TEST_MAX_HP := 100.0
const WEAPON_DAMAGE := 30.0
const FRIENDLY_SAMPLES := 60

var _total: int = 0
var _failures: int = 0
var _net: Node = null
var _attacker: CharacterBody2D = null
var _target: CharacterBody2D = null
var _enemy_source: Node2D = null
var _finished: bool = false


func _ready() -> void:
	_net = get_node_or_null("/root/Net")
	if _net == null:
		printerr("NET_FRIENDLY_DAMAGE_CHECK FAIL 缺少 Net 自动加载")
		get_tree().quit(1)
		return
	call_deferred("_run")


func _process(_delta: float) -> void:
	pass


func _check(ok: bool, label: String) -> void:
	_total += 1
	if not ok:
		_failures += 1
	print("NET_FRIENDLY_DAMAGE_CHECK %s %s" % ["PASS" if ok else "FAIL", label])


func _spawn_player(pos: Vector2) -> CharacterBody2D:
	var player := PlayerScene.instantiate() as CharacterBody2D
	# 联机实体：跳过单机座位注册，避免与 active_seat 绑定。
	player.network_controlled = true
	player.global_position = pos
	add_child(player)
	return player


func _reset_hp() -> void:
	_target.max_hp = TEST_MAX_HP
	_target.current_hp = TEST_MAX_HP
	_target._is_dying = false


func _apply_damage(source: Node, origin: bool = false, amount: float = WEAPON_DAMAGE) -> float:
	var before: float = _target.current_hp
	_target.take_damage(amount, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0, 0, false, source, origin)
	return before - _target.current_hp


func _run() -> void:
	var err: Error = _net.host_game(0)
	_check(err == OK and bool(_net.is_online_session()), "真实 host_game(0) 建立联机会话")

	_attacker = _spawn_player(Vector2.ZERO)
	_target = _spawn_player(Vector2(64.0, 0.0))
	_enemy_source = Node2D.new()
	_enemy_source.name = "EnemySource"
	add_child(_enemy_source)
	await get_tree().process_frame
	await get_tree().process_frame

	_check(_attacker != null and _target != null and _target.is_in_group("player"), "真实玩家节点已就绪并属于 player 组")

	# ── 纯判定矩阵 ───────────────────────────────────────────────
	_check(HitResolver.resolve_player_damage_for_mode(WEAPON_DAMAGE, _attacker, _target, true, false, true) < 0.0,
		"联机关闭友伤：玩家来源命中判定为无效")
	_check(is_equal_approx(HitResolver.resolve_player_damage_for_mode(WEAPON_DAMAGE, _enemy_source, _target, true, false, false), WEAPON_DAMAGE),
		"联机关闭友伤：敌人来源仍按原伤害")
	_check(is_equal_approx(HitResolver.resolve_player_damage_for_mode(WEAPON_DAMAGE, _target, _target, true, false, true), WEAPON_DAMAGE),
		"联机关闭友伤：自伤仍按原伤害")
	_check(is_equal_approx(HitResolver.resolve_player_damage_for_mode(WEAPON_DAMAGE, null, _target, true, false, false), WEAPON_DAMAGE),
		"无来源（非玩家来源）不会被误判成友伤")

	# ── 关闭友伤：真实 take_damage 不扣血 ─────────────────────────
	_reset_hp()
	var delta_off: float = _apply_damage(_attacker, true)
	_check(is_zero_approx(delta_off), "关闭友伤：队友攻击真实入口不扣血")
	_reset_hp()
	var delta_off_freed: float = _apply_damage(null, true)
	_check(is_zero_approx(delta_off_freed), "关闭友伤：来源已释放时仍按玩家来源拦截")
	_check(bool(_net.set_host_friendly_fire_enabled(true)), "房主可开启友伤")

	# ── 开启友伤：每次有效命中只扣 1~2 ───────────────────────────
	_check(bool(_net.friendly_fire_enabled), "开启后房间状态为 true")
	var minimum := 999.0
	var maximum := -1.0
	var all_in_range := true
	for _i: int in range(FRIENDLY_SAMPLES):
		_reset_hp()
		var delta: float = _apply_damage(_attacker, true)
		minimum = minf(minimum, delta)
		maximum = maxf(maximum, delta)
		if delta < 1.0 or delta > 2.0:
			all_in_range = false
	_check(all_in_range, "开启友伤：%d 次真实结算全部落在 1~2 点" % FRIENDLY_SAMPLES)
	_check(is_equal_approx(minimum, 1.0) and is_equal_approx(maximum, 2.0),
		"开启友伤：1 与 2 都会出现（实测 %.0f~%.0f）" % [minimum, maximum])

	_reset_hp()
	var delta_enemy: float = _apply_damage(_enemy_source, false)
	_check(is_equal_approx(delta_enemy, WEAPON_DAMAGE), "开启友伤：敌人伤害仍为原值 30")
	_reset_hp()
	var delta_self: float = _apply_damage(_target, true)
	_check(is_equal_approx(delta_self, WEAPON_DAMAGE), "开启友伤：自伤仍按原值 30（不套用友伤 1~2）")

	# 友伤命中不应附带击退/Heat/削り：仅看 HP 变化已覆盖；这里再确认不会触发火焰元素。
	_reset_hp()
	_target.take_damage(WEAPON_DAMAGE, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0,
		WeaponData.Element.FIRE, true, _attacker, true)
	_check(_target.current_hp >= TEST_MAX_HP - 2.0 and _target._burning_time <= 0.0,
		"开启友伤：火焰/Heat 不会把 1~2 点放大或附加灼烧")

	# ── Client 无伤害权威 ────────────────────────────────────────
	_net.is_host = false
	_reset_hp()
	var delta_client: float = _apply_damage(_enemy_source, false)
	_check(is_zero_approx(delta_client), "Client 侧 take_damage 不结算权威伤害")
	_net.is_host = true

	# ── 离房默认关闭 ─────────────────────────────────────────────
	_net.leave()
	_check(not bool(_net.friendly_fire_enabled), "离房后房间友伤恢复关闭")

	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	for node: Node in [_attacker, _target, _enemy_source]:
		if is_instance_valid(node):
			node.queue_free()
	print("NET_FRIENDLY_DAMAGE_CHECK total=%d passed=%d failed=%d" % [
		_total, _total - _failures, _failures])
	get_tree().quit(1 if _failures > 0 else 0)
