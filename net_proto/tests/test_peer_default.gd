extends SceneTree
## 诊断：无头模式下 multiplayer_peer 的默认值（用于排查 game.gd 守卫判断）。


func _initialize() -> void:
	print("== 诊断 multiplayer 默认状态 ==")
	var mp := get_multiplayer()
	print("get_multiplayer().multiplayer_peer = ", mp.multiplayer_peer)
	print("get_multiplayer().get_unique_id()   = ", mp.get_unique_id())
	print("get_multiplayer().get_peers()       = ", mp.get_peers())
	quit(0)
