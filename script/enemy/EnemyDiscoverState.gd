extends State
## 发现玩家 — 显示 "!" 表情符号，持续 2 秒后开始追击

var _timer: float = 0.0
const DISCOVER_DURATION: float = 0.5


func enter() -> void:
	character.update_moving(false)
	character.velocity = Vector2.ZERO
	_timer = DISCOVER_DURATION

	# 播放发现音效
	var enemy: Node2D = character
	enemy._play_sound(enemy.discover_sound)

	# 显示 "!"
	var label: Label = character.get_node_or_null("DiscoverLabel") as Label
	if label:
		label.text = "!"
		label.show()


func exit() -> void:
	# 隐藏 "!"
	var label: Label = character.get_node_or_null("DiscoverLabel") as Label
	if label:
		label.hide()


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	_timer -= delta
	if _timer <= 0.0:
		transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	character.move_and_slide()
