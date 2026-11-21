extends RefCounted

## ── 架构定位 ──
## 系统：UI 表现 ｜ 层：工具（纯静态，无节点）
## 职责：RM2K3 窗口皮的唯一入口 —— 底图整体拉伸 + 20px 九宫格边框。
## 依赖：无（只 load 两张系统贴图）
##
## 【为什么要收成一份】安全屋台词框、操作说明、战役选择、成就弹窗/成就一览
## 必须长得一样；旧实现里各写各的 ColorRect 双线框，样式已经分叉。
## 以后新增任何「RM 窗口」页面都调 `RMWindow.apply(panel)`，改一处全同步。
##
## 用法：
##   var panel := Control.new()
##   panel.size = Vector2(w, h)
##   RM_WINDOW.apply(panel)
##   panel.add_child(标题/正文...)      # 内容后加 → 天然压在底图与边框之上

const BG_PATH := "res://art/System/Window background color.png"
const FRAME_PATH := "res://art/System/Window frame.png"
## 九宫格四边（与 safehouse_dialogue.tscn / controls_guide.gd 保持一致）
const PATCH: int = 20


## 给 panel 铺上 RM 窗口皮。幂等：重复调用不会叠加（会先移除同名旧节点）。
static func apply(panel: Control) -> void:
	if panel == null:
		return
	for child_name: String in ["RmWindowBg", "RmWindowFrame"]:
		var old: Node = panel.get_node_or_null(child_name)
		if old != null:
			panel.remove_child(old)
			old.queue_free()

	var bg_tex: Texture2D = load(BG_PATH) as Texture2D
	if bg_tex != null:
		var bg := TextureRect.new()
		bg.name = "RmWindowBg"
		bg.texture = bg_tex
		bg.size = panel.size
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(bg)

	var frame_tex: Texture2D = load(FRAME_PATH) as Texture2D
	if frame_tex == null:
		return
	var frame := NinePatchRect.new()
	frame.name = "RmWindowFrame"
	frame.texture = frame_tex
	frame.patch_margin_left = PATCH
	frame.patch_margin_top = PATCH
	frame.patch_margin_right = PATCH
	frame.patch_margin_bottom = PATCH
	frame.size = panel.size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(frame)
