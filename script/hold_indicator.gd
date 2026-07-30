extends Node2D
## 按住进度指示器 — 由 weapon_pickup.gd 动态创建的子节点
## 仅用于绘制圆环，所有配置和状态由父节点 weapon_pickup 持有。

var _pickup: Node2D

func _draw() -> void:
	if _pickup and _pickup.has_method("_indicator_draw"):
		_pickup._indicator_draw(self)
