extends CanvasLayer

## ── 架构定位 ──
## 系统：导演系统调试 ｜ 层：UI（CanvasLayer，由 Director 懒创建）
## 联机：仅本机显示（Host/单机）；面板本身不改变任何导演状态
## 职责：实时展示导演的决策输入与状态：阶段/紧张度/进度/人口/名额/Boss 牌堆/投放/最近事件。
## 依赖：`Director.debug_snapshot()`（数据全部由导演侧组装，面板只负责排版）
##
## 【为什么做成只读面板】导演参数有 100+ 个，改一个就要猜"为什么这次没刷/为什么 Tank 这么早"。
## 过去只能读 `print` 日志（刷屏且没有上下文）。面板把「决策输入」和「已经发生的决定」
## 摊在一屏里，调参与复现都靠它。
##
## 【热键】F3（`Director._unhandled_input`）→ 只在 `Global.debug_enabled` 为真时生效，
## 导出包（release）该值为 false，打包即自动关闭，不需要手动改配置。

const REFRESH_SEC: float = 0.2
const PANEL_LAYER: int = 84        ## 跳转按钮(85)/黑幕(90) 之下，不遮挡
const BAR_CELLS: int = 10

var _director: Node = null
var _panel: PanelContainer = null
var _label: Label = null
var _timer: float = 0.0


func setup(director_node: Node) -> void:
	_director = director_node


func _ready() -> void:
	layer = PANEL_LAYER
	_build()
	visible = false


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.position = Vector2(12, 12)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.04, 0.05, 0.86)
	sb.border_color = Color(0.25, 0.25, 0.28, 0.9)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	_label = Label.new()
	_label.name = "Text"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.custom_minimum_size = Vector2(430, 0)
	var font: Font = null
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("get_ui_font"):
		font = g.call("get_ui_font")
	if font != null:
		_label.add_theme_font_override("font", font)
	## 项目铁律：字号取 12 的整倍
	_label.add_theme_font_size_override("font_size", 12)
	_label.add_theme_color_override("font_color", Color(0.86, 0.88, 0.9))
	_panel.add_child(_label)


## F3 调用：切换显隐，打开时立刻刷一次（不等 0.2s 节拍）。
func toggle() -> void:
	visible = not visible
	if visible:
		_timer = 0.0
		_refresh()


func is_open() -> bool:
	return visible


func _process(delta: float) -> void:
	if not visible:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REFRESH_SEC
	_refresh()


func _refresh() -> void:
	if _label == null:
		return
	if _director == null or not is_instance_valid(_director):
		_label.text = "导演未就绪"
		return
	var snap: Dictionary = _director.call("debug_snapshot")
	_label.text = _format(snap)


# ═══════════════════════════════════════
# 排版
# ═══════════════════════════════════════

