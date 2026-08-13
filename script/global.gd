extends Node
## 全局单例 — 跨场景共享的数据和开关

# ═══════════════════════════════════════
# Debug 开关
# ═══════════════════════════════════════
var debug_enabled: bool = true:
	set(v):
		debug_enabled = v
		print("[Global] debug = %s" % v)

var debug_visuals: bool = false

# ═══════════════════════════════════════
# 设置（音量 / 固定朝向）
# ═══════════════════════════════════════
var music_volume: int = 80      ## 音乐音量 0–100
var sfx_volume: int = 80        ## 音效音量 0–100
var facing_lock_mode: int = 0   ## 固定朝向模式: 0=切换式, 1=按住式

# ═══════════════════════════════════════
# 文字渲染全局设置（各 UI 场景读取这些默认值）
# ═══════════════════════════════════════
@export_group("文字默认")
@export var text_font_path: String = "res://art/System/ark-pixel-16px-monospaced-zh_cn.ttf"
@export var text_font_path_small: String = "res://art/System/ark-pixel-12px-monospaced-zh_cn.ttf"  ## 12px 小字专用
@export var text_color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var text_color_shader_path: String = "res://shader/text_color.gdshader"
@export var text_color_index: int = 0
@export var text_color_row: int = 0
@export var text_gradient_enabled: bool = true
@export var text_bold: bool = false
@export var text_outline: bool = false
@export var text_outline_color: Color = Color.BLACK
@export var text_outline_width: float = 1.0
@export var text_shadow: bool = true
@export var text_shadow_color: Color = Color(0, 0, 0, 0.6)
@export var text_shadow_offset: Vector2 = Vector2(2, 2)

# ═══════════════════════════════════════
# 文字资源缓存（避免重复 Image.load_from_file）
# ═══════════════════════════════════════
var _cached_color_img: Image = null
var _cached_color_img_path: String = ""


## 返回缓存的色表 Image，供 GradientLabel 共享使用。
## Image.load_from_file() 无缓存，统一从这里获取避免重复 I/O。
func get_cached_color_image() -> Image:
	if _cached_color_img and _cached_color_img_path == text_color_sheet_path:
		return _cached_color_img
	_cached_color_img = Image.load_from_file(text_color_sheet_path)
	_cached_color_img_path = text_color_sheet_path
	if _cached_color_img:
		print("[Global] 色表缓存: %d×%d" % [_cached_color_img.get_width(), _cached_color_img.get_height()])
	else:
		printerr("[Global] 色表加载失败: %s" % text_color_sheet_path)
	return _cached_color_img


# ═══════════════════════════════════════
# 玩家数据
# ═══════════════════════════════════════
var player_character: Resource = null
var inventory: Array = []
var player_hp: float = 200.0
var player_tp: int = 0                        ## 当前队员 TP（技能点）
var gold: int = 0

# ═══════════════════════════════════════
# 武器装备
# ═══════════════════════════════════════
var equipment: Dictionary = {"primary": null, "secondary": null}
var active_weapon_slot: String = "primary"

# ═══════════════════════════════════════
# 消耗品装备
# ═══════════════════════════════════════
var healing_item: ItemData = null
var healing_item_count: int = 0  ## 治疗品数量（医疗包 UI 显示）
var support_item: ItemData = null
var throwable: ThrowableData = null           ## 当前投掷物（单槽位，数字5键使用）

# ═══════════════════════════════════════
# 弹药 & 弹夹
# ═══════════════════════════════════════
var weapon_magazines: Dictionary = {}

# ═══════════════════════════════════════
# 队伍数据（角色切换系统）
# ═══════════════════════════════════════
## 队伍成员列表，每个是一个 Dictionary:
##   character: CharacterData       — 角色资源
##   current_hp: float              — 当前 HP
##   equipment: Dictionary          — {primary: WeaponData, secondary: WeaponData}
##   weapon_magazines: Dictionary   — item_id → 弹夹子弹数
##   active_weapon_slot: String     — "primary" 或 "secondary"
##   facing: int                    — 最后朝向 (FaceDir)
##   position: Vector2              — 场景位置
##   healing_item: ItemData         — 消耗品
##   support_item: ItemData         — 消耗品
##   inventory: Array               — 背包物品
var team: Array[Dictionary] = []
var current_team_index: int = 0

