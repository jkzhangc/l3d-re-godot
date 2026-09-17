extends Node2D

## ── 架构定位 ──
## 系统：队友替身 ｜ 层：表现（Node2D）
## 联机：不涉及
## 职责：不可交互、不可受伤的队友静态精灵，由 CharacterSwitchManager 创建。
## 依赖：CharacterSwitchManager

## 队友站立精灵 — 不可交互、不受伤害的静态角色
##
## 由 CharacterSwitchManager 创建和管理。
## 仅包含 Sprite2D，无碰撞体、无物理、不可交互。


func _ready() -> void:
	# 确保没有碰撞体
	for child: Node in get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			child.queue_free()
