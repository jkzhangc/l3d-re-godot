class_name PlayerState extends RefCounted
## 单个玩家/队员的完整状态 —— 从 Global 单例迁出的 per-player 数据。
##
## 单人模式：每个队伍座位一份。角色切换 = 换绑 Player 节点指向的 PlayerState，
##           不再逐字段拷贝（旧实现见 global.gd 的 _apply/_save_team_member）。
## 联机模式（尚未实现）：每个 peer 一份，按 Host 全量模拟模型只在 Host 侧写入。
##
## 本类只存「数据」，不碰场景节点。消耗品的实际效果（回 HP/TP）由玩家节点自己施加 ——
## use_healing_item() / use_support_item() 只负责扣数量并返回被消耗的物品。

# ═══════════════════════════════════════
# 角色与生命
# ═══════════════════════════════════════
var character: CharacterData = null
## character 的来源 .tres 路径。必须单独记 —— 座位上的 CharacterData 是 duplicate()
## 出来的独立副本，而 Resource.duplicate() 会清空 resource_path，光靠 character
## 本身存不出路径来。
var character_path: String = ""
var current_hp: float = 200.0
var current_tp: int = 0

# ═══════════════════════════════════════
# 装备与弹药
# ═══════════════════════════════════════
var equipment: Dictionary = {"primary": null, "secondary": null}
var active_weapon_slot: String = "primary"
var weapon_magazines: Dictionary = {}   ## item_id → 弹夹内余弹

# ═══════════════════════════════════════
# 消耗品与背包
# ═══════════════════════════════════════
var healing_item: ItemData = null
var healing_item_count: int = 0
var support_item: ItemData = null
var throwable: ThrowableData = null
var inventory: Array = []

# ═══════════════════════════════════════
# 场景位姿（角色切换 / 存档用）
# ═══════════════════════════════════════
var facing: int = 0
var position: Vector2 = Vector2.ZERO

# ═══════════════════════════════════════
# 每角色独立的运行时计时（从 player.gd 迁入）
# ═══════════════════════════════════════
var shove_fatigue_count: int = 0        ## 连续推击计数
var shove_cooldown_timer: float = 0.0   ## 推击冷却倒计时（>0=冷却中）
var shove_idle_timer: float = 0.0       ## 自上次推击以来的空闲时间
var tp_regen_timer: float = 0.0         ## TP 自动回复计时

# ═══════════════════════════════════════
# 座位归属（联机预留；单人下 owner_peer_id 恒为 0）
# ═══════════════════════════════════════
var seat_index: int = 0
var owner_peer_id: int = 0   ## 0 = 本地/无主


func _init() -> void:
	# 显式初始化容器 —— 沿用项目既有防御约定（防 Godot 4 类级默认值跨实例共享）
	equipment = {"primary": null, "secondary": null}
	weapon_magazines = {}
	inventory = []


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════

## 用一份 CharacterData 初始化本座位。
## 注意：cd 应当已经是 duplicate() 出来的独立副本，否则多个座位会共享同一实例。
## source_path 传 duplicate() 之前那份 .tres 的路径（副本自己的 resource_path 是空的）。
func init_from_character(cd: CharacterData, source_path: String = "") -> void:
	character = cd
	if not source_path.is_empty():
		character_path = source_path
	elif cd:
		character_path = cd.resource_path
	if not cd:
		return
	current_hp = float(cd.get_effective_max_hp())
	current_tp = cd.get_effective_max_tp()


# ═══════════════════════════════════════
# 查询
# ═══════════════════════════════════════

func is_alive() -> bool:
	return current_hp > 0.0


func get_max_hp() -> float:
	if character:
		return float(character.get_effective_max_hp())
	return 200.0


func get_max_tp() -> int:
	if character:
		return character.get_effective_max_tp()
	return 0


func get_character_name() -> String:
	if character:
		return character.character_name
	return "?"


# ═══════════════════════════════════════
# 武器装备管理（迁自 global.gd:447-490）
# ═══════════════════════════════════════

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
		print("[PlayerState] 卸下 %s 槽: %s" % [slot, old.item_name])
	equipment[slot] = wd
	print("[PlayerState] 装备到 %s 槽: %s" % [slot, wd.item_name])


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
	print("[PlayerState] 切换到 %s 槽: %s" % [slot, wd.item_name])
	return true


