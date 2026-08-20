class_name SafehouseArrivalMusic extends Node
## 安全屋到达音乐。初始安全屋立即播放；有章节总结的安全屋在总结关闭后播放。

@export var arrival_music: AudioStream
@export var volume_db: float = 0.0
@export var wait_for_chapter_summary: bool = true

var _player: AudioStreamPlayer


func _ready() -> void:
	call_deferred("_start_when_ready")


func _start_when_ready() -> void:
	if not arrival_music:
		return
	var summary: ChapterSummary = get_tree().current_scene.find_child("ChapterSummary", true, false) as ChapterSummary
	if wait_for_chapter_summary and summary and summary.visible:
		summary.summary_finished.connect(_play_arrival_music, CONNECT_ONE_SHOT)
		return
	_play_arrival_music()


func _play_arrival_music() -> void:
	if not _player:
		_player = AudioStreamPlayer.new()
		_player.name = "SafehouseArrivalMusicPlayer"
		_player.bus = &"Music"
		add_child(_player)
	_player.stop()
	_player.stream = arrival_music
	_player.volume_db = volume_db
	_player.play()
