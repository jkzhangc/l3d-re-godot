extends Control

## ── 架构定位 ──
## 系统：限时挑战收尾 ｜ 层：表现（Control，代码构建、无 tscn）
## 联机：不涉及（限时挑战是单人模式）
## 职责：「时间到」全屏页：暂停游戏 → 告知挑战失败 → 任意键回标题。
##       回标题走 `Global.go_to_title_screen()`，途中 `finish_run(false)` 会把本局
##       记进限时挑战记录（`timed_out = true`），所以这里**不需要**自己记账。
## 依赖：Global（字体 / 音效 / 回标题）；由 `TimedChallenge._show_fail()` 挂在 CanvasLayer 上
##
## ★字号铁律：像素字体只允许 12 的整倍（本文件 24 / 36 / 48）。

const WINDOW_BG_PATH := "res://art/System/Window background color.png"
const WINDOW_FRAME_PATH := "res://art/System/Window frame.png"

const FONT_TITLE: int = 48
const FONT_BODY: int = 24
const PANEL_SIZE: Vector2 = Vector2(720.0, 300.0)

const COLOR_TITLE := Color(1.0, 0.52, 0.44)
const COLOR_BODY := Color(0.88, 0.86, 0.80)
const COLOR_MUTED := Color(0.66, 0.64, 0.60)

var _closing: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	## 挂上即暂停：尸潮/敌人不再动，玩家也不会在黑屏底下乱跑。
	get_tree().paused = true
	Global.play_ui_sfx("cancel")


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.80)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var vp: Vector2 = get_viewport_rect().size
	var panel := _build_window((vp - PANEL_SIZE) * 0.5, PANEL_SIZE)

	var title := _make_label("时 间 到", FONT_TITLE)
	title.position = Vector2(0, 34)
	title.size = Vector2(PANEL_SIZE.x, 60)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = COLOR_TITLE
	panel.add_child(title)

	var sub := _make_label("限时挑战失败", FONT_BODY)
	sub.position = Vector2(0, 108)
	sub.size = Vector2(PANEL_SIZE.x, 32)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = COLOR_BODY
	panel.add_child(sub)

	## 进度小结：玩家最想知道「我打到哪了」。
	var tc: Node = get_node_or_null("/root/TimedChallenge")
	var line: String = "本关倒计时已耗尽"
	if tc != null:
		line = "到达第 %d 关　最长连杀 %d　本局击杀 %d" % [
			int(tc.get("levels_entered")), int(tc.get("best_combo")), _total_kills()]
	var info := _make_label(line, FONT_BODY)
	info.position = Vector2(0, 154)
	info.size = Vector2(PANEL_SIZE.x, 32)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.modulate = COLOR_MUTED
	panel.add_child(info)

	var hint := _make_label("按任意键返回标题（本局已记入限时挑战记录）", FONT_BODY)
	hint.position = Vector2(0, 214)
	hint.size = Vector2(PANEL_SIZE.x, 32)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = COLOR_BODY
	panel.add_child(hint)


func _total_kills() -> int:
	var stats: Node = get_node_or_null("/root/ChapterStats")
	if stats != null and stats.has_method("get_campaign_totals"):
		var t: Dictionary = stats.call("get_campaign_totals")
		return int(t.get("kills", 0))
	return 0


func _input(event: InputEvent) -> void:
	if _closing:
		return
	var go: bool = false
	if event is InputEventKey and event.pressed and not event.echo:
		go = true
	elif event is InputEventMouseButton and event.pressed:
		go = true
	elif event is InputEventScreenTouch and event.pressed:
		go = true
	elif event.is_action_pressed("确定键") or event.is_action_pressed("取消键"):
		go = true
	if not go:
		return
	get_viewport().set_input_as_handled()
	_exit()


func _exit() -> void:
	_closing = true
	get_tree().paused = false
	Global.play_ui_sfx("confirm")
	## TimedChallenge 是 autoload，本层挂在它下面，跨场景不会自动销毁 → 必须自己摘掉。
	var host: Node = get_parent()
	Global.go_to_title_screen()
	if host != null and is_instance_valid(host):
		host.queue_free()


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
