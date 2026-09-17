extends Node2D
## 僵尸变体 + 尸潮狂暴 —— headless 验证 harness。
##
## 用法："$GD" --headless --path <项目> res://tools/zombie_variant_test.tscn
##
## 覆盖：
##   ① spawn_enemy 按池注入变体（贴图/速度/伤害）
##   ② set_rage(true) → クリムゾンヘッド图 + 加速加攻 + 狂暴叫声
##   ③ set_rage(false) → 恢复普通形态与数值
##   ④ 无狂暴图的外观（中年ゾンビ）set_rage(true) 是 no-op
##   ⑤ 权重 0 的变体不会被选中
##   ⑥ 尸潮：_set_all_enemies_rage 全场切换 / 期间刷出的敌人直接狂暴 / 结束恢复
##   ⑦ 空池 → 经典敌人（enemy.tscn 默认贴图）不被改动

const ENEMY_SCENE := preload("res://object/enemy.tscn")
const PLAYER_SCENE := preload("res://object/player.tscn")
const V_ZHOKUIN := preload("res://tres/zombies/職員ゾンビ.tres")
const V_CHUNEN := preload("res://tres/zombies/中年ゾンビ.tres")
const V_MALE := preload("res://tres/zombies/男性ゾンビ.tres")

var _checks: int = 0
var _fails: int = 0
var _decor: Node2D = null
var _player: CharacterBody2D = null


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("[PASS] %s" % label)
	else:
		_fails += 1
		print("[FAIL] %s" % label)


func _ready() -> void:
	# Director.spawn_enemy 需要一个名字含 "decor" 的挂载点
	_decor = Node2D.new()
	_decor.name = "DecorLayer"
	add_child(_decor)
	_player = PLAYER_SCENE.instantiate() as CharacterBody2D
	add_child(_player)
	_player.global_position = Vector2(0, 0)
	var sm: Node = _player.get_node_or_null("StateMachine")
	if sm:
		sm.set_physics_process(false)
		sm.set_process(false)
	for i in range(5):
		await get_tree().physics_frame

	_test_variant_injection()
	_test_rage_toggle()
	_test_no_rage_variant()
	_test_weight_zero()
	_test_horde_rage()
	_test_empty_pool_classic()

	print("=== ZOMBIE_VARIANT_TEST: %d/%d checks passed ===" % [_checks - _fails, _checks])
	get_tree().quit(0 if _fails == 0 else 1)


func _spawn() -> CharacterBody2D:
	return Director.spawn_enemy(Vector2(200, 200), _decor) as CharacterBody2D


func _test_variant_injection() -> void:
	Director._zombie_pool = [V_ZHOKUIN]
	var e: CharacterBody2D = _spawn()
	_check(e != null, "池注入：spawn_enemy 成功生成")
	if e == null:
		return
	_check(e.walk_texture == V_ZHOKUIN.normal_texture,
		"池注入：行走图 = 变体普通图（%s）" % e.walk_texture.resource_path.get_file())
	_check(is_equal_approx(e.move_speed, V_ZHOKUIN.move_speed),
		"池注入：移动速度 = %.0f" % e.move_speed)
	_check(is_equal_approx(e.attack_damage, V_ZHOKUIN.attack_damage),
		"池注入：攻击伤害 = %.0f" % e.attack_damage)
	_check(not e.is_rage(), "池注入：初始为普通形态")
	e.free()


