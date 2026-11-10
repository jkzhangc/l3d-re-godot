extends Control

## ── 架构定位 ──
## 系统：记录一览（竞速记录 / 总游玩统计）｜ 层：表现（Control，代码构建、无 tscn）
## 联机：不涉及（纯本地资料）
## 职责：三页只读报表 —— `page = 0` 竞速记录、`page = 1` 总游玩统计（仿 L4D2 总览）、
##       `page = 2` 限时挑战记录（到达关卡 / 用时 / 连杀）。
## 依赖：Global.speedrun_records / Global.play_stats（都在 config.json 里，跨存档保留）
##
## 【操作】↑↓ 滚动（记录多时）· 取消/Esc 返回 · 鼠标滚轮翻页
##
## ★字号铁律：像素字体只允许 12 的整倍（本文件 24 / 36 / 48）。

signal closed

const WINDOW_BG_PATH := "res://art/System/Window background color.png"
const WINDOW_FRAME_PATH := "res://art/System/Window frame.png"

const FONT_TITLE: int = 36
const FONT_BODY: int = 24
const LINE_H: float = 32.0

const PANEL_SIZE := Vector2(1000.0, 640.0)
const PAD: float = 28.0
const HEADER_H: float = 64.0
const HINT_H: float = 48.0

const COLOR_TITLE := Color(0.98, 0.96, 0.88)
const COLOR_BODY := Color(0.86, 0.84, 0.78)
const COLOR_MUTED := Color(0.62, 0.60, 0.56)
const COLOR_ACCENT := Color(0.98, 0.84, 0.42)
const COLOR_GOOD := Color(0.72, 0.95, 0.72)
const COLOR_BAD := Color(1.0, 0.62, 0.55)

## 0 = 竞速记录；1 = 总游玩统计；2 = 限时挑战记录。由调用方在 add_child 之前赋值。
var page: int = 0

var _panel: Control = null
var _body: Control = null
var _scroll: float = 0.0
var _content_h: float = 0.0
var _clip_h: float = 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_push_touch_menu_mode()
	_build()


func _exit_tree() -> void:
	_pop_touch_menu_mode()


func _push_touch_menu_mode() -> void:
	var tc: Node = _touch_layer()
	if tc != null and tc.has_method("push_menu_overlay"):
		tc.call("push_menu_overlay", self)


func _pop_touch_menu_mode() -> void:
	var tc: Node = _touch_layer()
	if tc != null and tc.has_method("pop_menu_overlay"):
		tc.call("pop_menu_overlay", self)


func _touch_layer() -> Node:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("touch_controls"):
		return g.call("touch_controls")
	return null


