class_name PlayerData extends Resource
## 玩家数据容器 — 从 Global 单例中分离出来的玩家专属状态
##
## 用途：
## - Player 节点持有自己的 PlayerData 实例
## - 联机时每个玩家的 PlayerData 由 Host 权威管理
## - 支持序列化/反序列化（checkpoint / 存档）
##
## 注意：此 Resource 由 Player 节点创建和管理，不直接读写 Global。


# ═══════════════════════════════════════
# 角色数据
# ═══════════════════════════════════════
@export var character: CharacterData = null
@export var gold: int = 0

# ═══════════════════════════════════════
# HP
# ═══════════════════════════════════════
@export var current_hp: float = 200.0

## 获取最大 HP（从 CharacterData 读取，如无则默认 200）
func get_max_hp() -> float:
	if character:
		return float(character.get_effective_max_hp())
	return 200.0


func get_hp_ratio() -> float:
	var mh: float = get_max_hp()
	if mh <= 0.0:
		return 0.0
	return clampf(current_hp / mh, 0.0, 1.0)


# ═══════════════════════════════════════
# 武器装备
# ═══════════════════════════════════════
@export var equipment: Dictionary = {"primary": null, "secondary": null}
@export var active_weapon_slot: String = "primary"


func get_active_weapon() -> WeaponData:
	return equipment.get(active_weapon_slot) as WeaponData


func get_equipped_weapon(slot: String) -> WeaponData:
	return equipment.get(slot) as WeaponData


func equip_weapon_in_slot(wd: WeaponData, slot: String) -> void:
	if not slot in equipment:
		return
	var old: WeaponData = equipment[slot] as WeaponData
	if old:
		inventory.append(old)
	equipment[slot] = wd


func unequip_slot(slot: String) -> WeaponData:
	var old: WeaponData = equipment.get(slot) as WeaponData
	if old:
		equipment[slot] = null
	return old


func switch_to_slot(slot: String) -> bool:
	if slot == active_weapon_slot:
		return false
	if not equipment.has(slot):
		return false
	var wd: WeaponData = equipment[slot] as WeaponData
	if not wd:
		return false
	active_weapon_slot = slot
	return true


func get_active_weapon_state_name() -> String:
	var wd: WeaponData = get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		return wd.weapon_state_name
	return ""


# ═══════════════════════════════════════
# 消耗品
# ═══════════════════════════════════════
@export var healing_item: ItemData = null
@export var support_item: ItemData = null


func has_healing_item() -> bool:
	return healing_item != null


func use_healing_item() -> bool:
	if not healing_item:
		return false
	healing_item = null
	return true


func use_support_item() -> bool:
	if not support_item:
		return false
	support_item = null
	return true


func pickup_consumable(item: ItemData) -> void:
	match item.item_type:
		ItemData.ItemType.HEALING:
			healing_item = item
		ItemData.ItemType.SUPPORT:
			support_item = item


# ═══════════════════════════════════════
# 背包
# ═══════════════════════════════════════
@export var inventory: Array = []


func add_item(item: Resource) -> void:
	inventory.append(item)


func remove_item(idx: int) -> void:
	if idx >= 0 and idx < inventory.size():
		inventory.remove_at(idx)


# ═══════════════════════════════════════
# 弹药 & 弹夹
# ═══════════════════════════════════════
@export var weapon_magazines: Dictionary = {}


func get_magazine_ammo(weapon_id: String) -> int:
	return weapon_magazines.get(weapon_id, 0)


func set_magazine_ammo(weapon_id: String, count: int) -> void:
	weapon_magazines[weapon_id] = clampi(count, 0, 999)


func count_ammo_item(ammo_item_id: String) -> int:
	var total: int = 0
	for item: Resource in inventory:
		var it: ItemData = item as ItemData
		if it and it.item_type == ItemData.ItemType.AMMO and it.item_id == ammo_item_id:
			total += 1
	return total


func consume_ammo_item(ammo_item_id: String, count: int) -> int:
	var consumed: int = 0
	var indices_to_remove: Array[int] = []
	for i: int in range(inventory.size()):
		if consumed >= count:
			break
		var it: ItemData = inventory[i] as ItemData
		if it and it.item_type == ItemData.ItemType.AMMO and it.item_id == ammo_item_id:
			indices_to_remove.append(i)
			consumed += 1
	if consumed < count:
		return 0
	indices_to_remove.reverse()
	for idx: int in indices_to_remove:
		inventory.remove_at(idx)
	return consumed


# ═══════════════════════════════════════
# 伤害 / 治疗
# ═══════════════════════════════════════

func take_damage(amount: float) -> void:
	current_hp = maxf(0.0, current_hp - amount)


func heal(amount: float) -> void:
	current_hp = minf(get_max_hp(), current_hp + amount)


func is_dead() -> bool:
	return current_hp <= 0.0


# ═══════════════════════════════════════
# 序列化（checkpoint / 存档）
# ═══════════════════════════════════════

func to_dict() -> Dictionary:
	return {
		"current_hp": current_hp,
		"gold": gold,
		"equipment_primary": equipment.get("primary"),
		"equipment_secondary": equipment.get("secondary"),
		"active_weapon_slot": active_weapon_slot,
		"weapon_magazines": weapon_magazines.duplicate(),
		"inventory": inventory.duplicate(),
		"healing_item": healing_item,
		"support_item": support_item,
	}


func from_dict(d: Dictionary) -> void:
	current_hp = d.get("current_hp", 200.0)
	gold = d.get("gold", 0)
	equipment["primary"] = d.get("equipment_primary")
	equipment["secondary"] = d.get("equipment_secondary")
	active_weapon_slot = d.get("active_weapon_slot", "primary")
	weapon_magazines = d.get("weapon_magazines", {}).duplicate()
	inventory = d.get("inventory", []).duplicate()
	healing_item = d.get("healing_item")
	support_item = d.get("support_item")
