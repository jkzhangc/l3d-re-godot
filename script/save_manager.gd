class_name SaveManager extends RefCounted

## ── 架构定位 ──
## 系统：存档系统 ｜ 层：数据（RefCounted）
## 联机：仅单机 / Host 侧使用（存档点节点在联机会话里自移除，见 save_point.gd）
## 职责：多槽位 JSON 存档读写（20 槽），格式 v2（seats 数组承载 per-player 状态）并兼容 v1 旧格式。
## 依赖：PlayerState、ItemCodec；被 Global / 存档点菜单 / 标题画面调用

## 存档管理器 — 保存 / 加载游戏数据到 JSON 文件
##
## ★2026-10-03 重写：从「单档」升级为「20 个槽位」。
##   ① 落盘目录 `res://saves/` → **`user://saves/`** —— `res://` 在导出包（尤其安卓 APK）里
##      是**只读**的，写 `res://saves/` 会静默失败（此前 save_game 是死代码才没暴露）。
##   ② 每槽一个文件：`user://saves/slot_%02d.json`（slot_00 ~ slot_19）。
##
## 存档格式 v2：per-player 状态全部收在 seats 数组里（每项 = PlayerState.to_dict()），
## 顶层只放真正全局的东西（gold / 场景 / 战役 / 难度）。
##
## v1（无 save_version 字段）是旧格式：顶层单值 + 一个残缺的 team 数组。
## 旧格式仍可读入（见 _load_legacy），但只写 v2。

const SAVE_DIR: String = "user://saves/"
const SAVE_VERSION: int = 2
## 存档槽位数量（用户 2026-10-03 定稿：16 → 能多就 20）。
const SLOT_COUNT: int = 20


# ═══════════════════════════════════════
# 路径 / 查询
# ═══════════════════════════════════════

static func slot_path(idx: int) -> String:
	return SAVE_DIR + "slot_%02d.json" % clampi(idx, 0, SLOT_COUNT - 1)


static func has_slot(idx: int) -> bool:
	if idx < 0 or idx >= SLOT_COUNT:
		return false
	return FileAccess.file_exists(slot_path(idx))


## 是否**至少有一个**存档槽有内容（标题画面「继续游戏」的可用性判据）。
static func has_any_save() -> bool:
	return latest_slot() >= 0


## 最近一次保存的槽位号；无档返回 -1（按文件 mtime 取最新）。
static func latest_slot() -> int:
	var best_idx: int = -1
	var best_time: int = -1
	for i: int in range(SLOT_COUNT):
		var p: String = slot_path(i)
		if not FileAccess.file_exists(p):
			continue
		var t: int = FileAccess.get_modified_time(p)
		if t >= best_time:
			best_time = t
			best_idx = i
	return best_idx


static func delete_slot(idx: int) -> bool:
	if not has_slot(idx):
		return false
	var err: Error = DirAccess.remove_absolute(slot_path(idx))
	return err == OK


# ═══════════════════════════════════════
# 保存
# ═══════════════════════════════════════

