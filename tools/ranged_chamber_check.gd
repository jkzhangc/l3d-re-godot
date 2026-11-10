extends Node2D

## ── 用例：上膛子弹不能被「削り」吞掉（2026-11-10 用户实测）──
## 现象：换完弹按开火，动画中途被酸 / Heat 攻击命中 → 弹夹被扣（削り 每次 -2），
##       开火帧看到弹夹为 0 就静默 return：子弹没出来、弹夹却少了 = 「攻击被吞」。
##       1 发弹夹的榴弹炮 / 火箭筒必踩（-2 直接清零），所以用户觉得"榴弹炮更容易触发"。
##
## 修法：开火动作**开始时**记一份弹数快照（`_ammo_at_attack_start`）；
##       开火帧弹夹为 0 但快照 > 0 → 这一发已上膛，照常发射（不再扣弹）。
##
## 附：削り 的**反馈**（2026-11-10 用户需求）—— 扣弹夹 / 扣耐久 / 武器损坏都要飘字，
##     否则玩家只会看到弹夹莫名变少，误以为是攻击被吞。
##
## 运行：godot --headless --path . res://tools/ranged_chamber_check.tscn

const PLAYER_SCENE := preload("res://object/player.tscn")
const LAUNCHER := preload("res://object/weapon_grenade_launcher.tres")

var _fail: int = 0


func _check(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("  OK   %s%s" % [label, "" if detail.is_empty() else "（%s）" % detail])
		return
	_fail += 1
	print("  FAIL %s%s" % [label, "" if detail.is_empty() else "（%s）" % detail])


func _ready() -> void:
	print("=== RANGED_CHAMBER_CHECK（削り 不再吞掉已上膛的一发）===")
	await get_tree().process_frame

	var player: CharacterBody2D = PLAYER_SCENE.instantiate()
	add_child(player)
	for i in range(3):
		await get_tree().process_frame

	var state: PlayerState = Players.get_state_for_entity(player)
	_check("玩家实体拿到 PlayerState", state != null)
	if state == null:
		_finish()
		return

	## 用 1 发弹夹的榴弹炮：削り -2 一定清零，最容易复现用户的现象。
	state.equip_weapon_in_slot(LAUNCHER, "secondary")
	state.switch_to_slot("secondary")
	state.set_magazine_ammo(LAUNCHER.item_id, 1)
	_check("当前武器 = 榴弹炮", state.get_active_weapon() == LAUNCHER)
	_check("弹夹 = 1", state.get_magazine_ammo(LAUNCHER.item_id) == 1)

	var sm: Node = player.get_node_or_null("StateMachine")
	_check("状态机存在", sm != null)
	if sm == null:
		_finish()
		return

	sm.call("request_state", "RangedAttack")
	for i in range(2):
		await get_tree().process_frame
	var atk: Node = sm.get("current_state")
	_check("进入远程攻击状态", atk != null and String(atk.name) == "RangedAttack",
		"" if atk == null else String(atk.name))
	if atk == null:
		_finish()
		return

	## ① 正常：动作开始时 1 发，开火帧还有 1 发 → 发射 + 扣到 0
	var before: int = _count_bullets()
	atk.call("_fire_bullet")
	_check("正常开火：子弹生成", _count_bullets() == before + 1)
	_check("正常开火：弹夹扣到 0", state.get_magazine_ammo(LAUNCHER.item_id) == 0)

	## ② 被削り 清空：动作开始时 1 发，开火帧已被扣到 0 → 仍要发射（这一发已上膛）
	state.set_magazine_ammo(LAUNCHER.item_id, 1)
	atk.set("_ammo_at_attack_start", 1)          ## 模拟「按下开火时弹夹里有 1 发」
	state.set_magazine_ammo(LAUNCHER.item_id, 0)  ## 模拟削り 在动画中途清零
	before = _count_bullets()
	atk.call("_fire_bullet")
	_check("★削り 清空后仍发射（不再被吞）", _count_bullets() == before + 1)
	_check("发射后弹夹不出现负数", state.get_magazine_ammo(LAUNCHER.item_id) == 0)

	## ③ 开火前就是空的：动作开始时快照 0 → 不发射（空枪照旧）
	atk.set("_ammo_at_attack_start", 0)
	before = _count_bullets()
	atk.call("_fire_bullet")
	_check("动作开始时就没弹 → 不发空枪", _count_bullets() == before)

	## ④ 削り 反馈：酸攻击命中要飘「弹夹 -N」，弹夹已空则不飘
	state.set_magazine_ammo(LAUNCHER.item_id, 3)
	var hints_before: int = _count_hint("弹夹")
	player.take_damage(3.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 0, WeaponData.Element.ACID)
	_check("酸攻击确实削掉弹夹（3 → 1）", state.get_magazine_ammo(LAUNCHER.item_id) == 1)
	_check("★削り 有飘字反馈（弹夹 -2）", _count_hint("弹夹") > hints_before)

	state.set_magazine_ammo(LAUNCHER.item_id, 0)
	var hints_empty: int = _count_hint("弹夹")
	player.take_damage(3.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 0, WeaponData.Element.ACID)
	_check("弹夹已空时不飘字（没有扣就没有提示）", _count_hint("弹夹") == hints_empty)

	## ⑤ 源码级：快照必须在 enter / _restart_attack 两处都刷新
	var src: String = _read("res://script/player/PlayerRangedAttackState.gd")
	var enter_body: String = src.split("func enter()")[1].split("\nfunc ")[0] if src.contains("func enter()") else ""
	var restart_body: String = src.split("func _restart_attack()")[1].split("\nfunc ")[0] \
		if src.contains("func _restart_attack()") else ""
	_check("enter() 记录弹数快照", enter_body.contains("_ammo_at_attack_start ="))
	_check("_restart_attack() 刷新快照（连发不会白送子弹）",
		restart_body.contains("_ammo_at_attack_start ="))

	_finish()


## 统计当前场上「含指定文字的飘字」数量（DamageNumber 会 join "damage_number" 组）。
func _count_hint(keyword: String) -> int:
	var n: int = 0
	for node: Node in get_tree().get_nodes_in_group("damage_number"):
		if String(node.get("text_override")).contains(keyword):
			n += 1
	return n


func _count_bullets() -> int:
	var n: int = 0
	for child: Node in get_children():
		if child.get_script() != null and String(child.get_script().resource_path).ends_with("bullet.gd"):
			n += 1
	return n


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t: String = f.get_as_text()
	f.close()
	return t


func _finish() -> void:
	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)
