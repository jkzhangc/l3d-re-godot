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
		"timestamp": Time.get_datetime_string_from_system(),
	}

	var f: FileAccess = FileAccess.open(SAVE_DIR + SAVE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
		print("[存档] 已保存: %s" % (SAVE_DIR + SAVE_FILE))


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
	# 角色数据由外部处理
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