## 保存当前游戏状态到指定槽位。
## spawn_position（可选）：存档点的全局坐标 —— 旧档 / 兜底落点。
## player_position（可选）：**玩家当时的真实站位**（2026-10-05）—— 读档优先落回这里，
##   避免落回存档点中心被 32×32 实体碰撞卡住。
static func save_to_slot(idx: int, spawn_position: Variant = null, player_position: Variant = null) -> bool:
	idx = clampi(idx, 0, SLOT_COUNT - 1)
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

	var scene_path: String = ""
	if Global.get_tree() and Global.get_tree().current_scene:
		scene_path = Global.get_tree().current_scene.scene_file_path

	var seat_dicts: Array = []
	for s: PlayerState in Players.seats:
		seat_dicts.append(s.to_dict())

	var data: Dictionary = {
		"save_version": SAVE_VERSION,
		"slot_index": idx,
		"gold": Global.gold,
		"scene_path": scene_path,
		"seats": seat_dicts,
		"active_seat_index": Players.active_seat_index,
		# 单机喷雾共用池（2026-09-13）；联机时恒 0（各座位自己存）
		"team_spray_count": Players.team_spray_count if Players.using_shared_spray_pool() else 0,
		# ★喷雾池 count 与 item 必须成对存取（同 checkpoint 的教训）：
		#   只存 count → 读档后 count>0 但 item=null → 喷雾用不了且每按一次白扣一支。
		"team_spray_item": _encode_item(Players.team_spray_item) if Players.using_shared_spray_pool() else {},
		"selected_campaign": Global.selected_campaign.resource_path if Global.selected_campaign else "",
		"selected_difficulty": Global.selected_difficulty,
		"quest_flags": Global.quest_flags.duplicate(),
		# ★已看过的安全屋台词 key（2026-10-05）：读档后已看过的不再重放。
		"seen_safehouse_dialogues": Global.seen_safehouse_dialogues.duplicate(),
		# 槽位列表预览用的轻量数据（避免开菜单时逐槽加载 CharacterData 卡顿）
		"preview": _build_preview(),
		"timestamp": Time.get_datetime_string_from_system(),
	}
	if spawn_position is Vector2:
		data["spawn_position"] = {"x": spawn_position.x, "y": spawn_position.y}
	## ★玩家真实站位（2026-10-05）：读档优先用它，避免落回存档点中心被卡住。
	if player_position is Vector2:
		data["player_position"] = {"x": player_position.x, "y": player_position.y}

	var f: FileAccess = FileAccess.open(slot_path(idx), FileAccess.WRITE)
	if f == null:
		push_error("[存档] 无法写入槽位 %d: %s (err=%d)"
			% [idx, slot_path(idx), FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	print("[存档] 已保存槽位 %d: %s | 座位=%d" % [idx, slot_path(idx), seat_dicts.size()])
	return true


## 从当前座位构建「槽位预览」轻量数据（标题/徽章/槽位列表用）。
static func _build_preview() -> Dictionary:
	var members: Array = []
	for s: PlayerState in Players.seats:
		if s == null:
			continue
		var cd: CharacterData = s.character
		members.append({
			"name": cd.character_name if cd else "?",
			"level": cd.level if cd else 1,
			"hp": int(round(s.current_hp)),
			"max_hp": int(round(s.get_max_hp())),
			"character_path": s.character_path,
		})
	var leader: String = ""
	var leader_path: String = ""
	if not members.is_empty():
		leader = str(members[0].get("name", ""))
		leader_path = str(members[0].get("character_path", ""))
	return {
		"leader": leader,
		"leader_path": leader_path,
		"party_size": members.size(),
		"members": members,
	}


static func _encode_item(it: ItemData) -> Dictionary:
	if it == null:
		return {}
	var codec: GDScript = load("res://script/item_codec.gd")
	return codec.to_dict(it)


# ═══════════════════════════════════════
# 读取
# ═══════════════════════════════════════

## 只读槽位摘要（**不改动任何运行时状态**），供槽位列表显示。
## 返回 {} 表示空槽；键：leader / party_size / members / scene_name / timestamp。
static func slot_info(idx: int) -> Dictionary:
	if not has_slot(idx):
		return {}
	var data: Dictionary = _read_raw(idx)
	if data.is_empty():
		return {}
	var info: Dictionary = (data.get("preview", {}) as Dictionary).duplicate(true)
	info["slot_index"] = idx
	info["scene_name"] = str(data.get("scene_path", "")).get_file().get_basename()
	info["timestamp"] = data.get("timestamp", "")
	info["save_version"] = int(data.get("save_version", 1))
	return info


## 加载槽位并**应用**到运行时（Players / Global）。
## 返回存档数据（含 scene_path / spawn_position）；无档返回 {}。
static func load_slot(idx: int) -> Dictionary:
	if not has_slot(idx):
		print("[存档] 槽位 %d 为空" % idx)
		return {}
	var data: Dictionary = _read_raw(idx)
	if data.is_empty():
		return {}

	var version: int = int(data.get("save_version", 1))
	if version >= 2:
		_load_v2(data)
	else:
		_load_legacy(data)

	# 全局字段（两个版本共用）
	Global.gold = data.get("gold", 0)
	Global.quest_flags.clear()
	var saved_flags: Dictionary = data.get("quest_flags", {})
	if not saved_flags.is_empty():
		for k: Variant in saved_flags:
			Global.quest_flags[str(k)] = bool(saved_flags[k])
	# ★已看过的安全屋台词 key（2026-10-05）：旧档无该键 → 空集 → 台词正常重播一次。
	Global.seen_safehouse_dialogues.clear()
	var saved_seen: Dictionary = data.get("seen_safehouse_dialogues", {})
	if not saved_seen.is_empty():
		for k: Variant in saved_seen:
			Global.seen_safehouse_dialogues[str(k)] = bool(saved_seen[k])
	var campaign_path: String = data.get("selected_campaign", "")
	if not campaign_path.is_empty() and ResourceLoader.exists(campaign_path):
		Global.selected_campaign = load(campaign_path) as CampaignData
	Global.selected_difficulty = data.get("selected_difficulty", 0)

	print("[存档] 已加载槽位 %d: %s (time=%s, v%d)" % [idx, slot_path(idx), data.get("timestamp", "?"), version])
	print("[存档] 恢复完成 | 座位=%d %s" % [Players.seat_count(), Players.get_active_state().describe()])
	return data


static func _read_raw(idx: int) -> Dictionary:
	var path: String = slot_path(idx)
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(text) if text else null
	if data is Dictionary:
		return data as Dictionary
	return {}


static func _load_v2(data: Dictionary) -> void:
	Players.clear_seats()
	for elem: Variant in data.get("seats", []):
		var sd: Dictionary = elem as Dictionary
		if not sd:
			continue
		var st: PlayerState = PlayerState.new()
		st.from_dict(sd)
		Players.add_seat(st)
	if Players.seat_count() > 0:
		Players.seats_authored = true
		Players.active_seat_index = clampi(
			data.get("active_seat_index", 0), 0, Players.seat_count() - 1
		)
	# 喷雾共用池（单机）：v2.1 起有专用字段；旧 v2 存档把各座位持有的喷雾并入池
	var saved_pool: int = int(data.get("team_spray_count", -1))
	if saved_pool >= 0:
		Players.team_spray_count = saved_pool
	elif not Players.is_online_session():
		var migrated: int = 0
		for s: PlayerState in Players.seats:
			if s and s.healing_item_count > 0:
				migrated += s.healing_item_count
			if s:
				s.healing_item = null
				s.healing_item_count = 0
		Players.team_spray_count = migrated
	# ★count 与 item 成对恢复（旧档没有该键 → 回退到默认喷雾资源）
	var spray: Variant = data.get("team_spray_item", {})
	var codec: GDScript = load("res://script/item_codec.gd")
	if spray is Dictionary and not (spray as Dictionary).is_empty():
		var it: ItemData = codec.from_dict(spray)
		if it:
			Players.team_spray_item = it
	elif Players.team_spray_count > 0 and Players.team_spray_item == null:
		var g: Node = Global.get_node_or_null("/root/Global") if Global else null
		if g and g.has_method("_default_spray_item"):
			Players.team_spray_item = g.call("_default_spray_item")


## 读取 v1 旧存档并归一化为座位表
static func _load_legacy(data: Dictionary) -> void:
	Players.clear_seats()

	var team_arr: Array = data.get("team", [])
	if team_arr.is_empty():
		# 旧的「单角色」存档：只有顶层单值
		var st: PlayerState = PlayerState.new()
		_apply_legacy_top_level(st, data)
		Players.add_seat(st)
	else:
		for elem: Variant in team_arr:
			var md: Dictionary = elem as Dictionary
			if not md:
				continue
			Players.add_seat(_seat_from_legacy_member(md))
		# 顶层的 inventory / 治疗品 / 辅助品 是 v1 的 team 数组没存的，
		# 叠加回激活座位（旧 loader 会用 team 里的空值把它们冲掉，这里救回来）
		var active: int = clampi(data.get("current_team_index", 0), 0, Players.seat_count() - 1)
		var st: PlayerState = Players.get_seat(active)
		if st:
			_apply_legacy_consumables(st, data)

	Players.seats_authored = true
	Players.active_seat_index = clampi(
		data.get("current_team_index", 0), 0, maxi(Players.seat_count() - 1, 0)
	)
	print("[存档] v1 旧存档已迁移为 %d 个座位" % Players.seat_count())


static func _seat_from_legacy_member(md: Dictionary) -> PlayerState:
	var st: PlayerState = PlayerState.new()
	var resource_path: String = md.get("resource_path", "")
	if not resource_path.is_empty() and ResourceLoader.exists(resource_path):
		var res: Resource = load(resource_path)
		if res is CharacterData:
			# duplicate()：v1 的 _deserialize_team 少了这一步，导致同角色的多个队员
			# 共享同一实例、并污染资源缓存里的 .tres 母本
			st.character = (res as CharacterData).duplicate() as CharacterData
			st.character_path = resource_path
	st.current_hp = md.get("current_hp", st.get_max_hp())
	## ★经唯一写入口 set_tp（钳到 [0, 上限]）：旧存档里的越界 TP 不再污染 HUD。
	st.set_tp(int(md.get("current_tp", st.get_max_tp())))
	st.facing = md.get("facing", 0)
	st.position = Vector2(md.get("position_x", 0.0), md.get("position_y", 0.0))
	var eq: Dictionary = md.get("equipment", {})
	for slot: String in ["primary", "secondary"]:
		var sd: Dictionary = eq.get(slot, {})
		if not sd.is_empty():
			st.equipment[slot] = ItemCodec.from_dict(sd)
	st.weapon_magazines = md.get("weapon_magazines", {}).duplicate()
	st.active_weapon_slot = md.get("active_weapon_slot", "primary")
	return st


static func _apply_legacy_top_level(st: PlayerState, data: Dictionary) -> void:
	var cd_path: String = "res://object/character_nobita.tres"
	if ResourceLoader.exists(cd_path):
		var res: Resource = load(cd_path)
		if res is CharacterData:
			st.character = (res as CharacterData).duplicate() as CharacterData
			st.character_path = cd_path
	st.current_hp = data.get("player_hp", st.get_max_hp())
	st.set_tp(st.get_max_tp())
	var eq: Dictionary = data.get("equipment", {})
	for slot: String in ["primary", "secondary"]:
		var sd: Dictionary = eq.get(slot, {})
		if not sd.is_empty():
			st.equipment[slot] = ItemCodec.from_dict(sd)
	st.active_weapon_slot = data.get("active_weapon_slot", "primary")
	st.weapon_magazines = data.get("weapon_magazines", {}).duplicate()
	_apply_legacy_consumables(st, data)


static func _apply_legacy_consumables(st: PlayerState, data: Dictionary) -> void:
	var hd: Dictionary = data.get("healing_item", {})
	if not hd.is_empty():
		st.healing_item = ItemCodec.from_dict(hd)
		if st.healing_item_count <= 0:
			st.healing_item_count = 1
	var sd: Dictionary = data.get("support_item", {})
	if not sd.is_empty():
		st.support_item = ItemCodec.from_dict(sd)
	for elem: Variant in data.get("inventory", []):
		var d: Dictionary = elem as Dictionary
		if not d:
			continue
		var it: ItemData = ItemCodec.from_dict(d)
		if it:
			st.inventory.append(it)


## 读档后的落点：优先「玩家真实站位」（2026-10-05），旧档回退「存档点坐标」；都没有返回 null。
static func spawn_position_of(data: Dictionary) -> Variant:
	for key: String in ["player_position", "spawn_position"]:
		var sp: Variant = data.get(key, null)
		if sp is Dictionary:
			var d: Dictionary = sp
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return null


## 获取指定槽位记录的场景路径（用于读档后切图）。空槽返回 ""。
static func get_slot_scene_path(idx: int) -> String:
	return str(_read_raw(idx).get("scene_path", ""))