# ═══════════════════════════════════════
# 战役 / 难度
# ═══════════════════════════════════════
var selected_campaign: CampaignData = null
var selected_difficulty: int = 0  ## 0=Easy, 1=Normal, 2=Hard, 3=Expert
var difficulty_multipliers: Dictionary = {
	0: {"enemy_hp": 0.7, "enemy_damage": 0.5, "director_intensity": 0.6},
	1: {"enemy_hp": 1.0, "enemy_damage": 1.0, "director_intensity": 1.0},
	2: {"enemy_hp": 1.5, "enemy_damage": 1.5, "director_intensity": 1.5},
	3: {"enemy_hp": 2.0, "enemy_damage": 2.0, "director_intensity": 2.0},
}

# ═══════════════════════════════════════
# 尸体管理
# ═══════════════════════════════════════
var corpse_list: Array = []
@export var max_corpses: int = 20
@export var corpses_to_remove: int = 10

# ═══════════════════════════════════════
# 死亡处理
# ═══════════════════════════════════════
@export var death_music_path: String = "res://sound/残念なお知らせ.wav"  ## 死亡音乐文件路径（如 "res://music/death.ogg"）
@export var death_fade_duration: float = 10.0  ## 死亡黑屏淡入时长（秒）
@export var death_black_hold: float = 2.0     ## 死亡全黑后等待时长（秒）
@export var death_music_volume_db: float = -10.0  ## 死亡音乐音量（dB, 0 为原始音量）
const CONFIG_FILE: String = "res://config.json"


func _ready() -> void:
	_load_config()
	_ensure_audio_buses()


# ═══════════════════════════════════════
# 内存 Checkpoint（安全屋存档点）
# ═══════════════════════════════════════
var checkpoint: Dictionary = {}  ## 安全屋捕获的快照（仅在内存中，不写磁盘）

## 在安全屋捕获 checkpoint —— 深拷贝当前状态为快照
func capture_checkpoint() -> void:
	var scene_path: String = ""
	if get_tree() and get_tree().current_scene:
		scene_path = get_tree().current_scene.scene_file_path

	_save_global_to_team_member(current_team_index)
	checkpoint = {
		"scene_path": scene_path,
		"player_hp": player_hp,
		"player_tp": player_tp,
		"equipment_primary": equipment.get("primary"),
		"equipment_secondary": equipment.get("secondary"),
		"active_weapon_slot": active_weapon_slot,
		"weapon_magazines": weapon_magazines.duplicate(),
		"inventory": inventory.duplicate(),
		"healing_item": healing_item,
		"healing_item_count": healing_item_count,
		"support_item": support_item,
		"throwable": throwable,
		"gold": gold,
		"team": team.duplicate(true),
		"current_team_index": current_team_index,
		"selected_campaign": selected_campaign,
		"selected_difficulty": selected_difficulty,
	}
	print("[Checkpoint] 已捕获: 场景=%s HP=%.0f 主武器=%s 弹夹=%s 物品=%d" % [
		scene_path, player_hp,
		(equipment.get("primary") as WeaponData).item_name if equipment.get("primary") else "无",
		str(weapon_magazines),
		inventory.size(),
	])

## 返回 checkpoint 中的安全屋场景路径（用于死亡后切回安全屋）
func get_checkpoint_scene() -> String:
	return checkpoint.get("scene_path", "")

## 从内存 checkpoint 恢复游戏状态（死亡时调用）
func restore_checkpoint() -> void:
	if checkpoint.is_empty():
		print("[Checkpoint] 无 checkpoint，保持当前状态")
		return
	player_hp = checkpoint.get("player_hp", 200.0)
	player_tp = checkpoint.get("player_tp", 0)
	equipment["primary"] = checkpoint.get("equipment_primary")
	equipment["secondary"] = checkpoint.get("equipment_secondary")
	active_weapon_slot = checkpoint.get("active_weapon_slot", "primary")
	weapon_magazines = checkpoint.get("weapon_magazines", {}).duplicate()
	inventory = checkpoint.get("inventory", []).duplicate()
	healing_item = checkpoint.get("healing_item")
	healing_item_count = checkpoint.get("healing_item_count", 0)
	support_item = checkpoint.get("support_item")
	throwable = checkpoint.get("throwable")
	gold = checkpoint.get("gold", 0)
	# 恢复队伍
	if checkpoint.has("team"):
		team = checkpoint["team"].duplicate(true)
		current_team_index = checkpoint.get("current_team_index", 0)
		_apply_team_member_to_global(current_team_index)
	selected_campaign = checkpoint.get("selected_campaign")
	selected_difficulty = checkpoint.get("selected_difficulty", 0)
	print("[Checkpoint] 已恢复: HP=%.0f 主武器=%s 弹夹=%s 物品=%d 队伍=%d" % [
		player_hp,
		(equipment.get("primary") as WeaponData).item_name if equipment.get("primary") else "无",
		str(weapon_magazines),
		inventory.size(),
		team.size(),
	])

