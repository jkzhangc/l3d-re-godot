extends Control

## ── 架构定位 ──
## 系统：成就 ｜ 层：表现（Control，**代码构建、无 tscn**；由标题画面叠加打开）
## 联机：不涉及（纯本地查看）
## 职责：成就一览 —— 列出全部目录条目、达成状态与进度；确定/取消关闭。
## 依赖：Achievements、Global（字体）
##
## 【为什么做成叠加层而不是独立场景】独立场景要手写 tscn（锚点/字体/Theme 三处易错），
## 而这里只需要"盖在标题之上、关闭即销毁"，用 `add_child` 叠加最省事也最稳。

signal closed

## ★ 2026-10-02 加宽 920 → 1080：24px 字号下「名字 + 条件 + 进度」三列在 920 里挤不开，
## 长名字会压到条件列上。现在三列各自独立占位，名字再长也只在**自己那一列**内截断。
const PANEL_W: float = 1080.0
const PANEL_H: float = 620.0
const ROW_H: float = 46.0
const FONT_TITLE: int = 24
const FONT_BODY: int = 24

## 三列几何（左内边距 / 名字列宽 / 条件列起点 / 进度列宽）。
## 名字列 344px ≈ 12 个 24px 全角字，当前最长成就名（"不行。绝对不行。" 8 字 + "◆ " 前缀）只用掉约 240。
const COL_PAD: float = 36.0
const NAME_W: float = 344.0
const DESC_X: float = 384.0
const STATE_W: float = 188.0
## 条件列宽 = 面板宽 - 条件列起点 - 进度列宽 - 右内边距
const DESC_W: float = PANEL_W - DESC_X - STATE_W - 36.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	## 吃掉鼠标/触摸：这个页是模态的，底下的标题菜单不该再收到点击
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	ACHIEVEMENTS.load_progress()
	_build()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键") or event.is_action_pressed("确定键"):
		## ★项目铁律：菜单输入「**消费了才标记**」——不标记的话会掐掉触摸事件，
		## 让整页虚拟键失效（09-30 教训）。
		get_viewport().set_input_as_handled()
		closed.emit()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := ColorRect.new()
	panel.color = Color(0.10, 0.09, 0.08, 0.96)
	panel.size = Vector2(PANEL_W, PANEL_H)
	panel.position = ((get_viewport_rect().size - panel.size) * 0.5).floor()
	add_child(panel)

	var title := _make_label("成  就", FONT_TITLE)
	title.position = Vector2(0, 18)
	title.size = Vector2(PANEL_W, 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)

	var count := _make_label("已达成 %d / %d" % [ACHIEVEMENTS.unlocked_count(), ACHIEVEMENTS.CATALOG.size()],
		FONT_BODY)
	count.position = Vector2(PANEL_W - STATE_W - COL_PAD, 20)
	count.size = Vector2(STATE_W, 30)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.modulate = Color(0.80, 0.78, 0.72)
	panel.add_child(count)

	var sep := ColorRect.new()
	sep.color = Color(0.55, 0.50, 0.42, 0.7)
	sep.position = Vector2(28, 60)
	sep.size = Vector2(PANEL_W - 56, 1)
	panel.add_child(sep)

	var y: float = 74.0
	for e: Dictionary in ACHIEVEMENTS.CATALOG:
		var id: String = str(e.get("id", ""))
		var ok: bool = ACHIEVEMENTS.is_unlocked_any(id)

		## 达成标记（◆ 与成就弹窗同款符号）+ 名称
		var name_label := _make_label("%s %s" % ["◆" if ok else "◇", ACHIEVEMENTS.name_of(id)], FONT_BODY)
		name_label.position = Vector2(COL_PAD, y)
		name_label.size = Vector2(NAME_W, 30)
		## 名字再长也只在自己列内截断，绝不会压到条件列上（加宽面板后的双保险）。
		name_label.clip_text = true
		if not ok:
			name_label.modulate = Color(0.55, 0.53, 0.50)   ## 未达成：压暗
		panel.add_child(name_label)

		var desc_label := _make_label(ACHIEVEMENTS.desc_of(id), FONT_BODY)
		desc_label.position = Vector2(DESC_X, y)
		desc_label.size = Vector2(DESC_W, 30)
		desc_label.clip_text = true
		desc_label.modulate = Color(0.72, 0.70, 0.64) if ok else Color(0.48, 0.46, 0.44)
		panel.add_child(desc_label)

		var state_label := _make_label("已达成" if ok else "%d / %d"
			% [ACHIEVEMENTS.progress_of(ACHIEVEMENTS.TEAM_SEAT, id), ACHIEVEMENTS.target_of(id)], FONT_BODY)
		state_label.position = Vector2(PANEL_W - STATE_W - COL_PAD, y)
		state_label.size = Vector2(STATE_W, 30)
		state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		state_label.modulate = Color(0.95, 0.80, 0.35) if ok else Color(0.50, 0.48, 0.46)
		panel.add_child(state_label)
		y += ROW_H

	var footer := _make_label("确定 / Esc 返回", FONT_BODY)
	footer.position = Vector2(0, PANEL_H - 42)
	footer.size = Vector2(PANEL_W, 30)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.modulate = Color(0.80, 0.78, 0.72)
	panel.add_child(footer)


func _make_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", l, size)
	else:
		l.add_theme_font_size_override("font_size", size)
	return l


## 成就系统入口（**preload 常量而不是 class_name**：本项目 class_name 不进全局类缓存，
## 跨文件按名字引用会在 headless / 导出时报 Parse Error —— 见 MEMORY「class_name 不跨文件」）。
const ACHIEVEMENTS := preload("res://script/achievements.gd")
