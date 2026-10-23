extends RefCounted

## ── 架构定位 ──
## 系统：音频服务 ｜ 层：服务类（RefCounted，由 Global 持有）
## 联机：纯本机表现，与联机无关
## 职责：音频总线（Master/SFX/Music）、音量应用、SFX 并发限制与 voice stealing、
##       UI 窗口音效、拾取音效、大厅 BGM。
## 依赖：宿主节点（Global，提供 get_tree / save_config / 音频配置项）
##
## 【为什么从 global.gd 抽出（2026-10-08）】音频逻辑约 180 行、与字体/触摸布局/存档等
## 职责无关，且外部调用一律走 `Global.<方法>`。抽出后 Global 只保留同名转发门面 →
## 外部调用点零改动。
##
## 【配置项的归属】`@export` 的音频配置（并发上限、UI/拾取音效路径）**留在 Global**，
## 本服务经 `_host` 读取 —— 这样不改变 Global 作为 autoload 的 @export 语义。
## `music_volume` / `sfx_volume` 由**本服务持有**，Global 用 getter/setter 代理，
## 使 `Global._apply_config_file` / `save_config` 零改动。

## 宿主节点（Global），用于配置读取、挂播放器、回调 save_config。
var _host: Node = null

## 音乐/音效/BGS（环境音）音量 0–100（config 持久化；Global 以属性代理暴露）。
var music_volume: int = 80
var sfx_volume: int = 80
## 环境音（地图 BGS：虫鸣/风声/室内的空调声…）独立音量。
## 2026-10-23：地图里的 `BGS` AudioStreamPlayer 原本直连 Master，设置里的音乐/音效
## 两个滑条都管不到它（和 2026-09-13 fire_patch 漏网是同一类问题）。
var bgs_volume: int = 80

## 同一音效资源的活跃播放器计数（resource_path → Array[AudioStreamPlayer]）
var _active_sfx: Dictionary = {}
## 大厅 BGM 播放器（挂在宿主上，切界面不释放 → 音乐连续）。
var _lobby_music_player: AudioStreamPlayer = null

const LOBBY_MUSIC_PATH: String = "res://music/l3d_lobby.mp3"

## ── 世界音效距离衰减（2026-10-20 用户需求）──
## 「敌人发出的各种声音」与「联机时其他玩家开枪等各种声音」都要随距离变小。
## 实际数值由 Global 的 @export 提供（AudioService 每次播放时读取，改默认值即生效）：
##   world_sfx_max_distance     —— 超过此距离完全无声（世界像素；视口 1280×960、可见半径≈640×480）
##   world_sfx_attenuation      —— 衰减指数（1=线性，越大远处掉得越快）
##   world_sfx_panning_strength —— 左右声像强度（0=不作声像，1=完全按相对方位偏声）
## 宿主缺失（harness 裸实例）时用这组保守默认。
const DEFAULT_WORLD_SFX_MAX_DISTANCE: float = 1000.0
const DEFAULT_WORLD_SFX_ATTENUATION: float = 1.4
const DEFAULT_WORLD_SFX_PANNING_STRENGTH: float = 0.8


func _init(host: Node) -> void:
	_host = host


# ═══════════════════════════════════════
# 主体：总线与音量
# ═══════════════════════════════════════

func ensure_audio_buses() -> void:
	var bc: int = AudioServer.bus_count
	if bc < 2:
		AudioServer.add_bus(1)
	if bc < 3:
		AudioServer.add_bus(2)
	if bc < 4:
		AudioServer.add_bus(3)
	AudioServer.set_bus_name(1, "SFX")
	AudioServer.set_bus_name(2, "Music")
	AudioServer.set_bus_name(3, "BGS")
	apply_volume()
	print("[Global] 音频总线已创建: Master, SFX, Music, BGS")


func apply_volume() -> void:
	var sfx_idx: int = AudioServer.get_bus_index("SFX")
	var music_idx: int = AudioServer.get_bus_index("Music")
	var bgs_idx: int = AudioServer.get_bus_index("BGS")
	if sfx_idx >= 0:
		AudioServer.set_bus_volume_db(sfx_idx, linear_to_db(sfx_volume / 100.0))
	if music_idx >= 0:
		AudioServer.set_bus_volume_db(music_idx, linear_to_db(music_volume / 100.0))
	if bgs_idx >= 0:
		## 0% 用 -80dB 而不是线性值本身：linear_to_db(0) 是 -inf，部分平台会报错。
		AudioServer.set_bus_volume_db(bgs_idx, linear_to_db(maxf(bgs_volume / 100.0, 0.0001)))


func set_music_volume(pct: int) -> void:
	music_volume = clampi(pct, 0, 100)
	apply_volume()
	if _host != null and _host.has_method("save_config"):
		_host.call("save_config")