# ═══════════════════════════════════════
# 队伍管理
# ═══════════════════════════════════════

## 将指定索引的队员数据加载到当前 Global 读写字段
func _apply_team_member_to_global(index: int) -> void:
	if index < 0 or index >= team.size():
		return
	var member: Dictionary = team[index]
	player_character = member.get("character")
	player_hp = member.get("current_hp", 200.0)
	player_tp = member.get("current_tp", 0)
	equipment = member.get("equipment", {"primary": null, "secondary": null}).duplicate()
	weapon_magazines = member.get("weapon_magazines", {}).duplicate()
	active_weapon_slot = member.get("active_weapon_slot", "primary")
	if active_weapon_slot not in equipment:
		active_weapon_slot = "primary"
	healing_item = member.get("healing_item")
	healing_item_count = member.get("healing_item_count", 0)
	support_item = member.get("support_item")
	throwable = member.get("throwable")
	inventory = member.get("inventory", []).duplicate()


## 从当前 Global 字段保存到指定索引的队员数据
func _save_global_to_team_member(index: int) -> void:
	if index < 0 or index >= team.size():
		return
	var member: Dictionary = team[index]
	member["character"] = player_character
	member["current_hp"] = player_hp
	member["current_tp"] = player_tp
	member["equipment"] = equipment.duplicate()
	member["weapon_magazines"] = weapon_magazines.duplicate()
	member["active_weapon_slot"] = active_weapon_slot
	member["healing_item"] = healing_item
	member["healing_item_count"] = healing_item_count
	member["support_item"] = support_item
	member["throwable"] = throwable
	member["inventory"] = inventory.duplicate()


## 获取当前队员数据字典（先保存再返回）
func get_current_team_member() -> Dictionary:
	if team.size() == 0:
		return {}
	_save_global_to_team_member(current_team_index)
	return team[current_team_index]


## 队伍总人数
func get_team_size() -> int:
	return team.size()


## 切换到队伍中指定索引的成员
func set_active_team_index(index: int) -> void:
	if index < 0 or index >= team.size():
		return
	current_team_index = index
	_apply_team_member_to_global(index)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("调试可视化键"):
		debug_visuals = not debug_visuals
		print("[Global] 调试可视化: %s" % ("开启" if debug_visuals else "关闭"))
		# 切换导航网格可视化
		ProjectSettings.set_setting("debug/navigation/enable_edge_lines", debug_visuals)
		ProjectSettings.set_setting("debug/navigation/enable_geometry_face_random_color", debug_visuals)
		var tree: SceneTree = get_tree()
		if tree:
			var root: Window = tree.root
			if root:
				_trigger_redraw_recursive(root)


func _trigger_redraw_recursive(node: Node) -> void:
	if node is CanvasItem:
		(node as CanvasItem).queue_redraw()
	for child: Node in node.get_children():
		_trigger_redraw_recursive(child)


func _load_config() -> void:
	if FileAccess.file_exists(CONFIG_FILE):
		var f: FileAccess = FileAccess.open(CONFIG_FILE, FileAccess.READ)
		if f:
			var text: String = f.get_as_text()
			f.close()
			var cfg: Dictionary = JSON.parse_string(text) if text else {}
			if cfg:
				debug_enabled = cfg.get("debug", false)
				music_volume = cfg.get("music_volume", 80)
				sfx_volume = cfg.get("sfx_volume", 80)
				facing_lock_mode = cfg.get("facing_lock_mode", 0)


func save_config() -> void:
	var cfg: Dictionary = {
		"debug": debug_enabled,
		"music_volume": music_volume,
		"sfx_volume": sfx_volume,
		"facing_lock_mode": facing_lock_mode
	}
	var f: FileAccess = FileAccess.open(CONFIG_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(cfg, "\t"))
		f.close()


# ═══════════════════════════════════════
# 音频总管理
# ═══════════════════════════════════════

@export var max_sfx_concurrency: int = 4  ## 同一音效最大同时播放数（防止音量叠加）

