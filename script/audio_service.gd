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

## 音乐/音效音量 0–100（config 持久化；Global 以属性代理暴露）。
var music_volume: int = 80
var sfx_volume: int = 80

## 同一音效资源的活跃播放器计数（resource_path → Array[AudioStreamPlayer]）
var _active_sfx: Dictionary = {}
## 大厅 BGM 播放器（挂在宿主上，切界面不释放 → 音乐连续）。
var _lobby_music_player: AudioStreamPlayer = null

const LOBBY_MUSIC_PATH: String = "res://music/l3d_lobby.mp3"


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
	AudioServer.set_bus_name(1, "SFX")
	AudioServer.set_bus_name(2, "Music")
	apply_volume()
	print("[Global] 音频总线已创建: Master, SFX, Music")


func apply_volume() -> void:
	var sfx_idx: int = AudioServer.get_bus_index("SFX")
	var music_idx: int = AudioServer.get_bus_index("Music")
	if sfx_idx >= 0:
		AudioServer.set_bus_volume_db(sfx_idx, linear_to_db(sfx_volume / 100.0))
	if music_idx >= 0:
		AudioServer.set_bus_volume_db(music_idx, linear_to_db(music_volume / 100.0))


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


# ═══════════════════════════════════════
# 音效播放（带并发限制）
# ═══════════════════════════════════════

## 播放音效（带并发限制，防止同音效多实例叠加导致音量过大）。
## positional=true 且 parent 是 Node2D 时用 AudioStreamPlayer2D —— 音量随距离衰减、
## 带声像（丧尸叫等世界内音效必须走这个，否则屏外的僵尸和贴脸的一样响）。
func play_sfx_managed(stream: AudioStream, parent: Node, positional: bool = false, pitch: float = 1.0) -> void:
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
		# 可视世界半径 ≈ 分辨率/2（zoom=2x）≈ 640×480；衰减到屏外一圈即无声
		p2d.max_distance = 1100.0
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
	arr.append(player)
	_active_sfx[key] = arr


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
