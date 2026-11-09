extends Node

## 角色名册 / 武器行走图白名单 一致性检查（2026-11-09）。
## 用法：godot --headless --path . res://tools/character_roster_check.tscn
##
## 守三件事：
##  1. 角色目录能载入全部正式角色（含安雄 `yasuo`），且每人都有行走图；
##  2. **白名单 ⊆ 「有图可拿」**：`allowed_*_weapons` 里出现的武器，角色必须真的画了
##     对应 `weapon_state_name` 的行走图（或该武器自带通用近战身体）——
##     否则会出现「允许拿、但举枪瞬间变回大雄」的老问题；
##  3. 安雄的安全屋台词在全部场景/批次里都有（台词表早于角色存在，怕漏配）。

const CATALOG := preload("res://script/character_catalog.gd")
const DIALOGUES := preload("res://script/safehouse_dialogue_data.gd")

var _fail := 0


func _check(label: String, got, want) -> void:
	if got == want:
		print("  OK   %s = %s" % [label, str(got)])
	else:
		_fail += 1
		print("  FAIL %s = %s（期望 %s）" % [label, str(got), str(want)])


func _ready() -> void:
	await get_tree().process_frame
	var chars: Array[CharacterData] = CATALOG.load_available_characters()
	_check("角色数量", chars.size(), 5)

	var ids: Array[String] = []
	for cd: CharacterData in chars:
		ids.append(cd.character_id)
	_check("含安雄 yasuo", ids.has("yasuo"), true)
	print("  · 名册: %s" % str(ids))

	print("=== 1) 每个角色都有行走图 ===")
	for cd: CharacterData in chars:
		_check("%s walk_texture" % cd.character_id, cd.walk_texture != null, true)

	print("=== 2) 安雄的武器行走图映射 ===")
	var anyu: CharacterData = null
	for cd: CharacterData in chars:
		if cd.character_id == "yasuo":
			anyu = cd
	_check("找到安雄", anyu != null, true)
	if anyu != null:
		for state: String in ["Pistol", "Smg", "Rifle", "Shotgun", "Launcher", "RLauncher", "RLauncher2", "Stinger", "Bowgun", "Melee", "Melee_LR"]:
			_check("有 %s 图" % state, anyu.get_weapon_walk_texture(state) != null, true)
		_check("手枪可用（有图）", anyu.has_weapon_walk_art(load("res://object/weapon_pistol.tres")), true)
		_check("马格南不可用（无图）", anyu.has_weapon_walk_art(load("res://object/weapon_magnum.tres")), false)
		_check("RPG 可用（有图）", anyu.has_weapon_walk_art(load("res://object/weapon_rocket_launcher.tres")), true)
		_check("demolition = true（说明书：デモリション）", anyu.demolition, true)
		_check("yasuo_soul = true（安雄魂）", anyu.yasuo_soul, true)
		_check("self_blast_immune = true（自爆无效）", anyu.self_blast_immune, true)
		_check("portrait 非空", anyu.portrait != null, true)
		_check("portrait_index = 4", anyu.portrait_index, 4)
		## 选人图标：用默认图标表的 R2-3（红帽子+绿衣 = 安雄），不拿自己的行走图顶。
		_check("select_icon_sheet 为空（用默认图标表）", anyu.select_icon_sheet == null, true)
		_check("select_icon_index = 2", anyu.select_icon_index, 2)
		_check("select_icon_direction = 1", anyu.select_icon_direction, 1)

	print("=== 3) 白名单里不能出现「没图的武器」 ===")
	var weapon_paths: Array[String] = []
	var dir := DirAccess.open("res://object")
	if dir:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while not fn.is_empty():
			if fn.begins_with("weapon_") and fn.ends_with(".tres"):
				weapon_paths.append("res://object/" + fn)
			fn = dir.get_next()
		dir.list_dir_end()
	var by_id: Dictionary = {}
	for p: String in weapon_paths:
		var wd := load(p) as WeaponData
		if wd != null:
			by_id[wd.item_id] = wd
	_check("武器表非空", by_id.size() > 30, true)

	for cd: CharacterData in chars:
		var bad: Array[String] = []
		var all_allowed: Array[String] = []
		all_allowed.append_array(cd.allowed_primary_weapons)
		all_allowed.append_array(cd.allowed_secondary_weapons)
		for wid: String in all_allowed:
			var wd: WeaponData = by_id.get(wid)
			if wd == null:
				bad.append(wid + "(不存在)")
			elif not cd.has_weapon_walk_art(wd):
				bad.append(wid + "(无图)")
		_check("%s 白名单均可拿" % cd.character_id, bad.is_empty(), true)
		if not bad.is_empty():
			print("       → %s" % str(bad))

	print("=== 4) 安雄安全屋台词覆盖 ===")
	var missing: Array[String] = []
	for scene_key: String in DIALOGUES.DIALOGUES.keys():
		var batches: Dictionary = DIALOGUES.DIALOGUES[scene_key]
		for batch: String in batches.keys():
			if not (batches[batch] as Dictionary).has("yasuo"):
				missing.append("%s/%s" % [scene_key, batch])
	_check("所有场景批次都有 yasuo", missing.is_empty(), true)
	if not missing.is_empty():
		print("       → %s" % str(missing))

	print("\n失败 %d 项" % _fail)
	await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)
