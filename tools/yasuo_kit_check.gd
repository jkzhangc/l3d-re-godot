extends Node

## 安雄专属机制回归（2026-11-09）：
##   · 安雄魂：TP10 → 下一次受到的伤害固定为 1，用完即消
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


## 打一次伤害，返回 HP 变化量。
func _hit(p: Node2D, dmg: float, source: Node, explosion: bool) -> float:
	var before: float = float(p.get("current_hp"))
	p.call("take_damage", dmg, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 0,
		0, false, source, false, explosion)
	return before - float(p.get("current_hp"))


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

	print("=== 1) 安雄魂：TP10 → 下次受伤固定 1 ===")
	player.set("current_hp", 100.0)
	if state != null:
		state.current_tp = 10
	_check("TP 满 10 时发动成功", bool(player.call("activate_soul_shield")), true)
	_check("TP 已扣 10", state.current_tp if state else -1, 0)
	_check("魂已挂上", bool(player.call("has_soul_shield")), true)
	_check("重复发动被拒（不白扣 TP）", bool(player.call("activate_soul_shield")), false)
	_check("下一次伤害 = 1", _hit(player, 50.0, null, false), 1.0)
	_check("魂已消耗", bool(player.call("has_soul_shield")), false)
	_check("之后伤害恢复正常（50）", _hit(player, 50.0, null, false), 50.0)

	print("=== 2) TP 不足不能发动 ===")
	if state != null:
		state.current_tp = 9
	_check("TP=9 发动被拒", bool(player.call("activate_soul_shield")), false)
	_check("没有挂上", bool(player.call("has_soul_shield")), false)

	print("=== 3) 自爆无效体质 ===")
	player.set("current_hp", 100.0)
	_check("自己的爆炸：0 伤害", _hit(player, 40.0, player, true), 0.0)
	player.set("current_hp", 100.0)
	var other: Node2D = Node2D.new()
	add_child(other)
	_check("别人的爆炸：照常受伤", _hit(player, 40.0, other, true) > 0.0, true)
	player.set("current_hp", 100.0)
	_check("自己但非爆炸（近战/子弹）：照常受伤", _hit(player, 40.0, player, false) > 0.0, true)

	print("=== 4) 换人后魂仍在（可换人传递） ===")
	player.set("current_hp", 100.0)
	if state != null:
		state.current_tp = 10
	player.call("activate_soul_shield")
	## 模拟切人：换回大雄的数据（实体不重建）
	var nobita: CharacterData = load("res://object/character_nobita.tres")
	player.set("current_character", nobita)
	_check("切人后魂仍在", bool(player.call("has_soul_shield")), true)
	_check("切人后伤害仍固定 1", _hit(player, 50.0, null, false), 1.0)

	print("=== 5) 只有安雄有这两条设定 ===")
	_check("安雄 yasuo_soul", (ANYU as CharacterData).yasuo_soul, true)
	_check("安雄 self_blast_immune", (ANYU as CharacterData).self_blast_immune, true)
	_check("安雄 demolition", (ANYU as CharacterData).demolition, true)
	_check("大雄没有 yasuo_soul", (nobita as CharacterData).yasuo_soul, false)
	_check("安雄头像非空", (ANYU as CharacterData).portrait != null, true)
	_check("安雄头像索引 4", (ANYU as CharacterData).portrait_index, 4)

	print("=== 6) buff 列表（HUD 数据源） ===")
	player.set("current_character", anyu)
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
	_check("常驻（remain < 0）", float(soul_entry.get("remain", 0.0)) < 0.0, true)
	_check("不是负面", bool(soul_entry.get("debuff", true)), false)
	## 快照 → 回填 的另一端（联机 Client 走这条路）
	var snap: Array = player.call("get_buff_snapshot")
	_check("快照含 1 条", snap.size(), 1)
	player.call("apply_network_buffs", snap)
	player.set("network_controlled", true)
	player.set("network_local_player", false)
	var remote: Array = player.call("get_active_buffs")
	_check("镜像端也能读出同一条", remote.size() >= 1, true)
	player.set("network_controlled", false)

	print("=== 7) 没有跑步图 → 跑步沿用步行图与同一角色格 ===")
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
