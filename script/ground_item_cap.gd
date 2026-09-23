class_name GroundItemCap extends RefCounted

## ── 架构定位 ──
## 系统：物品系统 ｜ 层：工具（static）
## 职责：地面放置物上限（原作说明书 §3.1：地面装备含敌人掉落物合计 8 个，
##       超出时**最早的**消失）。weapon_pickup / healing_pickup 生成时调用 register()。
## 依赖：无（联机判定走 /root/Net 路径查询，与 random_pickup / director 同款）。
##
## ═══ 联机不变量（2026-09-23 实测根因，勿破坏）═══
## **地面物集合的唯一真源是 Host。** Host 侧照常执行本上限（单机语义在联机里保留），
## Client 侧**一律不参与本地上限淘汰** —— Client 的掉落物是 Host 快照的镜像，
## 由 NetworkWorld._apply_client_pickup_snapshot 按 id 全量重建/销毁。
##
## 反例（修复前的实际故障）：Client 重建镜像节点时进了 GroundItemCap 计数 →
## 计数超 8 → 淘汰「最早的」并 queue_free → 但 NetworkWorld._pickups[id] 仍指向
## 该节点（悬垂）→ 下个可靠快照（2.0s）该 id 仍在 → 按同一坐标重新 instantiate →
## 再次计数 → 再淘汰另一个 …… 形成 **2 秒周期的「消失↔重建」无限轮转**：
## 客户端地面掉落物每 2 秒闪一次、主机侧完全正常，且被淘汰物件的 NetworkWorld
## 条目始终悬垂（Host 侧 _build_pickup_snapshot 的 freed-cast 静默中止风险）。

const CAP: int = 8


## 注册一个地面放置物；若场上（ground_item 组）已满，删除创建时间最早的（不含本次）。
## 联机 Client 直接跳过：镜像物件的生命周期由 Host 权威快照决定，本地不得增删。
static func register(node: Node2D) -> void:
	if _is_network_client(node):
		return
	node.add_to_group("ground_item")
	node.set_meta("_ground_created_msec", Time.get_ticks_msec())
	var tree := node.get_tree()
	if not tree:
		return
	# 候选集先剔除已失效 / 已排队销毁的节点：queue_free() 是延迟生效的，同帧内多次
	# register 会把同一个待删节点反复计入 `items.size()` 并反复选中它 —— 修复前日志
	# 里连续两行「最早的『@Node2D@32』消失」即此现象（同名被删两次）。
	var items: Array = []
	for it: Node in tree.get_nodes_in_group("ground_item"):
		if not is_instance_valid(it) or it.is_queued_for_deletion():
			continue
		items.append(it)
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


## 当前是否「联机会话中的客户端」。
## ⚠ 不能用 Autoload 标识符（脚本热重载时序下可能解析失败），沿用工程惯例按
## 节点路径取 /root/Net —— 与 random_pickup.gd / director.gd / dev_enemy_spawner.gd 同款。
static func _is_network_client(node: Node) -> bool:
	var tree := node.get_tree()
	if tree == null:
		return false
	var net: Node = tree.root.get_node_or_null("Net")
	if net == null or not net.has_method("is_online_session"):
		return false
	if not bool(net.is_online_session()):
		return false
	return not bool(net.get("is_host"))