func set_sfx_volume(pct: int) -> void:
	sfx_volume = clampi(pct, 0, 100)
	apply_volume()
	if _host != null and _host.has_method("save_config"):
		_host.call("save_config")


func set_bgs_volume(pct: int) -> void:
	bgs_volume = clampi(pct, 0, 100)
	apply_volume()
	if _host != null and _host.has_method("save_config"):
		_host.call("save_config")


# ═══════════════════════════════════════
# 音效播放（带并发限制）
# ═══════════════════════════════════════

## 播放音效（带并发限制，防止同音效多实例叠加导致音量过大）。
## positional=true 且 parent 是 Node2D 时用 AudioStreamPlayer2D —— 音量随距离衰减、
## 带声像（丧尸叫等世界内音效必须走这个，否则屏外的僵尸和贴脸的一样响）。
##
## `at_position`：世界坐标定位点（默认 Vector2.INF = 用 parent 自身位置）。
## 供「播放当刻就要消失」的宿主（子弹命中/投掷物爆炸）使用 —— 播放器挂场景、
## 声源钉在该点，既不会被宿主 queue_free 截断，也不会跟着已消失的物体跑。
func play_sfx_managed(stream: AudioStream, parent: Node, positional: bool = false, pitch: float = 1.0,
		at_position: Vector2 = Vector2.INF) -> void:
	if not stream:
		return

	var key := stream.resource_path
	if key.is_empty():
		key = "inline_%d" % stream.get_instance_id()

	# 清理已完成/已释放的播放器
	var arr: Array = _active_sfx.get(key, [])
	var i: int = arr.size() - 1
	while i >= 0:
		# AudioStreamPlayer 与 AudioStreamPlayer2D 不是同一继承链，用鸭子读取 playing
		if not is_instance_valid(arr[i]) or not arr[i].playing:
			arr.remove_at(i)
		i -= 1

	var concurrency: int = _max_sfx_concurrency()
	if arr.size() >= concurrency:
		# 声音窃取（voice stealing）：停掉最旧的，让新触发的音效必有声。
		# 旧实现「丢弃新的」会让连发武器的枪声每隔几发漏一声（枪口火光有、声音没有，
		# 用户 2026-09-13 回归：发射音效跟全局不同步）。总并发仍被上限封顶。
		var oldest: Node = arr[0]
		if is_instance_valid(oldest):
			oldest.stop()
			oldest.queue_free()
		arr.remove_at(0)

	var player: Node = null
	if positional and parent is Node2D:
		var p2d := AudioStreamPlayer2D.new()
		# 可视世界半径 ≈ 分辨率/2（zoom=2x）≈ 640×480，屏角 ≈800。
		# 旧实现固定 max_distance=1100 + 默认线性衰减：屏边(640) 还剩 -7.5dB，
		# 听感上「远处的僵尸和贴脸的一样响」（2026-10-20 用户反馈的根因）。
		# 现改为「1000 处静音 + attenuation 指数」，屏边约 -12dB、屏角约 -20dB。
		p2d.max_distance = _world_sfx_max_distance()
		p2d.attenuation = _world_sfx_attenuation()
		p2d.panning_strength = _world_sfx_panning_strength()
		player = p2d
	else:
		player = AudioStreamPlayer.new()
	player.stream = stream
	player.bus = "SFX"
	player.autoplay = true
	player.pitch_scale = pitch  ## 每音效音调（2026-09-15：敌人各音效可独立设调）
	var cb: Callable = func():
		arr.erase(player)
		player.queue_free()
	player.finished.connect(cb)
	parent.add_child(player)
	## 世界坐标定位：播放器已入树才能写 global_position（未入树时 global==local）。
	if positional and at_position.is_finite() and player is AudioStreamPlayer2D:
		(player as AudioStreamPlayer2D).global_position = at_position
	arr.append(player)
	_active_sfx[key] = arr


## 玩家音效（单机/联机通用）：以「本地玩家」为听者决定是否做距离衰减。
##
## · 单机 —— 场上只有本机玩家，恒满音量（保持既有手感，不引入相机偏移导致的轻微衰减）。
## · 联机 —— 本地玩家自己恒满音量（相机平滑/朝向偏移不该让自己的枪声变小），
##   其他玩家走 2D 定位 → 距离衰减 + 左右声像（2026-10-20 用户需求：
##   「多人模式时其他玩家开枪等各种声音，离得越远越小」）。
##
## 是否本地玩家由 player 节点的 `network_local_player` 字段判定（player.gd 在
## Host/Client 两侧都会正确写入）；节点没有该字段时按本地处理。
func play_player_sfx(stream: AudioStream, player_node: Node, pitch: float = 1.0) -> void:
	if not stream or player_node == null or not is_instance_valid(player_node):
		return
	var positional: bool = false
	if _is_online_session():
		positional = player_node.get("network_local_player") != true
	play_sfx_managed(stream, player_node, positional, pitch)


