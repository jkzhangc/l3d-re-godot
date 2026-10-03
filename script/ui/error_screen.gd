extends CanvasLayer

## ── 架构定位 ──
## 系统：诊断 ｜ 层：表现（CanvasLayer，**全代码构建、无 tscn**；由 Global 在捕获到错误时创建）
## 联机：不涉及（各端各自弹；一端崩了不影响另一端）
## 职责：报错时**暂停游戏**并盖一层半透明黑底 + 报错详情 + 左下角红字提示（让玩家把日志发群）。
## 依赖：GameLog（路径与最近日志）、Global（字体 / 挂载点）
##
## 【用户需求（2026-10-02）原文】
## 「报错界面是半透明的黑色背景加上报错文字说明（比如哪里的代码错误那些就是正常的报错信息）。
##   然后左下角写着：游戏报错了！请截图或者把游戏目录下的报错文件发到交流群里！」
##
## 【为什么是 CanvasLayer 而不是 Control】它必须在**暂停**下仍然显示与响应（`PROCESS_MODE_ALWAYS`），
## 且要压过所有既有 UI（触摸层最高会抬到 110）→ 本层取 `layer = 200`。

## 层级：压过触摸层（最高 110）与一切游戏 UI。
const LAYER_INDEX: int = 200
const FONT_TITLE: int = 36
const FONT_BODY: int = 24
## 正文最多显示行数（超出的进日志文件，不塞进界面；给调用栈与最近日志留出面板空间）
const MAX_BODY_LINES: int = 8
## 最近日志显示行数
const MAX_RECENT_LINES: int = 6
## 最短显示时间（秒）：避免触摸误触立刻关掉，玩家还没看清
const MIN_VISIBLE_SEC: float = 0.6

## ── 节流（跨实例保留）──
## 引擎常在连续若干帧重复打印同一条错误 → 同一条只弹一次；且一个会话最多弹几次，
## 避免"错误风暴"把玩家锁在一个又一个弹窗里（超出的仍然写进日志文件）。
const DEDUP_WINDOW_SEC: float = 3.0
const MAX_POPUPS_PER_SESSION: int = 6
static var _last_key: String = ""
static var _last_msec: int = 0
static var _popups_shown: int = 0

## 日志落盘入口（preload 常量而非 class_name，见 MEMORY「class_name 不跨文件」）。
const GAME_LOG := preload("res://script/game_log.gd")

var _info: Dictionary = {}
var _shown_at: float = 0.0
## 弹出前的暂停状态，关闭时还原（不要把"本来就在暂停"的场面醒过来）
var _prev_paused: bool = false

## 是否值得为这条错误弹窗。由 Global 在创建本层前调用。
static func should_show(info: Dictionary) -> bool:
	## ① 引擎噪音白名单：**已被兜底、不影响可玩性**的错误不弹窗（照写日志文件）。
	## 判据是"报错内容"而非"是否报错"——玩家看到弹窗会以为游戏坏了，直接去群里问，
	## 反而淹没真正的致命错误。逐条写明理由，新增前先确认真的不影响玩法。
	if is_known_noise(info):
		return false
	if _popups_shown >= MAX_POPUPS_PER_SESSION:
		return false
	var key: String = "%s|%s" % [str(info.get("message", "")), str(info.get("where", ""))]
	var now: int = Time.get_ticks_msec()
	if key == _last_key and float(now - _last_msec) < DEDUP_WINDOW_SEC * 1000.0:
		return false
	_last_key = key
	_last_msec = now
	_popups_shown += 1
	return true


