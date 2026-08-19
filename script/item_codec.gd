class_name ItemCodec extends RefCounted
## 物品（ItemData / WeaponData）的 Dictionary 编解码。
##
## 单独成类是为了**打断循环依赖**：PlayerState 要序列化自己持有的物品，
## SaveManager 又要创建 PlayerState。两者互相引用会让 GDScript 编译失败，
## 而且报的是误导性的 "Identifier not found"（连 autoload 名都认不出）。
## 本类不依赖 PlayerState 也不依赖 SaveManager，处在依赖链的最底层。

## 序列化一个物品。优先记 resource_path（还原时能拿回完整精灵/动画/音效），
## 同时也存基础字段 —— 背包里的弹药是 duplicate() 出来的，没有 resource_path，
## 只能靠这些字段手工重建。
static func to_dict(item: ItemData) -> Dictionary:
	if not item:
		return {}
	var d: Dictionary = {
		"item_id": item.item_id,
		"item_name": item.item_name,
		"item_type": item.item_type,
		"description": item.description,
		"sell_price": item.sell_price,
	}
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


## 空 Dictionary → null，否则走 from_dict()
static func from_dict_or_null(d: Dictionary) -> ItemData:
	if d.is_empty():
		return null
	return from_dict(d)


static func from_dict(d: Dictionary) -> ItemData:
	var itype: int = int(d.get("item_type", 0))
	var resource_path: String = d.get("resource_path", "")

	# 优先从 .tres 文件加载（保留完整精灵/动画/音效数据）
	if not resource_path.is_empty() and ResourceLoader.exists(resource_path):
		var loaded: Resource = ResourceLoader.load(resource_path)
		if loaded is ItemData:
			return loaded as ItemData

	# 回退：手动构造（缺失精灵/动画数据；duplicate() 出来的弹药走这条路）
	if itype == ItemData.ItemType.WEAPON:
		var w: WeaponData = WeaponData.new()
		w.attack_power = d.get("attack_power", 10)
		w.attack_speed = d.get("attack_speed", 1.0)
		w.attack_range = d.get("attack_range", 48.0)
		w.critical_rate = d.get("critical_rate", 0.0)
		var ws: Variant = d.get("weapon_slot", 0)
		if ws is String:
			w.weapon_slot = 0 if ws == "primary" else 1
		else:
			w.weapon_slot = int(ws)
		_fill_item_data(w, d)
		return w
	var item: ItemData = ItemData.new()
	_fill_item_data(item, d)
	return item


static func _fill_item_data(item: ItemData, d: Dictionary) -> void:
	item.item_id = d.get("item_id", "")
	item.item_name = d.get("item_name", "?")
	item.item_type = int(d.get("item_type", 0))
	item.description = d.get("description", "")
	item.sell_price = int(d.get("sell_price", 0))
