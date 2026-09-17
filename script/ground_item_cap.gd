class_name GroundItemCap extends RefCounted

## ── 架构定位 ──
## 系统：物品系统 ｜ 层：工具（static）
## 职责：地面放置物上限（原作说明书 §3.1：地面装备含敌人掉落物合计 8 个，
##       超出时**最早的**消失）。weapon_pickup / healing_pickup 生成时调用 register()。
## 依赖：无。

const CAP: int = 8


## 注册一个地面放置物；若场上（ground_item 组）已满，删除创建时间最早的（不含本次）。
static func register(node: Node2D) -> void:
	node.add_to_group("ground_item")
	node.set_meta("_ground_created_msec", Time.get_ticks_msec())
	var tree := node.get_tree()
	if not tree:
		return
	var items: Array = tree.get_nodes_in_group("ground_item")
	while items.size() > CAP:
		var oldest: Node = null
		var oldest_t: int = 0x7fffffff
		for it: Node in items:
			if not is_instance_valid(it) or it == node:
				continue
			var t: int = int(it.get_meta("_ground_created_msec", 0))
			if t < oldest_t:
				oldest_t = t
				oldest = it
		if oldest == null:
			break
		items.erase(oldest)
		print("[地面放置物] 超过 %d 个 → 最早的「%s」消失" % [CAP, oldest.name])
		oldest.queue_free()
