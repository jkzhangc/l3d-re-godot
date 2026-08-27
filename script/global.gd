extends Node
## 全局单例 — 跨场景共享的数据和开关
##
## 这里适合放本机设置、UI 缓存、战役选择和跨场景配置；不要把联机 HP、背包、伤害、敌人等
## 权威事实写在 Global。联机状态由 PlayerState + Players 保存，并由 Host 的 NetworkWorld/Net 写入。
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
	var color_texture := ResourceLoader.load(text_color_sheet_path) as Texture2D
	_cached_color_img = color_texture.get_image() if color_texture else null
	_cached_color_img_path = text_color_sheet_path
	if _cached_color_img:
		print("[Global] 色表缓存: %d×%d" % [_cached_color_img.get_width(), _cached_color_img.get_height()])
	else:
		printerr("[Global] 色表加载失败: %s" % text_color_sheet_path)
	return _cached_color_img


# ═══════════════════════════════════════
# 全队共享数据
# ═══════════════════════════════════════
## gold 为全队共享资源；每名玩家状态由 Players / PlayerState 管理。
var gold: int = 0
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

	var seat_clones: Array[PlayerState] = []
	for s: PlayerState in Players.seats:
		seat_clones.append(s.clone())

	checkpoint = {
		"scene_path": scene_path,
		"seats": seat_clones,
		"active_seat_index": Players.active_seat_index,
		"gold": gold,
		"selected_campaign": selected_campaign,
		"selected_difficulty": selected_difficulty,
	}
	print("[Checkpoint] 已捕获: 场景=%s 座位=%d %s" % [
		scene_path, seat_clones.size(), Players.get_active_state().describe(),
	])

## 返回 checkpoint 中的安全屋场景路径（用于死亡后切回安全屋）
func get_checkpoint_scene() -> String:
	return checkpoint.get("scene_path", "")

## 从内存 checkpoint 恢复游戏状态（死亡时调用）
func restore_checkpoint() -> void:
	if checkpoint.is_empty():
		print("[Checkpoint] 无 checkpoint，保持当前状态")
		return
	var seat_clones: Array = checkpoint.get("seats", [])
	if not seat_clones.is_empty():
		Players.clear_seats()
		for s: PlayerState in seat_clones:
			Players.add_seat(s.clone())
		Players.seats_authored = true
		Players.active_seat_index = clampi(
			checkpoint.get("active_seat_index", 0), 0, Players.seat_count() - 1
		)
	gold = checkpoint.get("gold", 0)
	selected_campaign = checkpoint.get("selected_campaign")
	selected_difficulty = checkpoint.get("selected_difficulty", 0)
	print("[Checkpoint] 已恢复: 座位=%d %s" % [
		Players.seat_count(), Players.get_active_state().describe(),
	])

# ═══════════════════════════════════════
# 队伍管理 —— 已迁至 Players（script/player_registry.gd）
# ═══════════════════════════════════════

## 过渡期 shim：队伍规模。新代码请直接用 Players.seat_count()。
func get_team_size() -> int:
	return Players.seat_count()


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
# 游戏初始化
# ═══════════════════════════════════════

func init_new_game() -> void:
	# 座位表为空时 Players.get_active_state() 会懒创建座位 0（のび太，单角色回退模式），
	# 所以旧实现那条独立的「回退分支」不再需要 —— 两条初始化路径已统一。
	Players.get_active_state()
	Players.active_seat_index = 0
	gold = 0
	corpse_list.clear()
	print("[Global] 新游戏初始化完成 座位=%d %s" % [
		Players.seat_count(), Players.get_active_state().describe(),
	])


func try_load_or_init() -> void:
	if not checkpoint.is_empty():
		# 有 checkpoint → 恢复（死亡重载 / 回到安全屋）
		restore_checkpoint()
		print("[Global] checkpoint 恢复完成 | 座位=%d" % Players.seat_count())
		return

	# 无 checkpoint。座位表不是「菜单/存档/checkpoint 填出来的」才初始化新游戏；
	# 否则保留当前内存状态（从菜单流程过来 / 死亡重载但从未进入过安全屋）。
	# 用 seats_authored 而不是 seat_count()==0 判断 —— 因为任何一次对 Global
	# per-player shim 属性的读取都会触发座位懒创建，seat_count() 不可靠。
	if not Players.seats_authored:
		init_new_game()
	else:
		print("[Global] try_load_or_init: 保留当前状态 | 座位=%d %s" % [
			Players.seat_count(), Players.get_active_state().describe(),
		])