## 引擎噪音白名单（**只降级为"写日志、不弹窗"**，绝不吞掉日志）。
## ★判断标准：这条错误是否会让玩家无法继续游戏？不会 → 不值得弹窗打断他。
const NOISE_PATTERNS: Array[String] = [
	## 2026-10-02 用户实机截图：旧导出包把 8 月已重命名的 .wav 资源打了进去，
	## 加载失败 `No loader found for resource`。**只影响那一声音效不响**，
	## 游戏完全可玩（音效字段是 null 兜底）→ 不该弹窗打断玩家。
	"No loader found for resource",
	## 资源缺失的其它表述（同一类问题）。
	"Cannot open file",
	"Failed loading resource",

	## ── 2026-10-03：一批「有兜底 / 属正常状态」的运行期提示 ──
	## 【起因】用户实机报「一开防守战机器就弹报错」，截图里那条是
	## `[HoldoutMachine] 固定刷怪点有 4/4 个落在作者禁刷层(NoSpawn)内 —— 按「显式点位优先」
	## 仍会照常使用`，**行为完全正常、游戏照常运行**，却把玩家打断了。
	## 【系统性根因】Godot 的 `push_warning` 与 `push_error` **走同一条 Logger 通道**
	## （`_log_error`；引擎不区分二者，那个 error 布尔只覆盖 print/printerr）——
	## 所以「预期内的提示」一旦写成 `push_warning`，就会被报错界面当成错误弹出来。
	## 这与项目既有铁律「**预期情况别 printerr**」（UPnP 失败改 print）是同一条道理。
	## 【处置】逐条核对后统一降级：**只写日志、不弹窗**（绝不吞日志）。
	## ⚠ 判据仍是本清单既有标准：**这条会不会让玩家无法继续游戏？不会 → 不值得弹窗。**
	## 新增前务必先确认真的不影响可玩性，宁可偶尔多弹一次，也别把真错误吞掉。
	"固定刷怪点有",              # 点位被占/压墙 → 已退回屏幕外刷法，敌人照常出现
	"落在作者禁刷层",            # 显式点位优先，行为照常（业务侧也已降级为 print）
	"落点四周无空位",            # 保留原落点 / 退回基准点，掉落物不会消失
	"等待确认超时",              # 联机结算页：超时后强制收口，流程继续
	"等待玩家状态同步超时",      # 同上（远端确认超时）
	"找不到 NetworkWorld",       # 单机本来就没有 NetworkWorld（属正常）；联机侧都有回退
	"联机世界未就绪",            # 安全门请求被忽略（换图时序竞态，下次交互可重试）
	"触摸层不存在",              # 桌面端本来就没有虚拟触摸层（源码注释已写明「属正常」）
	"已改用",                    # 玩家槽位点位不可用 → 已改用备用位，出生照常
	"存在重复入口 ID",           # 取第一个入口，有回退
	"未找到入口 ID",             # 保留默认出生点，有回退
	"未设置 target_scene",       # 跳过该条传送点配置，不影响其它条目
	## ⚠ 用「关键词」而非整句，避免语序差异漏匹配（本批实测：LootDropper 写的是
	##   「不支持的掉落条目类型」、random_pickup 写的是「掉落池条目类型不支持」，
	##   二者语序相反 —— 用整句会漏一条）。
	"掉落条目类型",              # 跳过该掉落条目（LootDropper）
	"掉落池条目类型",            # 同上（random_pickup，另一处文案）
	"背景素材加载失败",          # 退回纯色底，可玩性不受影响
	"excluded_nodes",            # 该排除项被忽略，色调效果照常生效
	"VXAnimSprite:",             # 动画素材缺失 → 跳过初始化（表现为该动画不播）
]


## 这条错误是否属于「已兜底的引擎噪音」。命中任一白名单条目即返回 true。
static func is_known_noise(info: Dictionary) -> bool:
	var text: String = "%s %s" % [str(info.get("message", "")), str(info.get("code", ""))]
	for pattern: String in NOISE_PATTERNS:
		if text.find(pattern) >= 0:
			return true
	return false


## 用例 / 调试用：复位节流（同一进程里多次验证弹窗行为）。
static func reset_throttle() -> void:
	_last_key = ""
	_last_msec = 0
	_popups_shown = 0


func _init(info: Dictionary = {}) -> void:
	_info = info


func _ready() -> void:
	layer = LAYER_INDEX
	process_mode = Node.PROCESS_MODE_ALWAYS
	_prev_paused = get_tree().paused
	get_tree().paused = true
	_shown_at = float(Time.get_ticks_msec()) / 1000.0
	_build()


func _input(event: InputEvent) -> void:
	## ★项目铁律：菜单输入「**消费了才标记**」——标记会掐掉触摸事件，但本层是最高模态，
	## 必须吃掉，否则玩家会误操作到下面的游戏。
	if event.is_action_pressed("确定键") or event.is_action_pressed("取消键"):
		_dismiss()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		_dismiss()
		get_viewport().set_input_as_handled()


func _dismiss() -> void:
	## 最短显示时间内不响应（防触摸误触）
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - _shown_at < MIN_VISIBLE_SEC:
		return
	get_tree().paused = _prev_paused
	GAME_LOG.log_event("报错界面", "玩家关闭报错界面，游戏继续")
	queue_free()


# ═══════════════════════════════════════
# 构建
# ═══════════════════════════════════════

