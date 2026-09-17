class_name DropPoolData extends Resource

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：数据（Resource，.tres）
## 联机：数据只读；投放由 Host 权威执行
## 职责：随机掉落池：武器（WeaponData）或物品（ItemData）混合池，按权重随机取一项。
## 依赖：无（纯数据）。消费方：random_pickup.gd（随机掉落物）、item_manager.gd（导演投放）。
##
## 【配置方法】新建 DropPoolData 资源（或直接在 Inspector 里新建内嵌资源）：
##   items   = 拖入 weapon_*.tres / item_*.tres（可混放）
##   weights = 对应权重（条目不足时按 1.0 计；0 = 不会被抽中）
## 然后把池子拖进地图 DirectorConfig 的 drop_pool，ItemManager 投放时即从池里随机刷。

@export_group("掉落池")
## 掉落候选：WeaponData（走 weapon_pickup 拾取）或 ItemData（走 healing_pickup 拾取），可混放。
@export var items: Array[Resource] = []
## 与 items 一一对应的权重（条目不足按 1.0；0 = 不会被抽中）。
@export var weights: Array[float] = []


## 按权重随机取一项；池子为空或全 0 权重返回 null。
func roll() -> Resource:
	if items.is_empty():
		return null
	var total: float = 0.0
	for i: int in items.size():
		var w: float = weights[i] if i < weights.size() else 1.0
		total += maxf(w, 0.0)
	if total <= 0.0:
		return null
	var r: float = randf() * total
	for i: int in items.size():
		var w: float = weights[i] if i < weights.size() else 1.0
		if w <= 0.0:
			continue
		r -= w
		if r <= 0.0:
			return items[i]
	return items[items.size() - 1]
