extends Node2D

## 哆啦A梦 / 空气炮 / 空手拳击 / 武器锁定 的运行时校验（2026-11-17）。
## 用法：godot --headless --path . res://tools/fists_and_air_cannon_check.tscn
##
## 做法：真实例化 player.tscn（autoload 齐全），用 `Input.action_press` 模拟按键，
## 走**单机状态机的真实输入链路**（不是直接调状态函数），因此能验到：
##   · 空槽位按 1/2 是否真的举拳（而不是静默无反应）；
##   · 空气炮弹夹容量 0 时能否正常发射（旧实现会判「空响」直接 return）；
##   · 武器锁定角色按 E 丢武器是否真的无副作用；
##   · HUD 空槽位是否显示占位图标。

const PLAYER_SCENE := preload("res://object/player.tscn")
const HUD_SCENE := preload("res://scene/ui/combat_hud.tscn")
const DORA_PATH := "res://object/character_doraemon.tres"
const FISTS_PATH := "res://object/player_fists.tres"

var _fail: int = 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


## 模拟一次「真实按键边沿」。
## ⚠ 不能用 `Input.action_press()`：它不产生 `is_action_just_pressed` 的边沿
## （实测按下后 just_pressed 恒 false，状态机读不到），必须喂 InputEventAction。
func _press(action: String) -> void:
	var down := InputEventAction.new()
	down.action = action
	down.pressed = true
	Input.parse_input_event(down)
	await get_tree().process_frame
	await get_tree().process_frame
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame


func _ready() -> void:
	await get_tree().process_frame

	var dora: CharacterData = load(DORA_PATH)
	var fists: WeaponData = load(FISTS_PATH)
	_check("角色资源", dora != null, true)
	_check("拳套资源", fists != null, true)
	if dora == null or fists == null:
		get_tree().quit(1)
		return

	## ── 座位与实体 ──
	Players.clear_seats()
	var st: PlayerState = PlayerState.new()
	st.init_from_character(dora.duplicate() as CharacterData)
	Players.add_seat(st)
	Players.set_active_seat(0)
	_check("出生武器 = 空气炮", st.get_equipped_weapon("primary") != null
		and st.get_equipped_weapon("primary").item_id == "air_cannon", true)
	_check("副格为空", st.get_equipped_weapon("secondary"), null)

	var player: Node2D = PLAYER_SCENE.instantiate()
	add_child(player)
	await get_tree().process_frame
	var sm: StateMachine = player.get_node("StateMachine")
	_check("初始状态", sm.current_state_name(), "Idle")
	_check("角色已绑定", player.current_character.character_id, "doraemon")

	print("=== 1) 冒烟：装备槽为空 → 派生拳套 ===")
	st.active_weapon_slot = "secondary"
	_check("空槽 active_weapon = 拳", st.get_active_weapon().item_id, "fists")
	_check("空槽 equipped 仍为 null", st.get_equipped_weapon("secondary"), null)
	_check("拳路由状态", st.get_active_weapon().get_state_node_name(), "Melee")
	st.active_weapon_slot = "primary"
	_check("主格 active_weapon = 空气炮", st.get_active_weapon().item_id, "air_cannon")

	print("=== 2) 空槽位按 2 → 举拳（真实输入链路） ===")
	await _press("副武器键")
	_check("状态切到 Melee", sm.current_state_name(), "Melee")
	_check("激活槽 = secondary", st.active_weapon_slot, "secondary")
	_check("手里是拳", player.is_weapon_mode_active() and player._weapon_data != null
		and player._weapon_data.item_id == "fists", true)
	_check("拳击行走图来自角色数据", player.sprite.texture == dora.fist_walk_texture, true)

	print("=== 3) 拳击攻击链路 ===")
	## 举拳动画（1 帧 0.1s）没走完时确定键会被忽略，先等它进 READY。
	await get_tree().create_timer(0.25).timeout
	await _press("确定键")
	_check("状态切到 MeleeAttack", sm.current_state_name(), "MeleeAttack")
	## 拳套攻击序列 [4,5,5] 共 0.14+0.09+0.17 = 0.40s，留足余量再断言回位。
	await get_tree().create_timer(0.8).timeout
	_check("攻击后回到 Melee", sm.current_state_name(), "Melee")

	print("=== 4) 同槽位再按 2 → 放下拳，回到空手 ===")
	await _press("副武器键")
	await get_tree().create_timer(0.3).timeout
	_check("状态回到 Idle", sm.current_state_name(), "Idle")

	print("=== 5) 按 1 → 举空气炮 ===")
	await _press("主武器键")
	_check("状态切到 Ranged", sm.current_state_name(), "Ranged")
	_check("手里是空气炮", player._weapon_data != null
		and player._weapon_data.item_id == "air_cannon", true)
	await get_tree().create_timer(0.3).timeout

	print("=== 6) 空气炮开火：无弹夹也要出弹、且不扣弹 ===")
	var before_bullets: int = _count_bullets()
	await _press("确定键")
	await get_tree().create_timer(0.35).timeout
	var after_bullets: int = _count_bullets()
	_check("子弹已生成", after_bullets > before_bullets, true)
	_check("弹夹记录仍为 0（无弹夹武器）", st.get_magazine_ammo("air_cannon"), 0)
	_check("没有误进 Reload 状态", sm.current_state_name() == "Ranged"
		or sm.current_state_name() == "RangedAttack", true)

	print("=== 7) 武器锁定：按 E 丢武器应完全无副作用 ===")
	player.request_drop_all_weapons()
	await get_tree().process_frame
	_check("空气炮仍在主格", st.get_equipped_weapon("primary") != null
		and st.get_equipped_weapon("primary").item_id == "air_cannon", true)
	_check("地上没有掉落物", _count_weapon_pickups(), 0)

	print("=== 8) HUD：有武器显示图标、空格显示占位图 ===")
	var hud: CanvasLayer = HUD_SCENE.instantiate()
	add_child(hud)
	await get_tree().process_frame
	await get_tree().process_frame
	var primary_icon: TextureRect = hud.get_node_or_null("PrimaryWeaponIcon")
	var secondary_icon: TextureRect = hud.get_node_or_null("SecondaryWeaponIcon")
	_check("HUD 主图标 = 空气炮图标", primary_icon != null
		and primary_icon.texture == st.get_equipped_weapon("primary").icon, true)
	_check("HUD 主图标可见", primary_icon != null and primary_icon.visible, true)
	_check("HUD 空槽图标可见", secondary_icon != null and secondary_icon.visible, true)
	_check("HUD 空槽用的是装備アイコン", secondary_icon != null
		and secondary_icon.texture == load("res://art/Ui/装備アイコン.png"), true)

	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)


func _count_bullets() -> int:
	var n: int = 0
	for child: Node in get_children():
		if child.name.begins_with("Bullet"):
			n += 1
	return n


func _count_weapon_pickups() -> int:
	var n: int = 0
	for child: Node in get_children():
		if child.name.begins_with("WeaponPickup"):
			n += 1
	return n