# ═══════════════════════════════════════
# 构建
# ═══════════════════════════════════════

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var vp: Vector2 = get_viewport_rect().size
	_panel = _build_window((vp - PANEL_SIZE) * 0.5, PANEL_SIZE)
	var content_w: float = PANEL_SIZE.x - PAD * 2.0

	var title := _make_label(_title_text(), FONT_TITLE)
	title.position = Vector2(PAD, 12)
	title.size = Vector2(content_w, 44)
	title.modulate = COLOR_TITLE
	_panel.add_child(title)

	var sub := _make_label(_subtitle_text(), FONT_BODY)
	sub.position = Vector2(PAD, 20)
	sub.size = Vector2(content_w, 32)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sub.modulate = COLOR_ACCENT
	_panel.add_child(sub)

	var sep := ColorRect.new()
	sep.color = Color(0.55, 0.50, 0.42, 0.7)
	sep.position = Vector2(PAD, HEADER_H)
	sep.size = Vector2(content_w, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(sep)

	_clip_h = PANEL_SIZE.y - HEADER_H - HINT_H - 24.0
	var clip := Control.new()
	clip.position = Vector2(PAD, HEADER_H + 16.0)
	clip.size = Vector2(content_w, _clip_h)
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(clip)

	_body = Control.new()
	_body.size = Vector2(content_w, _clip_h)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(_body)

	match page:
		0:
			_build_speedrun()
		2:
			_build_timed()
		_:
			_build_stats()

	var hint := _make_label(_hint_text(), FONT_BODY)
	hint.position = Vector2(PAD, PANEL_SIZE.y - HINT_H + 4.0)
	hint.size = Vector2(content_w, 32)
	hint.modulate = COLOR_BODY
	_panel.add_child(hint)


func _title_text() -> String:
	match page:
		0:
			return "竞 速 记 录"
		2:
			return "限 时 挑 战 记 录"
		_:
			return "游 玩 统 计"


func _subtitle_text() -> String:
	if page == 0:
		var n: int = Global.speedrun_records.size()
		return "共 %d 条（最多保留 %d 条）" % [n, Global.SPEEDRUN_RECORD_CAP]
	if page == 2:
		var m: int = Global.timed_records.size()
		return "共 %d 条（最多保留 %d 条）" % [m, Global.TIMED_RECORD_CAP]
	return "全部模式累计"


func _hint_text() -> String:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("is_mobile_platform") and bool(g.call("is_mobile_platform")):
		return "%s 返回" % str(g.call("key_hint", &"取消键"))
	return "↑↓ 滚动 · 滚轮 翻页 · Esc 返回"


# ── 竞速记录 ──

func _build_speedrun() -> void:
	var y: float = 0.0
	var records: Array = Global.speedrun_records
	if records.is_empty():
		y = _add_line("还没有竞速记录。", COLOR_BODY, y)
		y = _add_line("从「开始游戏 → 计时竞速」开一局，通关或中途放弃都会记在这里。", COLOR_MUTED, y)
		_content_h = y
		return

	y = _add_line("── 最佳成绩 ──", COLOR_ACCENT, y)
	var seen: Array[String] = []
	for row: Variant in records:
		if not (row is Dictionary):
			continue
		var r: Dictionary = row
		var cid: String = str(r.get("campaign_id", ""))
		if cid in seen:
			continue
		seen.append(cid)
		var best: Dictionary = Global.speedrun_best_for(cid)
		var name_text: String = str(r.get("campaign", "?"))
		if best.is_empty():
			y = _add_line("%s：暂无通关记录" % name_text, COLOR_MUTED, y)
			continue
		y = _add_line("%s　%s　死亡 %d" % [
			name_text, Global.format_run_time(float(best.get("seconds", 0.0))),
			int(best.get("deaths", 0))], COLOR_GOOD, y)

	y += LINE_H * 0.4
	y = _add_line("── 最近记录 ──", COLOR_ACCENT, y)
	var shown: int = 0
	for row: Variant in records:
		if not (row is Dictionary):
			continue
		if shown >= 10:
			break
		shown += 1
		var r: Dictionary = row
		var cleared: bool = bool(r.get("cleared", false))
		var mark: String = "通关" if cleared else "未通关"
		var diff_name: String = ["简单", "普通", "困难", "专家"][clampi(int(r.get("difficulty", 0)), 0, 3)]
		y = _add_line("%d. %s · %s · %s %s · 死亡 %d · 击杀 %d" % [
			shown,
			str(r.get("campaign", "?")),
			diff_name,
			mark,
			Global.format_run_time(float(r.get("seconds", 0.0))),
			int(r.get("deaths", 0)),
			int(r.get("kills", 0)),
		], COLOR_BODY if cleared else COLOR_MUTED, y)
	_content_h = y


# ── 限时挑战记录 ──
## 限时挑战的「成绩」不是用时越短越好，而是**到达关卡数越深越好**；
## 同深度才比用时（活得久 = 打得稳）。所以这一页的最佳成绩按「关卡数 → 用时」排序，
## 明细里也把「到达 N 关」放在最前面。

func _build_timed() -> void:
	var y: float = 0.0
	var records: Array = Global.timed_records
	if records.is_empty():
		y = _add_line("还没有限时挑战记录。", COLOR_BODY, y)
		y = _add_line("从「开始游戏 → 限时挑战」开一局：每张关卡都有倒计时，", COLOR_MUTED, y)
		y = _add_line("击杀敌人能换时间，倒计时归零即失败。", COLOR_MUTED, y)
		_content_h = y
		return

	y = _add_line("── 最佳成绩 ──", COLOR_ACCENT, y)
	var seen: Array[String] = []
	for row: Variant in records:
		if not (row is Dictionary):
			continue
		var cid: String = str((row as Dictionary).get("campaign_id", ""))
		if cid in seen:
			continue
		seen.append(cid)
		var best: Dictionary = Global.timed_best_for(cid)
		if best.is_empty():
			continue
		var cleared: bool = bool(best.get("cleared", false))
		y = _add_line("%s　%s　到达 %d 关　用时 %s" % [
			str(best.get("campaign", "?")),
			_timed_result_text(best),
			int(best.get("levels", 0)),
			Global.format_run_time(float(best.get("seconds", 0.0)))],
			COLOR_GOOD if cleared else COLOR_BODY, y)

	y += LINE_H * 0.4
	y = _add_line("── 最近记录 ──", COLOR_ACCENT, y)
	var shown: int = 0
	for row: Variant in records:
		if not (row is Dictionary):
			continue
		if shown >= 10:
			break
		shown += 1
		var r: Dictionary = row
		var cleared: bool = bool(r.get("cleared", false))
		var diff_name: String = ["简单", "普通", "困难", "专家"][clampi(int(r.get("difficulty", 0)), 0, 3)]
		y = _add_line("%d. %s · %s · %s　%d 关　%s　连杀 %d" % [
			shown,
			str(r.get("campaign", "?")),
			diff_name,
			_timed_result_text(r),
			int(r.get("levels", 0)),
			Global.format_run_time(float(r.get("seconds", 0.0))),
			int(r.get("best_combo", 0)),
		], COLOR_BODY if cleared else COLOR_MUTED, y)
	_content_h = y


## 一局的结局：通关 / 时间到 / 中途退出（不是所有未通关都是时间到）。
func _timed_result_text(r: Dictionary) -> String:
	if bool(r.get("cleared", false)):
		return "通关"
	if bool(r.get("timed_out", false)):
		return "时间到"
	return "中途退出"


# ── 总游玩统计 ──

func _build_stats() -> void:
	var s: Dictionary = Global.play_stats
	if s.is_empty():
		var y0: float = 0.0
		y0 = _add_line("还没有游玩记录。", COLOR_BODY, y0)
		_content_h = y0
		return
	var runs: int = int(s.get("runs", 0))
	var clears: int = int(s.get("clears", 0))
	var rate: String = "—" if runs <= 0 else "%d%%" % int(round(float(clears) * 100.0 / float(runs)))
	var rows: Array = [
		["游玩局数", "%d" % runs, "通关次数", "%d（%s）" % [clears, rate]],
		["总游玩时长", Global.format_total_playtime(int(s.get("seconds", 0))), "死亡总数", "%d" % int(s.get("deaths", 0))],
		["击杀总数", _num(int(s.get("kills", 0))), "爆头数", _num(int(s.get("headshots", 0)))],
		["造成伤害", _num(int(float(s.get("damage_dealt", 0.0)))), "承受伤害", _num(int(float(s.get("damage_taken", 0.0))))],
		["使用治疗品", "%d 次" % int(s.get("healing_items", 0)), "", ""],
	]
	var y: float = 0.0
	for row: Array in rows:
		y = _add_stat_row(str(row[0]), str(row[1]), str(row[2]), str(row[3]), y)
	_content_h = y


func _add_stat_row(k1: String, v1: String, k2: String, v2: String, y: float) -> float:
	var half: float = (PANEL_SIZE.x - PAD * 2.0) * 0.5
	_put(k1, Vector2(0, y), Vector2(half * 0.55, LINE_H), FONT_BODY, COLOR_MUTED)
	_put(v1, Vector2(half * 0.55, y), Vector2(half * 0.45, LINE_H), FONT_BODY, COLOR_TITLE)
	if not k2.is_empty():
		_put(k2, Vector2(half, y), Vector2(half * 0.55, LINE_H), FONT_BODY, COLOR_MUTED)
		_put(v2, Vector2(half * 1.55, y), Vector2(half * 0.45, LINE_H), FONT_BODY, COLOR_TITLE)
	return y + 44.0


func _num(v: int) -> String:
	## 千分位（1234567 → 1,234,567）：战报数字一眼能读。
	var s: String = str(absi(v))
	var out: String = ""
	var count: int = 0
	for i: int in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if v < 0 else "") + out


