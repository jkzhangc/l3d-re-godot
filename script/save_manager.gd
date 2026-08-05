class_name SaveManager extends RefCounted
## 存档管理器 — 保存/加载游戏数据到 JSON 文件

const SAVE_DIR: String = "res://saves/"
const SAVE_FILE: String = "save_data.json"


## 保存当前游戏状态
static func save_game() -> void:
	DirAccess.make_dir_absolute(SAVE_DIR)

	var scene_path: String = ""
	if Global.get_tree() and Global.get_tree().current_scene:
		scene_path = Global.get_tree().current_scene.scene_file_path

	var data: Dictionary = {
		"gold": Global.gold,
		"inventory": _serialize_inventory(),
		"equipment": _serialize_equipment(),
		"active_weapon_slot": Global.active_weapon_slot,
		"healing_item": _serialize_consumable(Global.healing_item),
		"support_item": _serialize_consumable(Global.support_item),
		"player": _serialize_character(),
		"player_hp": Global.player_hp,
		"scene_path": scene_path,
		"weapon_magazines": Global.weapon_magazines.duplicate(),
		"team": _serialize_team(),
		"current_team_index": Global.current_team_index,
		"selected_campaign": Global.selected_campaign.resource_path if Global.selected_campaign else "",
		"selected_difficulty": Global.selected_difficulty,
		"timestamp": Time.get_datetime_string_from_system(),
	}

	var f: FileAccess = FileAccess.open(SAVE_DIR + SAVE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
		print("[存档] 已保存: %s | 弹夹=%s" % [SAVE_DIR + SAVE_FILE, str(Global.weapon_magazines)])


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

	print("[存档] 已加载: %s (time=%s)" % [path, data.get("timestamp", "?")])

	# 恢复到 Global
	Global.gold = data.get("gold", 0)
	Global.player_hp = data.get("player_hp", 200.0)
	_deserialize_inventory(data.get("inventory", []))
	_deserialize_equipment(data.get("equipment", {}))
	Global.active_weapon_slot = data.get("active_weapon_slot", "primary")
	Global.healing_item = _deserialize_consumable(data.get("healing_item", {}))
	Global.support_item = _deserialize_consumable(data.get("support_item", {}))
	Global.weapon_magazines = data.get("weapon_magazines", {}).duplicate()
	# 恢复队伍
	_deserialize_team(data.get("team", []))
	Global.current_team_index = data.get("current_team_index", 0)
	if Global.team.size() > 0:
		Global._apply_team_member_to_global(Global.current_team_index)
	# 恢复战役/难度
	var campaign_path: String = data.get("selected_campaign", "")
	if not campaign_path.is_empty() and ResourceLoader.exists(campaign_path):
		Global.selected_campaign = load(campaign_path) as CampaignData
	Global.selected_difficulty = data.get("selected_difficulty", 0)
	print("[存档] 弹夹数据已恢复: %s | 队伍=%d" % [str(Global.weapon_magazines), Global.team.size()])
	return data


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


# ═══════════════════════════════════════
# 序列化
# ═══════════════════════════════════════

static func _serialize_inventory() -> Array:
	var arr: Array = []
	for item: Resource in Global.inventory:
		var it: ItemData = item as ItemData
		if it:
			arr.append(_item_to_dict(it))
	return arr


static func _serialize_equipment() -> Dictionary:
	var d: Dictionary = {}
	var primary: WeaponData = Global.equipment.get("primary") as WeaponData
	if primary:
		d["primary"] = _item_to_dict(primary)
	var secondary: WeaponData = Global.equipment.get("secondary") as WeaponData
	if secondary:
		d["secondary"] = _item_to_dict(secondary)
	return d


static func _serialize_consumable(item: ItemData) -> Dictionary:
	if not item:
		return {}
	return _item_to_dict(item)


static func _serialize_character() -> Dictionary:
	var cd: CharacterData = Global.player_character as CharacterData
	if not cd:
		return {}
	return {
		"name": cd.character_name,
		"level": cd.level,
	}


static func _serialize_team() -> Array:
	var arr: Array = []
	for member: Dictionary in Global.team:
		var cd: CharacterData = member.get("character") as CharacterData
		var md: Dictionary = {
			"resource_path": cd.resource_path if cd else "",
			"current_hp": member.get("current_hp", 200.0),
			"facing": member.get("facing", 0),
			"position_x": (member.get("position") as Vector2).x if member.get("position") else 0.0,
			"position_y": (member.get("position") as Vector2).y if member.get("position") else 0.0,
			"equipment": _serialize_member_equipment(member.get("equipment", {})),
			"weapon_magazines": member.get("weapon_magazines", {}),
			"active_weapon_slot": member.get("active_weapon_slot", "primary"),
		}
		arr.append(md)
	return arr


static func _serialize_member_equipment(eq: Dictionary) -> Dictionary:
	var d: Dictionary = {}
	var primary: WeaponData = eq.get("primary") as WeaponData
	if primary:
		d["primary"] = _item_to_dict(primary)
	var secondary: WeaponData = eq.get("secondary") as WeaponData
	if secondary:
		d["secondary"] = _item_to_dict(secondary)
	return d


static func _deserialize_team(team_arr: Array) -> void:
	Global.team.clear()
	for member_v: Variant in team_arr:
		var md: Dictionary = member_v as Dictionary
		if not md:
			continue
		var resource_path: String = md.get("resource_path", "")
		var cd: CharacterData = null
		if not resource_path.is_empty() and ResourceLoader.exists(resource_path):
			var res: Resource = load(resource_path)
			if res is CharacterData:
				cd = res as CharacterData
				cd.current_hp = md.get("current_hp", float(cd.get_effective_max_hp()))
		# 反序列化装备
		var eq_dict: Dictionary = md.get("equipment", {})
		var equipment: Dictionary = {"primary": null, "secondary": null}
		var pd: Dictionary = eq_dict.get("primary", {})
		if not pd.is_empty():
			equipment["primary"] = _item_from_dict(pd)
		var sd: Dictionary = eq_dict.get("secondary", {})
		if not sd.is_empty():
			equipment["secondary"] = _item_from_dict(sd)
		var member: Dictionary = {
			"character": cd,
			"current_hp": md.get("current_hp", 200.0),
			"facing": md.get("facing", 0),
			"position": Vector2(md.get("position_x", 0.0), md.get("position_y", 0.0)),
			"equipment": equipment,
			"weapon_magazines": md.get("weapon_magazines", {}).duplicate(),
			"active_weapon_slot": md.get("active_weapon_slot", "primary"),
			"healing_item": null,
			"support_item": null,
			"inventory": [],
		}
		Global.team.append(member)


static func _deserialize_inventory(arr: Array) -> void:
	Global.inventory.clear()
	for elem: Variant in arr:
		var d: Dictionary = elem as Dictionary
		if not d:
			continue
		var item: ItemData = _item_from_dict(d)
		if item:
			Global.inventory.append(item)


static func _deserialize_equipment(d: Dictionary) -> void:
	Global.equipment["primary"] = null
	Global.equipment["secondary"] = null
	var pdict: Dictionary = d.get("primary", {})
	if not pdict.is_empty():
		var w: WeaponData = _item_from_dict(pdict) as WeaponData
		if w:
			Global.equipment["primary"] = w
	var sdict: Dictionary = d.get("secondary", {})
	if not sdict.is_empty():
		var w: WeaponData = _item_from_dict(sdict) as WeaponData
		if w:
			Global.equipment["secondary"] = w


static func _deserialize_consumable(d: Dictionary) -> ItemData:
	if d.is_empty():
		return null
	return _item_from_dict(d)


static func _item_to_dict(item: ItemData) -> Dictionary:
	var d: Dictionary = {
		"item_id": item.item_id,
		"item_name": item.item_name,
		"item_type": item.item_type,
		"description": item.description,
		"sell_price": item.sell_price,
	}
	# 保存资源路径，加载时从 .tres 恢复完整数据
	if item.resource_path and not item.resource_path.is_empty():
		d["resource_path"] = item.resource_path
	if item is WeaponData:
		var w: WeaponData = item as WeaponData
		d["attack_power"] = w.attack_power
		d["attack_speed"] = w.attack_speed
		d["attack_range"] = w.attack_range
		d["critical_rate"] = w.critical_rate
		d["weapon_slot"] = w.weapon_slot
	return d


static func _item_from_dict(d: Dictionary) -> ItemData:
	var itype: int = d.get("item_type", 0)
	var resource_path: String = d.get("resource_path", "")

	# 优先从 .tres 文件加载（保留完整精灵/动画/音效数据）
	if not resource_path.is_empty() and ResourceLoader.exists(resource_path):
		var loaded: Resource = ResourceLoader.load(resource_path)
		if loaded is ItemData:
			return loaded as ItemData

	# 回退：手动构造（缺失精灵/动画数据，仅用于兼容旧存档）
	if itype == ItemData.ItemType.WEAPON:
		var w: WeaponData = WeaponData.new()
		w.attack_power = d.get("attack_power", 10)
		w.attack_speed = d.get("attack_speed", 1.0)
		w.attack_range = d.get("attack_range", 48.0)
		w.critical_rate = d.get("critical_rate", 0.0)
		var ws = d.get("weapon_slot", 0)
		if ws is String:
			w.weapon_slot = 0 if ws == "primary" else 1
		else:
			w.weapon_slot = ws as int
		_fill_item_data(w, d)
		return w
	else:
		var item: ItemData = ItemData.new()
		_fill_item_data(item, d)
		return item


static func _fill_item_data(item: ItemData, d: Dictionary) -> void:
	item.item_id = d.get("item_id", "")
	item.item_name = d.get("item_name", "?")
	item.item_type = d.get("item_type", 0)
	item.description = d.get("description", "")
	item.sell_price = d.get("sell_price", 0)
