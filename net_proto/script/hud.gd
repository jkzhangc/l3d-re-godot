extends CanvasLayer

var _messages: Array[String] = []
@onready var hp_label: Label = %HpLabel
@onready var msg_label: Label = %MsgLabel

func _process(_delta: float) -> void:
	var game := get_tree().current_scene
	if game == null:
		return
	var me := game.get_node_or_null("Players/%d" % Net.my_peer_id)
	if me == null:
		var detail := "等待玩家实体生成"
		if game.has_method("get_network_sync_status"):
			detail = game.get_network_sync_status()
		hp_label.text = detail
		return
	hp_label.text = "HP: %d / 100    %s    %s" % [int(me.hp), Net.get_player_name(Net.my_peer_id), "存活" if me.alive else "倒地"]

func show_message(text: String) -> void:
	_messages.append(text)
	if _messages.size() > 20:
		_messages.pop_front()
	msg_label.text = "\n".join(_messages)