func _add_line(text: String, color: Color, y: float) -> float:
	_put(text, Vector2(0, y), Vector2(PANEL_SIZE.x - PAD * 2.0, LINE_H), FONT_BODY, color)
	return y + LINE_H


# ═══════════════════════════════════════
# 输入（滚动 / 关闭）
# ═══════════════════════════════════════

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		get_viewport().set_input_as_handled()
		Global.play_ui_sfx("cancel")
		_close()
		return
	var step: float = 0.0
	if event.is_action_pressed("上"):
		step = -LINE_H * 2.0
	elif event.is_action_pressed("下"):
		step = LINE_H * 2.0
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			step = -LINE_H * 2.0
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			step = LINE_H * 2.0
	if step == 0.0:
		return
	get_viewport().set_input_as_handled()
	Global.play_ui_sfx("cursor")
	_scroll = clampf(_scroll + step, 0.0, maxf(0.0, _content_h - _clip_h + LINE_H))
	if _body != null:
		_body.position.y = -_scroll


func _close() -> void:
	closed.emit()
	queue_free()


# ═══════════════════════════════════════
# 工具
# ═══════════════════════════════════════

func _build_window(pos: Vector2, window_size: Vector2) -> Control:
	var win := Control.new()
	win.position = pos
	win.size = window_size
	win.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(win)

	var bg := TextureRect.new()
	bg.texture = load(WINDOW_BG_PATH) as Texture2D
	bg.size = window_size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(bg)

	var frame := NinePatchRect.new()
	frame.texture = load(WINDOW_FRAME_PATH) as Texture2D
	frame.patch_margin_left = 20
	frame.patch_margin_top = 20
	frame.patch_margin_right = 20
	frame.patch_margin_bottom = 20
	frame.size = window_size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(frame)
	return win


func _put(text: String, pos: Vector2, box: Vector2, size: int, color: Color) -> void:
	var lbl := _make_label(text, size)
	lbl.position = pos
	lbl.size = box
	lbl.modulate = color
	_body.add_child(lbl)


func _make_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", l, size)
		if g.has_method("apply_text_shadow"):
			g.call("apply_text_shadow", l)
	else:
		l.add_theme_font_size_override("font_size", size)
	return l