## 同一音效资源的活跃播放器计数（resource_path → Array[AudioStreamPlayer]）
var _active_sfx: Dictionary = {}

## 播放音效（带并发限制，防止同音效多实例叠加导致音量过大）。
## 超过 max_sfx_concurrency 的新请求会被丢弃。
func play_sfx_managed(stream: AudioStream, parent: Node) -> void:
	if not stream:
		return

	var key := stream.resource_path
	if key.is_empty():
		key = "inline_%d" % stream.get_instance_id()

	# 清理已完成/已释放的播放器
	var arr: Array = _active_sfx.get(key, [])
	var i: int = arr.size() - 1
	while i >= 0:
		if not is_instance_valid(arr[i]) or not (arr[i] as AudioStreamPlayer).playing:
			arr.remove_at(i)
		i -= 1

	if arr.size() >= max_sfx_concurrency:
		return  # 丢弃，防止音量叠加

	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = "SFX"
	player.autoplay = true
	var cb: Callable = func():
		arr.erase(player)
		player.queue_free()
	player.finished.connect(cb)
	parent.add_child(player)
	arr.append(player)
	_active_sfx[key] = arr


func _ensure_audio_buses() -> void:
	var bc: int = AudioServer.bus_count
	if bc < 2:
		AudioServer.add_bus(1)
	if bc < 3:
		AudioServer.add_bus(2)
	AudioServer.set_bus_name(1, "SFX")
	AudioServer.set_bus_name(2, "Music")
	_apply_volume()
	print("[Global] 音频总线已创建: Master, SFX, Music")


func _apply_volume() -> void:
	var sfx_idx: int = AudioServer.get_bus_index("SFX")
	var music_idx: int = AudioServer.get_bus_index("Music")
	if sfx_idx >= 0:
		AudioServer.set_bus_volume_db(sfx_idx, linear_to_db(sfx_volume / 100.0))
	if music_idx >= 0:
		AudioServer.set_bus_volume_db(music_idx, linear_to_db(music_volume / 100.0))


func set_music_volume(pct: int) -> void:
	music_volume = clampi(pct, 0, 100)
	_apply_volume()
	save_config()


func set_sfx_volume(pct: int) -> void:
	sfx_volume = clampi(pct, 0, 100)
	_apply_volume()
	save_config()


func set_facing_lock_mode(mode: int) -> void:
	facing_lock_mode = clampi(mode, 0, 1)
	save_config()


# ═══════════════════════════════════════
# 尸体管理
# ═══════════════════════════════════════

func register_corpse(corpse: Node2D) -> void:
	corpse_list.append(corpse)
	print("[Global] 尸体注册: 当前 %d 具（上限 %d）" % [corpse_list.size(), max_corpses])
	if corpse_list.size() > max_corpses:
		_cleanup_corpses()


func _cleanup_corpses() -> void:
	var remove_count: int = mini(corpses_to_remove, corpse_list.size())
	print("[Global] 尸体超限！移除最旧 %d 具..." % remove_count)
	for i: int in range(remove_count):
		var corpse: Node2D = corpse_list[i] as Node2D
		if corpse and is_instance_valid(corpse):
			corpse.queue_free()
	corpse_list = corpse_list.slice(remove_count)


# ═══════════════════════════════════════
# 背包
# ═══════════════════════════════════════

func add_item(item: Resource) -> void:
	inventory.append(item)
	print("[Global] 获得物品: %s" % item.get("item_name") if item else "?")


func remove_item(idx: int) -> void:
	if idx >= 0 and idx < inventory.size():
		var item: Resource = inventory[idx]
		inventory.remove_at(idx)
		print("[Global] 移除物品: %s" % item.get("item_name") if item else "?")


# ═══════════════════════════════════════
# 武器装备管理
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
		print("[Global] 卸下 %s 槽: %s" % [slot, old.item_name])
	equipment[slot] = wd
	print("[Global] 装备到 %s 槽: %s" % [slot, wd.item_name])


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
	print("[Global] 切换到 %s 槽: %s" % [slot, wd.item_name])
	return true


func get_active_weapon_state_name() -> String:
	var wd: WeaponData = get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		return wd.weapon_state_name
	return ""


# ═══════════════════════════════════════
# 消耗品管理
# ═══════════════════════════════════════

