extends CanvasLayer
## HUD —— 只显示本地玩家状态 + 系统消息（纯表现，无任何权威数据）。

var _messages: Array[String] = []
var _last_hp := -1.0
var _last_alive := true

@onready var hp_label: Label = %HpLabel
@onready var msg_label: Label = %MsgLabel


func _process(_delta: float) -> void:
	var me := _my_player()
	if me == null:
		hp_label.text = "等待玩家实体生成 ..."
		return
	var hp: float = me.hp
	var alive: bool = me.alive
	if hp != _last_hp or alive != _last_alive:
		_last_hp = hp
		_last_alive = alive
		var status := "存活" if alive else "倒地（3 秒后复活）"
		hp_label.text = "HP: %d / 100    %s    %s" % [
			int(hp),
			Net.get_player_name(Net.my_peer_id),
			status,
		]


func _my_player() -> Node:
	var game := get_tree().current_scene
	if game == null:
		return null
	return game.get_node_or_null("Entities/%d" % Net.my_peer_id)


func show_message(text: String) -> void:
	_messages.append(text)
	if _messages.size() > 40:
		_messages.pop_front()
	var tail := _messages.slice(maxi(0, _messages.size() - 4))
	msg_label.text = "\n".join(tail)
