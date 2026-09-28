extends CanvasLayer

## ── 架构定位 ──
## 系统：触摸操作 ｜ 层：表现（CanvasLayer）
## 联机：不涉及（动作由既有 InputMap 承载，权威判定不变）
## 职责：手机端触摸操作层：把屏幕触摸转成既有 InputMap 动作（移动 / 攻击 / 装填 / 物品 / 系统）。
## 依赖：Global.is_mobile_platform()、Global.debug_enabled
##
## 【为什么是一个独立场景】用户要求"触摸按钮做成一个场景，每个按钮是独立节点，方便调整"：
## 全部按钮都在 `scene/ui/touch_controls.tscn` 里，位置 / 尺寸 / 贴图 / 映射动作
## 都能在编辑器里直接改，改完不必动任何脚本。

## 桌面端也显示（调布局用）。导出包（release）里 `debug_enabled` 恒 false，故不会误开。
@export var force_show_on_desktop: bool = false

## 触摸层在游戏 HUD 之上、黑幕(90)/结算页(100) 之下。
@export var control_layer: int = 80


func _ready() -> void:
	layer = control_layer
	var g: Node = get_node_or_null("/root/Global")
	var mobile: bool = false
	if g != null and g.has_method("is_mobile_platform"):
		mobile = bool(g.call("is_mobile_platform"))
	var debug_on: bool = g != null and bool(g.get("debug_enabled"))
	visible = mobile or (force_show_on_desktop and debug_on)
	print("[TouchControls] 移动平台=%s 调试=%s → 触摸层 visible=%s（%d 个按钮节点）" % [
		mobile, debug_on, visible, _count_buttons()])


func _count_buttons() -> int:
	var n: int = 0
	for node: Node in find_children("*", "Button", true, false):
		if node.get_script() != null:
			n += 1
	return n