func get_active_weapon_state_name() -> String:
	var wd: WeaponData = get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		return wd.weapon_state_name
	return ""


# ═══════════════════════════════════════
# 消耗品管理（迁自 global.gd:497-558）
# ═══════════════════════════════════════

## 使用治疗品。返回被消耗的物品（供调用方施加 hp_restore/tp_restore），无则返回 null。
func use_healing_item() -> ItemData:
	if not healing_item or healing_item_count <= 0:
		return null
	var used: ItemData = healing_item
	healing_item_count -= 1
	print("[PlayerState] 使用治疗品: %s 剩余 %d" % [used.item_name, healing_item_count])
	if healing_item_count <= 0:
		healing_item = null
		healing_item_count = 0
	return used


## 使用辅助品。返回被消耗的物品，无则返回 null。
func use_support_item() -> ItemData:
	if not support_item:
		return null
	var used: ItemData = support_item
	print("[PlayerState] 使用辅助品: %s" % used.item_name)
	support_item = null
	return used


func pickup_consumable(item: ItemData) -> void:
	if not item:
		return
	match item.item_type:
		ItemData.ItemType.HEALING:
			if healing_item and healing_item.item_id != item.item_id:
				print("[PlayerState] 替换治疗品: %s → %s" % [healing_item.item_name, item.item_name])
				healing_item_count = 0
			healing_item = item
			healing_item_count += 1
			print("[PlayerState] 拾取治疗品: %s ×%d" % [item.item_name, healing_item_count])
		ItemData.ItemType.SUPPORT:
			if support_item:
				print("[PlayerState] 替换辅助品: %s → %s" % [support_item.item_name, item.item_name])
			support_item = item
			print("[PlayerState] 装备辅助品: %s" % item.item_name)
		ItemData.ItemType.THROWABLE:
			if throwable:
				print("[PlayerState] 替换投掷物: %s → %s" % [throwable.item_name, item.item_name])
			throwable = item as ThrowableData
			print("[PlayerState] 装备投掷物: %s" % item.item_name)


# ═══════════════════════════════════════
# 弹药管理（迁自 global.gd:565-599）
# ═══════════════════════════════════════

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
		print("[PlayerState] 弹药不足: 需要 %d, 仅有 %d" % [count, consumed])
		return 0
	indices_to_remove.reverse()
	for idx: int in indices_to_remove:
		inventory.remove_at(idx)
	print("[PlayerState] 消耗弹药: %s ×%d" % [ammo_item_id, consumed])
	return consumed


# ═══════════════════════════════════════
# 背包（迁自 global.gd:431-440）
# ═══════════════════════════════════════

func add_item(item: Resource) -> void:
	if not item:
		return
	inventory.append(item)
	print("[PlayerState] 获得物品: %s" % str(item.get("item_name")))


func remove_item(idx: int) -> void:
	if idx >= 0 and idx < inventory.size():
		var item: Resource = inventory[idx]
		inventory.remove_at(idx)
		print("[PlayerState] 移除物品: %s" % str(item.get("item_name")))


# ═══════════════════════════════════════
# 克隆（内存 checkpoint 用）
# ═══════════════════════════════════════

## 深拷贝本座位状态。语义对齐旧实现的 team.duplicate(true)：
## 容器（equipment/weapon_magazines/inventory）复制一份，
## 资源引用（character / 各 ItemData）按引用保留 —— 不复制资源实例。
func clone() -> PlayerState:
	var c: PlayerState = PlayerState.new()
	c.character = character
	c.character_path = character_path
	c.current_hp = current_hp
	c.current_tp = current_tp
	c.equipment = equipment.duplicate()
	c.active_weapon_slot = active_weapon_slot
	c.weapon_magazines = weapon_magazines.duplicate()
	c.healing_item = healing_item
	c.healing_item_count = healing_item_count
	c.support_item = support_item
	c.throwable = throwable
	c.inventory = inventory.duplicate()
	c.facing = facing
	c.position = position
	c.shove_fatigue_count = shove_fatigue_count
	c.shove_cooldown_timer = shove_cooldown_timer
	c.shove_idle_timer = shove_idle_timer
	c.tp_regen_timer = tp_regen_timer
	c.seat_index = seat_index
	c.owner_peer_id = owner_peer_id
	return c


# ═══════════════════════════════════════
# 磁盘存档序列化
# ═══════════════════════════════════════

