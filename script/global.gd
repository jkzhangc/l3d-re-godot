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
@export var text_font_path: String = "res://art/System/SimsunXS_12_GB18030_J.ttf"
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
var support_item: ItemData = null

# ═══════════════════════════════════════
# 弹药 & 弹夹
# ═══════════════════════════════════════
var weapon_magazines: Dictionary = {}

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

# ═══════════════════════════════════════
# 存档路径
# ═══════════════════════════════════════
const SAVE_DIR: String = "res://saves/"
const SAVE_FILE: String = "save_data.json"
const CONFIG_FILE: String = "res://config.json"


func _ready() -> void:
	_load_config()
	_ensure_audio_buses()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_clear_save_on_quit()


func _clear_save_on_quit() -> void:
	var path: String = SAVE_DIR + SAVE_FILE
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		print("[Global] 退出游戏，存档已清除")


func _exit_tree() -> void:
	_clear_save_on_quit()


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
	if not healing_item:
		return false
	print("[Global] 使用治疗品: %s" % healing_item.item_name)
	healing_item = null
	return true


func use_support_item() -> bool:
	if not support_item:
		return false
	print("[Global] 使用辅助品: %s" % support_item.item_name)
	support_item = null
	return true


func pickup_consumable(item: ItemData) -> void:
	match item.item_type:
		ItemData.ItemType.HEALING:
			if healing_item:
				print("[Global] 替换治疗品: %s → %s" % [healing_item.item_name, item.item_name])
			healing_item = item
			print("[Global] 装备治疗品: %s" % item.item_name)
		ItemData.ItemType.SUPPORT:
			if support_item:
				print("[Global] 替换辅助品: %s → %s" % [support_item.item_name, item.item_name])
			support_item = item
			print("[Global] 装备辅助品: %s" % item.item_name)


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
	player_character = load("res://object/character_nobita.tres") as CharacterData
	inventory.clear()
	equipment["primary"] = null
	equipment["secondary"] = null
	active_weapon_slot = "primary"
	healing_item = null
	support_item = null
	weapon_magazines.clear()
	gold = 0
	player_hp = 200.0
	corpse_list.clear()

	add_item(load("res://object/weapon_pistol.tres") as ItemData)
	add_item(load("res://object/weapon_knife.tres") as ItemData)

	pickup_consumable(load("res://object/item_medkit.tres") as ItemData)
	pickup_consumable(load("res://object/item_pills.tres") as ItemData)

	for _i: int in range(20):
		add_item(load("res://object/item_pistol_ammo.tres") as ItemData)

	weapon_magazines["pistol_01"] = 12

	print("[Global] 新游戏初始化完成")


func try_load_or_init() -> void:
	if SaveManager.auto_load_on_start():
		if not player_character:
			player_character = load("res://object/character_nobita.tres") as CharacterData
		print("[Global] 存档加载成功 | HP=%.0f" % player_hp)
	else:
		init_new_game()