## 播放界面窗口音效（2026-09-15）。kind = "cursor" | "confirm" | "cancel"；
## override_path 非空时优先（各界面自己的 sfx_*_path 导出），否则用全局 ui_*_sfx_path。
## 播放器挂在宿主（Global）下——确认音后立刻切场景也不会被掐断。
func play_ui_sfx(kind: String, override_path: String = "") -> void:
	var path := override_path
	if path.is_empty():
		match kind:
			"cursor":
				path = _host_sfx_path("ui_cursor_sfx_path")
			"confirm":
				path = _host_sfx_path("ui_confirm_sfx_path")
			"cancel":
				path = _host_sfx_path("ui_cancel_sfx_path")
			_:
				return
	if path.is_empty():
		return
	var stream: AudioStream = load(path) as AudioStream
	if stream == null:
		push_warning("[Global] UI 音效加载失败: %s" % path)
		return
	play_sfx_managed(stream, _host if _host != null else Engine.get_main_loop().root)


## 播放拾取音效：override 非空用之，否则用全局默认；pitch <=0 视为原调。
## 播放器挂当前场景（非定位）——拾取物节点随即释放，不能挂；拾取都发生在玩家身边，
## 与 UI 音同等的非定位处理（沿用 ItemPickupPoint 既有行为）。
func play_pickup_sfx(override: AudioStream = null, pitch: float = 1.0) -> void:
	var stream := override
	if stream == null:
		var default_path: String = _host_sfx_path("default_pickup_sfx_path")
		if default_path.is_empty():
			return
		stream = load(default_path) as AudioStream
	if stream == null:
		return
	var scene: Node = null
	if _host != null and _host.get_tree() != null:
		scene = _host.get_tree().current_scene
	if scene == null:
		scene = _host
	play_sfx_managed(stream, scene, false, maxf(pitch, 0.01))


# ═══════════════════════════════════════
# 大厅音乐
# ═══════════════════════════════════════

## 播放大厅音乐。幂等：已在播同曲时直接返回（切界面不会重头播）。
func play_lobby_music() -> void:
	if _lobby_music_player and is_instance_valid(_lobby_music_player) and _lobby_music_player.playing:
		return
	if _lobby_music_player == null or not is_instance_valid(_lobby_music_player):
		_lobby_music_player = AudioStreamPlayer.new()
		_lobby_music_player.name = "LobbyMusicPlayer"
		_lobby_music_player.bus = "Music"
		if _host != null:
			_host.add_child(_lobby_music_player)
	if not ResourceLoader.exists(LOBBY_MUSIC_PATH):
		return
	_lobby_music_player.stream = load(LOBBY_MUSIC_PATH)
	_lobby_music_player.play()


## 停止大厅音乐（难度确认 / 回标题等正式离开大厅时调用）。
func stop_lobby_music() -> void:
	if _lobby_music_player and is_instance_valid(_lobby_music_player):
		_lobby_music_player.stop()


# ═══════════════════════════════════════
# 内部
# ═══════════════════════════════════════

## 读宿主上的 `@export` 音频配置（并发上限 / 音效路径），宿主缺失时用保守默认。
func _max_sfx_concurrency() -> int:
	if _host != null:
		var v: Variant = _host.get("max_sfx_concurrency")
		if v is int and int(v) > 0:
			return int(v)
	return 2


func _host_sfx_path(prop: String) -> String:
	if _host == null:
		return ""
	var v: Variant = _host.get(prop)
	return String(v) if v is String else ""


## 是否联机会话（本服务不缓存 Net 引用：harness / 无 autoload 时返回 false）。
func _is_online_session() -> bool:
	if _host == null:
		return false
	var net: Node = _host.get_node_or_null("/root/Net")
	if net == null or not net.has_method("is_online_session"):
		return false
	return bool(net.call("is_online_session"))


## 读宿主上的世界音效衰减配置（Global 的 @export），缺失/非法时用服务内默认。
func _world_sfx_max_distance() -> float:
	var v: float = _host_float("world_sfx_max_distance", DEFAULT_WORLD_SFX_MAX_DISTANCE)
	return v if v > 1.0 else DEFAULT_WORLD_SFX_MAX_DISTANCE


func _world_sfx_attenuation() -> float:
	var v: float = _host_float("world_sfx_attenuation", DEFAULT_WORLD_SFX_ATTENUATION)
	return v if v > 0.0 else DEFAULT_WORLD_SFX_ATTENUATION


func _world_sfx_panning_strength() -> float:
	return clampf(_host_float("world_sfx_panning_strength", DEFAULT_WORLD_SFX_PANNING_STRENGTH), 0.0, 1.0)


func _host_float(prop: String, fallback: float) -> float:
	if _host == null:
		return fallback
	var v: Variant = _host.get(prop)
	return float(v) if v is float or v is int else fallback