## 序列化为可 JSON 化的 Dictionary。物品编解码走 ItemCodec
## （它优先按 resource_path 还原，找不到路径才手动重建 —— 背包里的弹药是
## duplicate() 出来的、没有 resource_path，必须走后者）。
func to_dict() -> Dictionary:
	var inv: Array = []
	for item: Resource in inventory:
		var it: ItemData = item as ItemData
		if it:
			inv.append(ItemCodec.to_dict(it))
	var primary: ItemData = equipment.get("primary") as ItemData
	var secondary: ItemData = equipment.get("secondary") as ItemData
	return {
		"character_path": character_path,
		"current_hp": current_hp,
		"current_tp": current_tp,
		"equipment": {
			"primary": ItemCodec.to_dict(primary) if primary else {},
			"secondary": ItemCodec.to_dict(secondary) if secondary else {},
		},
		"active_weapon_slot": active_weapon_slot,
		"weapon_magazines": weapon_magazines.duplicate(),
		"healing_item": ItemCodec.to_dict(healing_item) if healing_item else {},
		"healing_item_count": healing_item_count,
		"support_item": ItemCodec.to_dict(support_item) if support_item else {},
		"throwable": ItemCodec.to_dict(throwable) if throwable else {},
		"inventory": inv,
		"facing": facing,
		"position_x": position.x,
		"position_y": position.y,
		"shove_fatigue_count": shove_fatigue_count,
		"seat_index": seat_index,
		"owner_peer_id": owner_peer_id,
	}


## 从 to_dict() 的产物还原。character 会 duplicate() 一份，
## 保证每个座位独占实例、不污染资源缓存里的 .tres 母本。
func from_dict(d: Dictionary) -> void:
	var cpath: String = d.get("character_path", "")
	character = null
	character_path = cpath
	if not cpath.is_empty() and ResourceLoader.exists(cpath):
		var res: Resource = load(cpath)
		if res is CharacterData:
			character = (res as CharacterData).duplicate() as CharacterData

	current_hp = d.get("current_hp", get_max_hp())
	current_tp = int(d.get("current_tp", get_max_tp()))

	var eq: Dictionary = d.get("equipment", {})
	equipment = {"primary": null, "secondary": null}
	for slot: String in ["primary", "secondary"]:
		var sd: Dictionary = eq.get(slot, {})
		if not sd.is_empty():
			equipment[slot] = ItemCodec.from_dict(sd)

	active_weapon_slot = d.get("active_weapon_slot", "primary")
	if active_weapon_slot not in equipment:
		active_weapon_slot = "primary"
	# JSON 往返会把整数读成 float，这里强制回 int ——
	# 否则弹夹值会变成 5.0 这种，随存档一路漂下去
	weapon_magazines = {}
	for k: Variant in d.get("weapon_magazines", {}):
		weapon_magazines[k] = int(d["weapon_magazines"][k])

	var hd: Dictionary = d.get("healing_item", {})
	healing_item = ItemCodec.from_dict_or_null(hd)
	healing_item_count = int(d.get("healing_item_count", 0))
	var sud: Dictionary = d.get("support_item", {})
	support_item = ItemCodec.from_dict_or_null(sud)
	var td: Dictionary = d.get("throwable", {})
	throwable = ItemCodec.from_dict_or_null(td) as ThrowableData

	inventory = []
	for elem: Variant in d.get("inventory", []):
		var ed: Dictionary = elem as Dictionary
		if ed:
			var it: ItemData = ItemCodec.from_dict(ed)
			if it:
				inventory.append(it)

	facing = int(d.get("facing", 0))
	position = Vector2(d.get("position_x", 0.0), d.get("position_y", 0.0))
	shove_fatigue_count = int(d.get("shove_fatigue_count", 0))
	seat_index = int(d.get("seat_index", 0))
	owner_peer_id = int(d.get("owner_peer_id", 0))


# ═══════════════════════════════════════
# 调试
# ═══════════════════════════════════════

func describe() -> String:
	var primary: WeaponData = equipment.get("primary") as WeaponData
	return "[座位%d %s HP=%.0f/%.0f TP=%d 主武器=%s 弹夹=%s]" % [
		seat_index,
		get_character_name(),
		current_hp, get_max_hp(),
		current_tp,
		primary.item_name if primary else "无",
		str(weapon_magazines),
	]
