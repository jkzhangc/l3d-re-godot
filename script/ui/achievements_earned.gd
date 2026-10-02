extends Control

## ── 架构定位 ──
## 系统：成就 ｜ 层：表现（Control，ED 流程内弹出；**无 tscn，全代码构建**）
## 联机：Host 汇总解锁列表后广播，两端显示同一份；**3 秒自动继续**（不依赖按键 → 天然同步）
## 职责：章节总结确定后展示本次解锁的成就（按座位归属），到时发 finished 让 ED 继续。
## 依赖：Achievements（take_pending）、Global（字体）、CampaignEnding（挂在 EndingRoot 下）
##
## 【为什么不用按键继续】用户 2026-10-02 定稿：多人时等按键可能有人迟迟不按 →
## 名单会不同步；改成固定 3 秒，两端走同一时间轴。

signal finished

## 停留时长（秒）——用户要求 3 秒
const HOLD_SECONDS: float = 3.0
const PANEL_W: float = 640.0
const PANEL_H: float = 360.0
const FONT_TITLE: int = 24
const FONT_BODY: int = 24

var _timer: float = 0.0
var _done: bool = false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 树此时是暂停的（ED 演出全程冻结世界）→ 本层必须 ALWAYS 才能走计时
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _process(delta: float) -> void:
	if _done:
		return
	_timer += delta
	if _timer >= HOLD_SECONDS:
		_done = true
		finished.emit()


## 本次是否有成就需要展示（无解锁 → 调用方直接跳过本页，不白等 3 秒）。
## ⚠ 只**查看**不取走 —— 取走是 `_build()` 里 `take_pending()` 的事，先 peek 再 take 会漏掉内容。
static func has_content() -> bool:
	return ACHIEVEMENTS.pending_count() > 0


func _build() -> void:
	var pending: Array = ACHIEVEMENTS.take_pending()

	## 半透明黑幕（压在 ED 黑幕之上；原 ED 黑幕此时已是全黑，这里只做视觉分层）
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var panel := ColorRect.new()
	panel.color = Color(0.10, 0.09, 0.08, 0.96)
	panel.size = Vector2(PANEL_W, PANEL_H)
	panel.position = ((get_viewport_rect().size - panel.size) * 0.5).floor()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	## RM 风格的双线内框
	var frame := ColorRect.new()
	frame.color = Color(0.55, 0.50, 0.42, 1.0)
	frame.position = Vector2(4, 4)
	frame.size = panel.size - Vector2(8, 8)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var inner := ColorRect.new()
	inner.color = panel.color
	inner.position = Vector2(3, 3)
	inner.size = frame.size - Vector2(6, 6)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(inner)
	panel.add_child(frame)

	var title := _make_label("成 就 达 成", FONT_TITLE)
	title.position = Vector2(0, 18)
	title.size = Vector2(PANEL_W, 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)

	var sep := ColorRect.new()
	sep.color = Color(0.55, 0.50, 0.42, 0.7)
	sep.position = Vector2(28, 60)
	sep.size = Vector2(PANEL_W - 56, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(sep)

	## 逐条列出（每条两行：名称+归属 / 说明）
	var y: float = 76.0
	for rec: Dictionary in pending:
		if y > PANEL_H - 70.0:
			break                       ## 面板放不下就截断（首批最多 10 条，正常够用）
		var id: String = str(rec.get("id", ""))
		var seat: int = int(rec.get("seat", ACHIEVEMENTS.TEAM_SEAT))
		var who: String = "全队" if seat == ACHIEVEMENTS.TEAM_SEAT else "%dP" % (seat + 1)

		var name_label := _make_label("◆ %s  （%s）" % [ACHIEVEMENTS.name_of(id), who], FONT_BODY)
		name_label.position = Vector2(32, y)
		name_label.size = Vector2(PANEL_W - 64, 30)
		panel.add_child(name_label)

		var desc_label := _make_label("　　%s" % ACHIEVEMENTS.desc_of(id), FONT_BODY)
		desc_label.position = Vector2(32, y + 28)
		desc_label.size = Vector2(PANEL_W - 64, 30)
		desc_label.modulate = Color(0.72, 0.70, 0.64)
		panel.add_child(desc_label)
		y += 62.0

	var footer := _make_label("3 秒后继续…", FONT_BODY)
	footer.position = Vector2(0, PANEL_H - 44)
	footer.size = Vector2(PANEL_W, 30)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.modulate = Color(0.80, 0.78, 0.72)
	panel.add_child(footer)


func _make_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 字体唯一入口（禁硬编码 .ttf / 禁非 12 整倍字号）
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", l, size)
	else:
		l.add_theme_font_size_override("font_size", size)
	return l

## 成就系统入口（**preload 常量而不是 class_name**：本项目 class_name 不进全局类缓存，
## 跨文件按名字引用会在 headless / 导出时报 Parse Error —— 见 MEMORY「class_name 不跨文件」）。
const ACHIEVEMENTS := preload("res://script/achievements.gd")
