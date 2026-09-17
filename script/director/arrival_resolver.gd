class_name ArrivalResolver extends RefCounted

## ── 架构定位 ──
## 系统：关卡流程 ｜ 层：工具类（RefCounted）
## 联机：不涉及
## 职责：统一解析入口点：显式坐标 > 匹配 ID 的 ArrivalPoint > 场景原有出生点。
## 依赖：ArrivalPoint；被 Global/game_init 调用

## 统一解析地图入口点，未匹配时保持场景原有的 PlayerSpawn 出生位置。

static func resolve(scene: Node, arrival_id: String, arrival_position: Variant = null) -> Variant:
	if arrival_position is Vector2:
		return arrival_position as Vector2
	var trimmed_id := arrival_id.strip_edges()
	if trimmed_id.is_empty() or not scene:
		return null

	var matched_point: ArrivalPoint = null
	for node: Node in scene.find_children("*", "Node2D", true, false):
		if not node is ArrivalPoint:
			continue
		var point := node as ArrivalPoint
		if point.point_id.strip_edges() != trimmed_id:
			continue
		if matched_point:
			push_warning("[ArrivalResolver] 场景 %s 存在重复入口 ID: %s，使用第一个: %s" % [
				scene.scene_file_path, trimmed_id, matched_point.get_path()
			])
			continue
		matched_point = point

	if not matched_point:
		push_warning("[ArrivalResolver] 场景 %s 未找到入口 ID: %s，保留 PlayerSpawn 默认位置" % [
			scene.scene_file_path, trimmed_id
		])
		return null

	return matched_point.global_position
