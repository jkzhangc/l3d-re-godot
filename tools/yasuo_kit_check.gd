extends Node

## 安雄专属机制回归（2026-11-10 改版）：
##   · 安雄魂：TP10 → **5 秒内每次受伤固定为 1**；受伤不取消状态；
##     生效中可再发动，每次 +5 秒（时长叠加，层数 +1）
##   · 自爆无效体质：**自己的**爆炸不伤自己；别人的爆炸 / 非爆炸自伤照常
## 用法：godot --headless --path . res://tools/yasuo_kit_check.tscn

const PLAYER_SCENE := preload("res://object/player.tscn")
const ANYU := preload("res://object/character_anyu.tres")

var _fail := 0


func _check(label: String, got, want) -> void:
	if typeof(got) == typeof(want) and is_same(got, want):
		print("  OK   %s = %s" % [label, str(got)])
		return
	if (got is float or got is int) and (want is float or want is int) \
			and absf(float(got) - float(want)) <= 0.001:
		print("  OK   %s = %s" % [label, str(got)])
		return
	_fail += 1
	print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _check_range(label: String, got: float, lo: float, hi: float) -> void:
	if got >= lo and got <= hi:
		print("  OK   %s = %.2f（%.1f~%.1f）" % [label, got, lo, hi])
		return
	_fail += 1
	print("  FAIL %s = %.2f（期望 %.1f~%.1f）" % [label, got, lo, hi])


## 打一次伤害，返回 HP 变化量。
func _hit(p: Node2D, dmg: float, source: Node, explosion: bool) -> float:
	var before: float = float(p.get("current_hp"))
	p.call("take_damage", dmg, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0,
		0, false, source, false, explosion)
	return before - float(p.get("current_hp"))


## 把魂的截止时刻拨到过去，模拟「5 秒到点」。
func _expire_soul(p: Node2D) -> void:
	p.set("_soul_shield_until_msec", Time.get_ticks_msec() - 1)


