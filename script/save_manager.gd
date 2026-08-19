class_name SaveManager extends RefCounted
## 存档管理器 — 保存/加载游戏数据到 JSON 文件
##
## 存档格式 v2：per-player 状态全部收在 seats 数组里（每项 = PlayerState.to_dict()），
## 顶层只放真正全局的东西（gold / 场景 / 战役 / 难度）。
##
## v1（无 save_version 字段）是旧格式：顶层单值 + 一个残缺的 team 数组。
## 旧格式仍可读入（见 _load_legacy），但只写 v2。
## 注意 v1 的 team 数组漏存了 current_tp / healing_item / support_item / throwable /
## inventory，旧 loader 还会用 team 里的空值覆盖顶层字段 —— 迁移时反过来把顶层的
## inventory/治疗品/辅助品叠加回激活座位，尽量救回这些数据。

const SAVE_DIR: String = "res://saves/"
const SAVE_FILE: String = "save_data.json"
const SAVE_VERSION: int = 2


## 保存当前游戏状态
static func save_game() -> void:
	DirAccess.make_dir_absolute(SAVE_DIR)

	var scene_path: String = ""
	if Global.get_tree() and Global.get_tree().current_scene:
		scene_path = Global.get_tree().current_scene.scene_file_path

	var seat_dicts: Array = []
	for s: PlayerState in Players.seats:
		seat_dicts.append(s.to_dict())

	var data: Dictionary = {
		"save_version": SAVE_VERSION,
		"gold": Global.gold,
		"scene_path": scene_path,
		"seats": seat_dicts,
		"active_seat_index": Players.active_seat_index,
		"selected_campaign": Global.selected_campaign.resource_path if Global.selected_campaign else "",
		"selected_difficulty": Global.selected_difficulty,
		"timestamp": Time.get_datetime_string_from_system(),
	}

	var f: FileAccess = FileAccess.open(SAVE_DIR + SAVE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
		print("[存档] 已保存: %s | 座位=%d" % [SAVE_DIR + SAVE_FILE, seat_dicts.size()])


## 加载存档
static func load_game() -> Dictionary:
	var path: String = SAVE_DIR + SAVE_FILE
	if not FileAccess.file_exists(path):
		print("[存档] 未找到存档文件")
		return {}

	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}

	var text: String = f.get_as_text()
	f.close()

	var data: Dictionary = JSON.parse_string(text) if text else {}
	if data.is_empty():
		return {}

	var version: int = int(data.get("save_version", 1))
	print("[存档] 已加载: %s (time=%s, v%d)" % [path, data.get("timestamp", "?"), version])

	if version >= 2:
		_load_v2(data)
	else:
		_load_legacy(data)

	# 全局字段（两个版本共用）
	Global.gold = data.get("gold", 0)
	var campaign_path: String = data.get("selected_campaign", "")
	if not campaign_path.is_empty() and ResourceLoader.exists(campaign_path):
		Global.selected_campaign = load(campaign_path) as CampaignData
	Global.selected_difficulty = data.get("selected_difficulty", 0)

	print("[存档] 恢复完成 | 座位=%d %s" % [
		Players.seat_count(), Players.get_active_state().describe(),
	])
	return data


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
	st.current_tp = md.get("current_tp", st.get_max_tp())
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
	st.current_tp = st.get_max_tp()
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


## 获取存档中的场景路径（用于死亡后重载）
static func get_saved_scene_path() -> String:
	var path: String = SAVE_DIR + SAVE_FILE
	if not FileAccess.file_exists(path):
		return ""
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not f:
		return ""
	var text: String = f.get_as_text()
	f.close()
	var data: Dictionary = JSON.parse_string(text) if text else {}
	return data.get("scene_path", "")


## 启动时自动加载
static func auto_load_on_start() -> bool:
	if not FileAccess.file_exists(SAVE_DIR + SAVE_FILE):
		return false
	var data: Dictionary = load_game()
	return not data.is_empty()


## 检查存档是否存在
static func has_save() -> bool:
	return FileAccess.file_exists(SAVE_DIR + SAVE_FILE)
