extends RefCounted

## ── 架构定位 ──
## 系统：玩家音效/音乐 ｜ 层：服务类（RefCounted，由 player 持有）
## 联机：Host/Client 通用（SFX 走 Global 管理器；音乐是玩家节点私有子节点）
## 职责：播放玩家音效（单机/联机同一套 SFX 管理器与并发上限）与死亡等地点的替换式音乐。
## 依赖：player 实体（作 SFX 宿主与子节点容器）、Global（play_sfx_managed / death_music_volume_db）
##
## 【为什么从 player.gd 抽出（2026-10-08）】音效工具约 33 行、纯表现、零玩法耦合；
## 唯一外部接口是 player 节点本身（作 SFX 宿主）。抽出后 player.gd 保留同名转发门面。

var _p: Node = null


func _init(player: Node) -> void:
	_p = player


func play_sound(stream: AudioStream) -> void:
	if not stream:
		return
	Global.play_sfx_managed(stream, _p)


## 联机表现专用音效入口（装填/攻击后/推击等）。与单机同一套 SFX 管理器与并发上限，
## 用**调用当刻**的节点自身作宿主：协程里 await 之后缓存的 SceneTree 可能已失效，
## 而本节点只要仍在树内就是合法宿主（2026-09-24 联机装填静音修复一并收口）。
func play_network_sfx(stream: AudioStream) -> void:
	if not stream or not _p.is_inside_tree():
		return
	Global.play_sfx_managed(stream, _p)


## 播放替换式音乐（挂在 player 节点下的 DeathMusicPlayer）。再次调用会先停掉旧实例。
func play_music(stream: AudioStream) -> void:
	if not stream:
		return
	# 停止已有的音乐
	for child: Node in _p.get_children():
		if child is AudioStreamPlayer and child.name == "DeathMusicPlayer":
			child.stop()
			child.queue_free()

	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.name = "DeathMusicPlayer"
	player.stream = stream
	player.bus = "Music"
	player.volume_db = Global.death_music_volume_db
	player.autoplay = true
	_p.add_child(player)