func _format(s: Dictionary) -> String:
	var lines: Array[String] = []
	var phase: String = str(s.get("phase", "?"))
	var left: float = float(s.get("phase_left", 0.0))
	var total: float = float(s.get("phase_duration", 0.0))
	lines.append("导演 F3 关闭    %s" % str(s.get("scene", "")))
	lines.append("阶段 %-8s 剩余 %5.1fs / %.1fs" % [phase, maxf(left, 0.0), total])
	## 智能尸潮压力表（2026-10-31）：BUILD 段填满即开尸潮 —— 直接看「还差多少」。
	lines.append("尸潮压力 %3.0f / %3.0fs  本章击杀 %d  每杀 +%.1fs" % [
		float(s.get("horde_progress", 0.0)), float(s.get("horde_target", 0.0)),
		int(s.get("horde_kills", 0)), float(s.get("horde_per_kill", 0.0))])
	## 硬间隔闸：距上一波多久 / 还差多少才允许下一波（-1 = 本图还没打过）。
	var since_peak: float = float(s.get("horde_since_peak", -1.0))
	var gap: float = float(s.get("horde_gap", 0.0))
	var since_txt: String = "新图" if since_peak < 0.0 else "%.0fs" % since_peak
	lines.append("距上一波 %-6s / 硬闸 %.0fs   BUILD 第 %d 段" % [
		since_txt, gap, int(s.get("horde_build_index", 0))])
	## 开局附加参数（2026-10-31）：全默认时不占篇幅，改过的才列出来。
	var mods: Array[String] = []
	if not bool(s.get("mod_berserk", true)):
		mods.append("尸潮不狂暴")
	if bool(s.get("mod_no_horde", false)):
		mods.append("关闭尸潮")
	if bool(s.get("mod_no_pressure", false)):
		mods.append("不加压")
	if not mods.is_empty():
		lines.append("附加：" + " / ".join(mods))

	var inten: float = float(s.get("intensity", 0.0))
	var raw: float = float(s.get("intensity_raw", 0.0))
	lines.append("紧张度 %.2f %s raw %.2f  交战=%s" % [
		inten, _bar(inten), raw, _yn(bool(s.get("in_combat", false)))])

	var prog: float = float(s.get("progress", 0.0))
	var pdesc: String = "出口 %s" % str(s.get("progress_exit", "-")) if bool(s.get("progress_has_exit", false)) \
		else "无出口(里程口径)"
	lines.append("进度 %.2f %s  %s  里程 %.0fpx" % [
		prog, _bar(prog), pdesc, float(s.get("trail", 0.0))])

	lines.append("人口 存活 %d / 上限 %d   威胁圈 %d   预算 %d" % [
		int(s.get("alive", 0)), int(s.get("active_cap", 0)),
		int(s.get("threat", 0)), int(s.get("budget", 0))])
	lines.append("特感 %d/%d   首只 %4.0fs   冷却 %4.0fs" % [
		int(s.get("specials_alive", 0)), int(s.get("specials_max", 0)),
		float(s.get("specials_first_left", 0.0)), float(s.get("specials_cool_left", 0.0))])
	lines.append("慈悲闸 %s   加压已禁 %s" % [
		_yn(bool(s.get("mercy", false))), _yn(bool(s.get("pressure_blocked", false)))])

	lines.append("Boss 牌 %d 张 %s   Tank 牌 %d  已发 T%d/%d W%d/%d" % [
		int(s.get("deck_size", 0)), str(s.get("deck", "")), int(s.get("deck_tank_cards", 0)),
		int(s.get("tanks_dealt", 0)), int(s.get("tanks_max", 0)),
		int(s.get("witches_dealt", 0)), int(s.get("witches_max", 0))])
	lines.append("     里程 %.0f  锚点下一个 %.0f  Tank 闸 %.2f~%.2f" % [
		float(s.get("boss_trail", 0.0)), float(s.get("boss_next_anchor", 0.0)),
		float(s.get("tank_pos_min", 0.0)), float(s.get("tank_pos_max", 0.0))])
	lines.append("     干旱 %d  上一图有 Tank=%s  本图不放 Tank=%s" % [
		int(s.get("tank_drought", 0)), _yn(bool(s.get("prev_map_had_tank", false))),
		_yn(int(s.get("deck_tank_cards", 0)) == 0)])

	## 防守战 Tank 供给（只在开/有需求时显示，平时不占屏）
	var hd: int = int(s.get("holdout_tank_demand", 0))
	var h_enabled: bool = bool(s.get("holdout_tank_enabled", false))
	if hd > 0 or (h_enabled and float(s.get("holdout_tank_cooldown", 0.0)) > 0.0):
		lines.append("防守战Tank 需求 %d 只  冷却 %4.1fs  首只 %4.1fs  重试 %3.1fs" % [
			hd, float(s.get("holdout_tank_cooldown", 0.0)),
			float(s.get("holdout_tank_first", 0.0)), float(s.get("holdout_tank_retry", 0.0))])
		lines.append("          需求间隔 %.0fs（需求>0 时替代 90~150s 环境冷却）" % float(
			s.get("holdout_tank_interval", 0.0)))

	lines.append("投放 上次 %.0fs 前 %s   下次检查 %.1fs" % [
		float(s.get("item_last_age", 0.0)), str(s.get("item_last", "-")),
		float(s.get("item_check_left", 0.0))])
	lines.append("     怜悯 冷却剩 %.0fs   低血计时 %.0fs   倒地=%s   上次 %s" % [
		float(s.get("fail_safe_ready_in", 0.0)), float(s.get("fail_safe_low_hp", 0.0)),
		_yn(bool(s.get("fail_safe_downed", false))), str(s.get("fail_safe_last", "无"))])

	lines.append("回收 存活 %d / 尸体 %d   Boss BGM=%s" % [
		int(s.get("recycle_alive", 0)), int(s.get("recycle_corpse", 0)),
		_yn(bool(s.get("boss_music", false)))])

	var events: Array = s.get("events", [])
	if not events.is_empty():
		lines.append("── 最近事件 ──")
		for e: Variant in events:
			lines.append("  " + str(e))
	return "\n".join(lines)


func _bar(v: float) -> String:
	var n: int = clampi(int(round(clampf(v, 0.0, 1.0) * BAR_CELLS)), 0, BAR_CELLS)
	var s: String = ""
	for i: int in range(BAR_CELLS):
		s += "█" if i < n else "░"
	return s


func _yn(b: bool) -> String:
	return "是" if b else "否"