func use_healing_item() -> bool:
	if not healing_item or healing_item_count <= 0:
		return false
	healing_item_count -= 1
	print("[Global] 使用治疗品: %s 剩余 %d" % [healing_item.item_name, healing_item_count])
	_apply_item_effects(healing_item)
	if healing_item_count <= 0:
		healing_item = null
		healing_item_count = 0
	return true


func use_support_item() -> bool:
	if not support_item:
		return false
	print("[Global] 使用辅助品: %s" % support_item.item_name)
	_apply_item_effects(support_item)
	support_item = null
	return true


## 应用物品的使用效果（HP/TP 回复）
func _apply_item_effects(item: ItemData) -> void:
	if not item:
		return
	var player := _find_player_node()
	if not player:
		return
	if item.hp_restore > 0 and player.has_method("heal"):
		player.heal(item.hp_restore)
	if item.tp_restore > 0 and player.has_method("restore_tp"):
		player.restore_tp(item.tp_restore)


## 查找当前玩家节点（group "player"）
func _find_player_node() -> Node:
	var nodes := get_tree().get_nodes_in_group("player")
	for n: Node in nodes:
		if n is CharacterBody2D:
			return n
	return null


func pickup_consumable(item: ItemData) -> void:
	match item.item_type:
		ItemData.ItemType.HEALING:
			if healing_item and healing_item.item_id != item.item_id:
				print("[Global] 替换治疗品: %s → %s" % [healing_item.item_name, item.item_name])
				healing_item_count = 0
			healing_item = item
			healing_item_count += 1
			print("[Global] 拾取治疗品: %s ×%d" % [item.item_name, healing_item_count])
		ItemData.ItemType.SUPPORT:
			if support_item:
				print("[Global] 替换辅助品: %s → %s" % [support_item.item_name, item.item_name])
			support_item = item
			print("[Global] 装备辅助品: %s" % item.item_name)
		ItemData.ItemType.THROWABLE:
			if throwable:
				print("[Global] 替换投掷物: %s → %s" % [throwable.item_name, item.item_name])
			throwable = item as ThrowableData
			print("[Global] 装备投掷物: %s" % item.item_name)


# ═══════════════════════════════════════
# 弹药管理
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
		print("[Global] 弹药不足: 需要 %d, 仅有 %d" % [count, consumed])
		return 0
	indices_to_remove.reverse()
	for idx: int in indices_to_remove:
		inventory.remove_at(idx)
	print("[Global] 消耗弹药: %s ×%d" % [ammo_item_id, consumed])
	return consumed


# ═══════════════════════════════════════
# 游戏初始化
# ═══════════════════════════════════════

func init_new_game() -> void:
	# 如果队伍非空（由角色选择界面设置），初始化第一个队员
	if team.size() > 0:
		current_team_index = 0
		_apply_team_member_to_global(0)
		corpse_list.clear()
		print("[Global] 新游戏初始化完成 队伍=%d人 HP=%.0f" % [team.size(), player_hp])
		return
	# 回退：单角色模式
	player_character = load("res://object/character_nobita.tres") as CharacterData
	inventory.clear()
	equipment["primary"] = null
	equipment["secondary"] = null
	active_weapon_slot = "primary"
	healing_item = null
	healing_item_count = 0
	support_item = null
	throwable = null
	weapon_magazines.clear()
	gold = 0
	player_hp = 200.0
	player_tp = (player_character as CharacterData).get_effective_max_tp()
	corpse_list.clear()
	print("[Global] 新游戏初始化完成（单角色回退模式）")


func try_load_or_init() -> void:
	if not player_character:
		player_character = load("res://object/character_nobita.tres") as CharacterData

	if not checkpoint.is_empty():
		# 有 checkpoint → 恢复（死亡重载 / 回到安全屋）
		restore_checkpoint()
		print("[Global] checkpoint 恢复完成 | HP=%.0f | 队伍=%d" % [player_hp, team.size()])
		return

	# 无 checkpoint。仅首次启动（装备为空 且 队伍为空）时初始化新游戏；
	# 否则保留当前内存状态（死亡重载但从未进入过安全屋）
	if equipment.get("primary") == null and equipment.get("secondary") == null and team.size() == 0:
		init_new_game()
	else:
		# 有队伍数据（从菜单流程过来），应用第一个队员
		if team.size() > 0:
			_apply_team_member_to_global(current_team_index)
		print("[Global] try_load_or_init: 保留当前状态 | HP=%.0f | 队伍=%d" % [player_hp, team.size()])