func _build() -> void:
	var root := Control.new()
	root.name = "ErrorRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var canvas: Vector2 = get_viewport().get_visible_rect().size

	## ① 半透明黑底（用户原话：半透明的黑色背景）
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	## ② 面板
	var panel_w: float = minf(1120.0, canvas.x - 120.0)
	var panel_h: float = minf(700.0, canvas.y - 120.0)
	var panel := ColorRect.new()
	panel.color = Color(0.10, 0.08, 0.08, 0.97)
	panel.size = Vector2(panel_w, panel_h)
	panel.position = ((canvas - panel.size) * 0.5).floor()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	## RM 风双线框（与成就弹窗同款观感）
	var frame := ColorRect.new()
	frame.color = Color(0.85, 0.35, 0.32, 1.0)
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

	var pad: float = 36.0
	var text_w: float = panel_w - pad * 2.0

	var title := _label("游戏发生错误", FONT_TITLE)
	title.position = Vector2(pad, 26)
	title.size = Vector2(text_w, 44)
	title.modulate = Color(1.0, 0.55, 0.5)
	panel.add_child(title)

	var y: float = 92.0

	## ③ 报错正文（错误消息 + 位置）——用户原话「比如哪里的代码错误那些」
	var msg: String = str(_info.get("message", "(未提供错误信息)"))
	for line: String in _wrap(msg, text_w, FONT_BODY, MAX_BODY_LINES):
		var l: Label = _label(line, FONT_BODY)
		l.position = Vector2(pad, y)
		l.size = Vector2(text_w, 30)
		panel.add_child(l)
		y += 32.0

	var where: String = str(_info.get("where", ""))
	if not where.is_empty():
		y += 6.0
		var wl := _label("位置：%s" % where, FONT_BODY)
		wl.position = Vector2(pad, y)
		wl.size = Vector2(text_w, 30)
		wl.modulate = Color(1.0, 0.82, 0.45)
		panel.add_child(wl)
		y += 36.0

	## ③b 调用栈（"哪一行调过来的"——引擎给了就显示，最多 5 行）
	var stack: Array = _info.get("stack", [])
	if not stack.is_empty():
		y += 4.0
		var shown: int = 0
		for s: String in stack:
			if shown >= 5:
				break
			var sl := _label("  " + _ellipsize(s, text_w - 24.0, FONT_BODY), FONT_BODY)
			sl.position = Vector2(pad + 12, y)
			sl.size = Vector2(text_w - 12, 28)
			sl.modulate = Color(0.86, 0.72, 0.60)
			panel.add_child(sl)
			y += 28.0
			shown += 1

	## ④ 最近日志（给玩家/群友一眼看到上下文）
	y += 10.0
	var sep := ColorRect.new()
	sep.color = Color(0.85, 0.35, 0.32, 0.55)
	sep.position = Vector2(pad, y)
	sep.size = Vector2(text_w, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(sep)
	y += 12.0

	var recent: Array = GAME_LOG.recent_lines()
	var start: int = maxi(0, recent.size() - MAX_RECENT_LINES)
	for i: int in range(start, recent.size()):
		var rl: Label = _label(_ellipsize(str(recent[i]), text_w, FONT_BODY), FONT_BODY)
		rl.position = Vector2(pad, y)
		rl.size = Vector2(text_w, 28)
		rl.modulate = Color(0.72, 0.70, 0.66)
		panel.add_child(rl)
		y += 28.0

	## ⑤ 日志文件路径 + 关闭提示（面板底部）
	var path_label := _label("日志文件：%s" % GAME_LOG.primary_path(), FONT_BODY)
	path_label.position = Vector2(pad, panel_h - 84)
	path_label.size = Vector2(text_w, 30)
	path_label.modulate = Color(0.80, 0.78, 0.72)
	panel.add_child(path_label)

	var hint := _label("按确定键 / 点击屏幕关闭并继续游戏", FONT_BODY)
	hint.position = Vector2(pad, panel_h - 50)
	hint.size = Vector2(text_w, 30)
	hint.modulate = Color(0.70, 0.68, 0.64)
	panel.add_child(hint)

	## ⑥ 左下角红字提示（用户指定的原话，整屏左下角、不在面板内）
	var tip := _label("游戏报错了！请截图或者把游戏目录下的报错文件发到交流群里！", FONT_BODY)
	tip.position = Vector2(24, canvas.y - 52)
	tip.size = Vector2(canvas.x - 48, 32)
	tip.modulate = Color(1.0, 0.35, 0.32)
	root.add_child(tip)


func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 字体唯一入口（禁硬编码 .ttf / 字号必须是 12 的整倍）
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", l, size)
	else:
		l.add_theme_font_size_override("font_size", size)
	return l


## 预先折行（★铁律：别用 `Label.autowrap_mode` —— 父节点不是 Container 时折行高度会算错）。
## 逐字符累加测宽，超宽即断；最多 `max_lines` 行，超出以 `…` 结尾。
func _wrap(text: String, max_w: float, font_size: int, max_lines: int) -> Array[String]:
	var font: Font = _ui_font()
	var out: Array[String] = []
	if font == null:
		out.append(text)
		return out
	var line: String = ""
	for i: int in text.length():
		var ch: String = text[i]
		if ch == "\n":
			out.append(line)
			line = ""
			continue
		var probe: String = line + ch
		if font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > max_w and not line.is_empty():
			out.append(line)
			line = ch
		else:
			line = probe
	if not line.is_empty():
		out.append(line)
	if out.size() > max_lines:
		out = out.slice(0, max_lines)
		out[max_lines - 1] = out[max_lines - 1] + " …"
	return out


## 单行截断到指定宽度（用于最近日志那种"不该换行"的条目）。
func _ellipsize(text: String, max_w: float, font_size: int) -> String:
	var font: Font = _ui_font()
	if font == null:
		return text
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
		return text
	var s: String = ""
	for i: int in text.length():
		var probe: String = s + text[i]
		if font.get_string_size(probe + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > max_w:
			break
		s = probe
	return s + "…"


func _ui_font() -> Font:
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("get_ui_font"):
		return g.call("get_ui_font")
	return null
