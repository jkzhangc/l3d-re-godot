extends RefCounted

## ── 架构定位 ──
## 系统：撤离条件 ｜ 层：工具（纯静态，无节点）
## 职责：「存活玩家到齐」判定 —— FinaleTrigger 与 HoldoutMachine 共用。
## 依赖：Players（实体 / 座位 / 状态）
##
## 【口径（2026-11-21 用户确认）】
##   只要求**还活着**的玩家到齐；倒地/死亡不阻塞撤离。
##   单机：恒 true（只有自己）。
##   联机：Host 在真正起 ED 前校验一次；Client 也先做本地预检（尽早给提示）。

## 返回 {"near": 半径内存活数, "total": 存活总数}
static func counts(center: Vector2, radius: float) -> Dictionary:
	var total: int = 0
	var near: int = 0
	for entity: Node2D in Players.all_entities(true):
		if entity == null or not is_instance_valid(entity):
			continue
		var st: PlayerState = Players.get_state_for_entity(entity)
		if st == null or not st.is_alive():
			continue
		total += 1
		if entity.global_position.distance_to(center) <= radius:
			near += 1
	return {"near": near, "total": total}


static func all_near(center: Vector2, radius: float) -> bool:
	var c: Dictionary = counts(center, radius)
	var total: int = int(c["total"])
	return total > 0 and int(c["near"]) >= total
