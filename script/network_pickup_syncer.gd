extends Node
## 网络武器掉落物同步器 — Host 广播拾取事件，Client 移除对应的掉落物。
##
## 由 GameInit 在联机时自动创建。


func _ready() -> void:
	if not NetworkManager.is_online():
		queue_free()
		return
	NetworkManager.recv_pickup_removed.connect(_on_pickup_removed)


func _on_pickup_removed(pickup_path: String) -> void:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	# 通过节点路径查找掉落物
	var pickup: Node = tree.current_scene.get_node_or_null(pickup_path)
	if pickup:
		pickup.queue_free()
		print("[PickupSyncer] 移除掉落物: %s" % pickup_path)
