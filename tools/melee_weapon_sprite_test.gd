extends Node2D

## 「武器单体动作图」运行时校验（人物与武器分开显示）。
## 用法：godot --headless --path . res://tools/melee_weapon_sprite_test.tscn --quit-after 400
##
## 做法：真实例化 player.tscn（autoload 齐全），在内存里改一份 WeaponData 副本
## （不动磁盘上的 tres），按**攻击序列步号**驱动后断言 weapon_sprite 的
## 可见性 / 帧区 / 层级。`facing` 是只读属性（只有 getter），所以直接写 `_facing`。

const PLAYER_SCENE := preload("res://object/player.tscn")
const BASE_WEAPON := "res://object/weapon_metal_bat.tres"
const SHEET := "res://art/WeaponAttack/金属バット/金属バット_attack1.png"

var _fail := 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _ready() -> void:
	await get_tree().process_frame

	var wd: WeaponData = (load(BASE_WEAPON) as WeaponData).duplicate()
	wd.melee_weapon_sprite = load(SHEET)
	wd.melee_weapon_sprite_seq_cols = {}      # 空表 → 按步序自动推
	wd.melee_weapon_sprite_force = true       # 金属球棒是「专用近战身体」，测试里强制打开
	# 金属球棒攻击序列 [2,3,4,1]：4 步

	var player: Node2D = PLAYER_SCENE.instantiate()
	add_child(player)
	await get_tree().process_frame

	print("=== 0) 节点是否建出来 ===")
	_check("weapon_sprite 已创建", player.weapon_sprite != null, true)
	_check("父节点", player.weapon_sprite.get_parent().name, "Sprite2D")

	print("=== 1) 普通行走模式 → 武器隐藏 ===")
	_check("visible", player.weapon_sprite.visible, false)

	print("=== 2) 举起（不在攻击序列里，步号 -1）→ 隐藏 ===")
	player.enter_weapon_mode(wd)
	await get_tree().process_frame
	_check("visible", player.weapon_sprite.visible, false)

	print("=== 3) 按攻击步号取列（4 步 → 前摇/挥动/挥动/后摇） ===")
	player._facing = 0                       # 下
	var seq: Array[int] = wd.get_melee_attack_char_sequence()
	for step: int in range(seq.size()):
		player.set_attack_char_index(seq[step], step)
		var want_col: int = 0 if step == 0 else (2 if step == seq.size() - 1 else 1)
		_check("第%d步 → 列%d" % [step + 1, want_col],
				int(player.weapon_sprite.region_rect.position.x / 212), want_col)
	_check("visible", player.weapon_sprite.visible, true)

	print("=== 4) 方向 → 行号；朝上画到身后 ===")
	for dir: int in [0, 1, 2, 3]:
		player._facing = dir
		player.set_attack_char_index(seq[1], 1)
		var r: Rect2 = player.weapon_sprite.region_rect
		_check("dir%d 行号" % dir, int(r.position.y / 148), dir)
	player._facing = 0
	player.set_attack_char_index(seq[1], 1)
	_check("朝下 z_index", player.weapon_sprite.z_index, 1)
	player._facing = 3
	player.set_attack_char_index(seq[1], 1)
	_check("朝上 z_index", player.weapon_sprite.z_index, -1)

	print("=== 5) 显式绑定表：未列出的步号 → 隐藏 ===")
	wd.melee_weapon_sprite_seq_cols = {1: 0, 2: 1, 3: 2}
	player._facing = 0
	player.set_attack_char_index(seq[0], 0)
	_check("第1步 未列出 visible", player.weapon_sprite.visible, false)
	player.set_attack_char_index(seq[1], 1)
	_check("第2步=动作图第1帧 visible", player.weapon_sprite.visible, true)
	_check("第2步 region_rect", player.weapon_sprite.region_rect, Rect2(0, 0, 212, 148))
	player.set_attack_char_index(seq[3], 3)
	_check("第4步 region_rect", player.weapon_sprite.region_rect, Rect2(424, 0, 212, 148))

	print("=== 6) 退出攻击（步号 -1）→ 隐藏 ===")
	player.set_attack_char_index(seq[1])
	_check("visible", player.weapon_sprite.visible, false)

	print("=== 7) 没有动作图的武器 → 隐藏（旧行为） ===")
	player.exit_weapon_mode()
	var plain: WeaponData = (load(BASE_WEAPON) as WeaponData).duplicate()
	player.enter_weapon_mode(plain)
	player.set_attack_char_index(seq[1], 1)
	_check("visible", player.weapon_sprite.visible, false)

	print("=== 8) 通用近战身体判定（文件名带 近战/近接 才默认叠） ===")
	var generic_gate: WeaponData = (load(BASE_WEAPON) as WeaponData).duplicate()
	generic_gate.melee_weapon_sprite = load(SHEET)
	_check("专用身体(金属バット) 不强制 → 不需要叠",
			generic_gate.is_generic_melee_body(generic_gate.weapon_walk_texture), false)
	generic_gate.weapon_walk_texture = load("res://art/Characters/のび太セット近战1.png")
	_check("通用身体(近战1) → 需要叠",
			generic_gate.is_generic_melee_body(generic_gate.weapon_walk_texture), true)
	generic_gate.weapon_walk_texture = load("res://art/Characters/のび太セット近接武器.png")
	_check("通用身体(近接武器) → 需要叠",
			generic_gate.is_generic_melee_body(generic_gate.weapon_walk_texture), true)

	print("=== 9) 专用身体 + 不强制 → 渲染层隐藏 ===")
	player.exit_weapon_mode()
	var dedicated: WeaponData = (load(BASE_WEAPON) as WeaponData).duplicate()
	dedicated.melee_weapon_sprite = load(SHEET)
	dedicated.melee_weapon_sprite_force = false
	player.enter_weapon_mode(dedicated)
	player.set_attack_char_index(dedicated.get_melee_attack_char_sequence()[1], 1)
	_check("visible", player.weapon_sprite.visible, false)

	print("=== 10) 专用身体 + 强制 → 显示 ===")
	dedicated.melee_weapon_sprite_force = true
	player.set_attack_char_index(dedicated.get_melee_attack_char_sequence()[1], 1)
	_check("visible", player.weapon_sprite.visible, true)

	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)