func _test_rage_toggle() -> void:
	Director._zombie_pool = [V_ZHOKUIN]
	var e: CharacterBody2D = _spawn()
	if e == null:
		return
	e.set_rage(true)
	_check(e.is_rage(), "狂暴：is_rage() = true")
	_check(e.walk_texture == V_ZHOKUIN.rage_texture,
		"狂暴：行走图切换为クリムゾンヘッド（%s）" % e.walk_texture.resource_path.get_file())
	_check(is_equal_approx(e.move_speed, V_ZHOKUIN.rage_move_speed),
		"狂暴：速度 %.0f → %.0f" % [V_ZHOKUIN.move_speed, e.move_speed])
	_check(is_equal_approx(e.attack_damage, V_ZHOKUIN.rage_attack_damage),
		"狂暴：伤害 %.0f → %.0f" % [V_ZHOKUIN.attack_damage, e.attack_damage])
	_check(e.get_discover_sound() == V_ZHOKUIN.rage_discover_sound,
		"狂暴：发现音效 = 狂暴叫声（クリム_叫び）")
	e.set_rage(false)
	_check(not e.is_rage(), "解除狂暴：is_rage() = false")
	_check(e.walk_texture == V_ZHOKUIN.normal_texture, "解除狂暴：行走图恢复普通")
	_check(is_equal_approx(e.move_speed, V_ZHOKUIN.move_speed), "解除狂暴：速度恢复")
	_check(is_equal_approx(e.attack_damage, V_ZHOKUIN.attack_damage), "解除狂暴：伤害恢复")
	e.free()


func _test_no_rage_variant() -> void:
	Director._zombie_pool = [V_CHUNEN]
	var e: CharacterBody2D = _spawn()
	if e == null:
		return
	_check(e.variant_rage_texture == null, "无狂暴形态：中年ゾンビ rage_texture = null")
	var before: Texture2D = e.walk_texture
	e.set_rage(true)
	_check(not e.is_rage(), "无狂暴形态：set_rage(true) 不进入狂暴")
	_check(e.walk_texture == before, "无狂暴形态：行走图不变")
	e.free()


func _test_weight_zero() -> void:
	var zero: Resource = V_ZHOKUIN.duplicate()
	zero.weight = 0.0
	Director._zombie_pool = [zero, V_MALE]
	var hits_zero: int = 0
	for i in range(60):
		var v: Resource = Director._pick_zombie_variant()
		if v == zero:
			hits_zero += 1
	_check(hits_zero == 0, "权重 0 的变体 60 次抽样中 0 次被选中（其余全部落到男性ゾンビ）")


func _test_horde_rage() -> void:
	## 注意：池子里选种是随机的 —— 要断言「谁狂暴、谁不狂暴」，必须先固定每个实体的变体，
	## 否则 e1 抽到中年ゾンビ时这条用例会随机失败（曾实际发生）。
	Director._zombie_pool = [V_ZHOKUIN]   ## e1：会狂暴的職員
	var e1: CharacterBody2D = _spawn()
	Director._zombie_pool = [V_CHUNEN]    ## e2：无狂暴形态的中年
	var e2: CharacterBody2D = _spawn()
	if e1 == null or e2 == null:
		return
	_check(e1.variant_rage_texture != null, "尸潮前置：職員ゾンビ 有狂暴图")
	_check(e2.variant_rage_texture == null, "尸潮前置：中年ゾンビ 无狂暴图")

	Director._set_all_enemies_rage(true)
	_check(e1.is_rage(), "尸潮开启：職員ゾンビ 进入狂暴")
	_check(not e2.is_rage(), "尸潮开启：中年ゾンビ（无狂暴形态）保持普通")

	## 尸潮期间刷出的敌人直接以狂暴登场
	Director._horde_rage = true
	Director._zombie_pool = [V_ZHOKUIN]
	var e3: CharacterBody2D = _spawn()
	_check(e3 != null and e3.is_rage(), "尸潮期间刷出的敌人直接狂暴")

	Director._set_all_enemies_rage(false)
	Director._horde_rage = false
	_check(not e1.is_rage(), "尸潮结束：職員ゾンビ 恢复普通")
	_check(not e3.is_rage(), "尸潮结束：狂暴登场的敌人也恢复普通")
	_check(e1.walk_texture == V_ZHOKUIN.normal_texture, "尸潮结束：行走图恢复普通")
	for e: Node in [e1, e2, e3]:
		if e is Node:
			(e as Node).free()


func _test_empty_pool_classic() -> void:
	Director._zombie_pool = []
	var e: CharacterBody2D = _spawn()
	if e == null:
		return
	_check(e.walk_texture.resource_path.ends_with("男性ゾンビ1.png"),
		"空池：经典敌人不被改动（默认 男性ゾンビ1）")
	e.free()
