extends Node2D

## ── 架构定位 ──
## 系统：拾取进度环 ｜ 层：表现（Node2D）
## 联机：不涉及
## 职责：按住拾取的进度圆环绘制，配置与状态全部由父节点 weapon_pickup 持有。
## 依赖：weapon_pickup（父节点）

## 按住进度指示器 — 由 weapon_pickup.gd 动态创建的子节点
## 仅用于绘制圆环，所有配置和状态由父节点 weapon_pickup 持有。

var _pickup: Node2D

func _draw() -> void:
	if _pickup and _pickup.has_method("_indicator_draw"):
		_pickup._indicator_draw(self)