func _ready() -> void:
	var director: Node = get_node_or_null("/root/Director")
	if director != null:
		director.set("auto_spawn_enabled", false)
	await get_tree().process_frame

	var player: Node2D = PLAYER_SCENE.instantiate()
	add_child(player)
	await get_tree().process_frame

	## 直接换成安雄（不跑完整切人流程，避免依赖状态机就绪时序）
	var anyu: CharacterData = (ANYU as CharacterData).duplicate()
	player.set("current_character", anyu)
	var state: PlayerState = Players.get_state_for_entity(player)
	_check("拿到 PlayerState", state != null, true)
	if state != null:
		state.character = anyu

	print("=== 1) 安雄魂：TP10 → 5 秒内每次受伤固定 1 ===")
	player.set("current_hp", 100.0)
	if state != null:
		state.current_tp = 10
	_check("TP 满 10 时发动成功", bool(player.call("activate_soul_shield")), true)
	_check("TP 已扣 10", state.current_tp if state else -1, 0)
	_check("魂已生效", bool(player.call("has_soul_shield")), true)
	_check_range("剩余时间约 5 秒", float(player.call("_soul_remain_sec")), 4.4, 5.0)
	_check("第一次伤害 = 1", _hit(player, 50.0, null, false), 1.0)
	_check("受伤后状态仍在（不再一次耗尽）", bool(player.call("has_soul_shield")), true)
	_check("第二次伤害 = 1", _hit(player, 50.0, null, false), 1.0)
	_check("第三次伤害 = 1", _hit(player, 50.0, null, false), 1.0)

	print("=== 2) 生效中再发动：时长叠加 + 层数 +1 ===")
	if state != null:
		state.current_tp = 20
	var before_remain: float = float(player.call("_soul_remain_sec"))
	_check("再发动成功", bool(player.call("activate_soul_shield")), true)
	_check("TP 再扣 10", state.current_tp if state else -1, 10)
	_check_range("总时长约 10 秒", float(player.call("_soul_remain_sec")), 9.0, 10.0)
	_check("层数 = 2", int(player.get("_soul_stacks")), 2)
	_check("比发动前更长", float(player.call("_soul_remain_sec")) > before_remain, true)

	print("=== 3) TP 不足不能发动（也不叠层） ===")
	if state != null:
		state.current_tp = 9
	_check("TP=9 发动被拒", bool(player.call("activate_soul_shield")), false)
	_check("层数仍是 2", int(player.get("_soul_stacks")), 2)

	print("=== 4) 5 秒到点后自动失效，再发动从 5 秒重新起算 ===")
	_expire_soul(player)
	_check("过期后不再生效", bool(player.call("has_soul_shield")), false)
	_check("过期后伤害恢复正常（50）", _hit(player, 50.0, null, false), 50.0)
	if state != null:
		state.current_tp = 10
	_check("过期后再发动成功", bool(player.call("activate_soul_shield")), true)
	_check("层数归 1", int(player.get("_soul_stacks")), 1)
	_check_range("重新起算 5 秒", float(player.call("_soul_remain_sec")), 4.4, 5.0)

	print("=== 5) 自爆无效体质 ===")
	player.set("current_hp", 100.0)
	_check("自己的爆炸：0 伤害", _hit(player, 40.0, player, true), 0.0)
	player.set("current_hp", 100.0)
	var other: Node2D = Node2D.new()
	add_child(other)
	_check("别人的爆炸：照常受伤", _hit(player, 40.0, other, true) > 0.0, true)
	player.set("current_hp", 100.0)
	_check("自己但非爆炸（近战/子弹）：照常受伤", _hit(player, 40.0, player, false) > 0.0, true)

	print("=== 6) 换人后魂仍在（可换人传递） ===")
	player.set("current_hp", 100.0)
	if state != null:
		state.current_tp = 10
	player.call("activate_soul_shield")
	## 模拟切人：换回大雄的数据（实体不重建）
	var nobita: CharacterData = load("res://object/character_nobita.tres")
	player.set("current_character", nobita)
	_check("切人后魂仍在", bool(player.call("has_soul_shield")), true)
	_check("切人后伤害仍固定 1", _hit(player, 50.0, null, false), 1.0)

	print("=== 7) 只有安雄有这两条设定 ===")
	_check("安雄 yasuo_soul", (ANYU as CharacterData).yasuo_soul, true)
	_check("安雄 self_blast_immune", (ANYU as CharacterData).self_blast_immune, true)
	_check("安雄 demolition", (ANYU as CharacterData).demolition, true)
	_check("大雄没有 yasuo_soul", (nobita as CharacterData).yasuo_soul, false)
	_check("安雄头像非空", (ANYU as CharacterData).portrait != null, true)
	_check("安雄头像索引 4", (ANYU as CharacterData).portrait_index, 4)

	print("=== 8) buff 列表（HUD 数据源） ===")
	player.set("current_character", anyu)
	_expire_soul(player)
	if state != null:
		state.current_tp = 20
	player.call("activate_soul_shield")
	if state != null:
		state.current_tp = 10
	player.call("activate_soul_shield")
	var buffs: Array = player.call("get_active_buffs")
	_check("发动后列表非空", buffs.size() >= 1, true)
	var soul_entry: Dictionary = {}
	for b: Dictionary in buffs:
		if String(b.get("id", "")) == "yasuo_soul":
			soul_entry = b
	_check("含 yasuo_soul", not soul_entry.is_empty(), true)
	_check("文案 = 安雄魂", String(soul_entry.get("label", "")), "安雄魂")
	_check("有倒计时（remain > 0）", float(soul_entry.get("remain", -1.0)) > 0.0, true)
	_check("层数 = 2（叠了两次）", int(soul_entry.get("stacks", 0)), 2)
	_check("不是负面", bool(soul_entry.get("debuff", true)), false)
	## 快照 → 回填 的另一端（联机 Client 走这条路）
	var snap: Array = player.call("get_buff_snapshot")
	_check("快照含 1 条", snap.size(), 1)
	## 层数必须进快照：Host 的 buff 同步只比对「id:层数」签名，
	## 续期若不改层数，Client 永远收不到新的倒计时（会提前消失）。
	_check("快照里的层数 = 2", int((snap[0] as Array)[2]), 2)
	_check("快照里的倒计时有值", float((snap[0] as Array)[1]) > 0.0, true)
	player.call("apply_network_buffs", snap)
	player.set("network_controlled", true)
	player.set("network_local_player", false)
	var remote: Array = player.call("get_active_buffs")
	_check("镜像端也能读出同一条", remote.size() >= 1, true)
	player.set("network_controlled", false)

	print("=== 9) 没有跑步图 → 跑步沿用步行图与同一角色格 ===")
	_check("安雄确实没配 run_texture", (ANYU as CharacterData).run_texture == null, true)
	player.set("current_character", anyu)
	player.call("_apply_current_character_data", anyu)
	_check("run_texture == walk_texture", player.get("run_texture") == player.get("walk_texture"), true)
	_check("run_char_index == walk_char_index",
			int(player.get("run_char_index")), int(player.get("walk_char_index")))
	player.set("current_character", nobita)
	player.call("_apply_current_character_data", nobita)
	_check("有跑步图的角色仍用专属图（大雄）",
			player.get("run_texture") != player.get("walk_texture"), true)

	player.queue_free()
	other.queue_free()
	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)
