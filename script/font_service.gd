extends RefCounted

## ── 架构定位 ──
## 系统：界面字体服务 ｜ 层：服务类（RefCounted，由 Global 持有）
## 联机：纯本机表现，与联机无关
## 职责：界面字体的**唯一真源**：可选字体表、按路径加载+像素化缓存、根 Theme、
##       运行时整树重套、启动自检、漏接审计。
## 依赖：宿主节点（Global，提供 get_tree/autoload 上下文）；被 Global 的转发门面调用
##
## 【为什么从 global.gd 抽出（2026-10-08）】字体逻辑约 270 行、与 Global 其它职责
## （音频/触摸布局/checkpoint/存档/调试）无关，且**外部调用一律走 `Global.<方法>`**。
## 抽出后 Global 只保留同名转发门面 → 20+ 处外部调用点**零改动**，
## 而 global.gd 体积与认知负担显著下降。
##
## 【为什么用 RefCounted + 宿主引用，而不是 autoload 节点】
## 字体服务不需要独立生命周期，也不该多一个 autoload（project.godot 不宜频繁动）。
## Global 在 `_ready` 创建本服务并注入 `_host`，服务内需要场景树时经 `_host.get_tree()` 取。
##
## 【设计约束】本类**不直接 emit Global 的 font_changed 信号** —— 信号由 Global 持有并转发
## （外部一律 `Global.font_changed.connect(...)`）。切换字体时 Global 调本类拿结果、再 emit。

## 可选界面字体路径（两套都是 12px 基底，所以字号铁律对两者通用）。
const FONT_OPTION_PATHS: Array[String] = [
	"res://art/System/fusion-pixel-12px-monospaced-zh_hans.ttf",
	"res://art/System/zpix_12px.ttf",
]
const FONT_OPTION_LABELS: Array[String] = ["缝合像素 12px", "zpix 像素 12px"]
## 各选项对 1769 字样本的实测缺字数（仅日志提示，不参与取字体逻辑）。
const FONT_OPTION_MISSING_HINT: Array[int] = [0, 0]
## 界面字号基底（铁律：界面字号必须是它的整数倍，否则像素字体缩放会糊）。
const UI_FONT_BASE_SIZE: int = 12
## 自检样本（缺任何一个都会在启动日志里点名）。
const FONT_SELF_CHECK_TEXT: String = "开始游戏联机设置退出操作说明装备物品难度简单普通困难专家急救喷雾武器弹药章节安全屋のび太ゾンビ"

## 宿主节点（Global），用于 get_tree / 作为播放器父节点等。
var _host: Node = null
## 当前选择的字体选项索引。
var font_option: int = 0
var _ui_font_cache: Dictionary = {}      ## path → FontFile（null 表示加载失败，避免重复报错）
var _ui_root_theme: Theme = null         ## 挂在场景树根上的默认主题（提供默认字体）


func _init(host: Node) -> void:
	_host = host


func ui_font_option_count() -> int:
	return FONT_OPTION_PATHS.size()


## 当前选项的显示名（设置面板用）。
func font_option_label() -> String:
	return FONT_OPTION_LABELS[clampi(font_option, 0, FONT_OPTION_LABELS.size() - 1)]


## 当前界面字体路径（**唯一真源**）。
func get_ui_font_path() -> String:
	return FONT_OPTION_PATHS[clampi(font_option, 0, FONT_OPTION_PATHS.size() - 1)]


## 按路径取字体（带缓存）。加载失败时**醒目报错**：静默回退会让「字体没打进包」
## 表现为「字形变了 / 缺字」，极难排查（2026-09-24 用户反馈的那类现象）。
func load_ui_font(path: String) -> FontFile:
	if path.is_empty():
		return null
	if _ui_font_cache.has(path):
		return _ui_font_cache[path]
	var ff := load(path) as FontFile
	if ff == null:
		printerr("[Global] ★界面字体加载失败（将回退系统字体，字形与设计不一致）: %s" % path)
	else:
		make_pixel_crisp(ff)
	_ui_font_cache[path] = ff
	return ff


## ★把字体设成「像素字体」应有的样子：**关抗锯齿 + 关次像素定位 + 固定 1:1 栅格化**。
## TTF 导入默认是 Grayscale 抗锯齿 + Auto 次像素定位 —— 12px 原尺寸下几乎看不出，
## 但**字号一放大**（弹药数字是 36px = 3 倍）字形边缘就渗出**零散的灰白像素点**；
## 两个像素字体（缝合像素 / zpix）都有这个问题（2026-09-30 用户实测）。
## **凡是从磁盘新 load 一份字体的地方，都必须过这里** ——
## 只改内存实例，不会写回 .import / 磁盘资源，所以对同一个字体反复调用是幂等的。
##
## ★`oversampling` 也必须钉成 1.0（2026-09-30 用户实测「手机端弹药数字仍有白点」）：
## `oversampling = 0` 的语义是「跟随视口自动超采样」。手机端走的是**分数缩放**
##（`pick_content_scale_stretch()` 对移动端一律返回 FRACTIONAL，本例 1.125 倍），
## 字形被按 1.125 倍栅格化、再缩回 36px 画进 1280×960 的固定画布 →
## 边缘丢像素/多像素，正是那些"零散白点"。像素字体要的是 **1:1 硬边栅格化**。
func make_pixel_crisp(ff: FontFile) -> void:
	if ff == null:
		return
	ff.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	ff.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	ff.oversampling = 1.0


## 当前界面字体资源。加载失败返回 null（调用方自行回退 ThemeDB.fallback_font）。
func get_ui_font() -> FontFile:
	return load_ui_font(get_ui_font_path())


## 解析一个「可能被场景或脚本烘死的字体路径」：
##   空 → 当前选择（跟随开关）；
##   属于可切换字体族（== FONT_OPTION_PATHS 之一）→ 当前选择
##     （**旧场景里烘的界面字体路径自动跟随开关**，不必逐个改 .tscn/.tres）；
##   其它 → 原样返回（真正自定义的字体，例如只为某个特殊字形准备的兜底字体）。
func resolve_ui_font_path(path: String) -> String:
	if path.is_empty():
		return get_ui_font_path()
	if path in FONT_OPTION_PATHS:
		return get_ui_font_path()
	return path


## 解析路径并加载（给「自己持有字体路径」的窗口用）。
func resolve_and_load_font(path: String) -> Font:
	var resolved := resolve_ui_font_path(path)
	var ff := load_ui_font(resolved)
	return ff if ff else ThemeDB.fallback_font


## 把界面字体套到 Label 上。字号被夹到 UI_FONT_BASE_SIZE 的整数倍（像素字体铁律）。
func apply_ui_font(lbl: Label, size: int = UI_FONT_BASE_SIZE) -> void:
	if lbl == null:
		return
	var font := get_ui_font()
	if font:
		lbl.add_theme_font_override("font", font)
	var s: int = maxi(UI_FONT_BASE_SIZE, int(round(float(size) / float(UI_FONT_BASE_SIZE))) * UI_FONT_BASE_SIZE)
	lbl.add_theme_font_size_override("font_size", s)


## 根 Theme：让**未显式指定字体**的控件（Label/Button/RichTextLabel…）也拿到界面字体。
## 只设 default_font/default_font_size，其余样式照旧落到 Godot 内置主题。
func ensure_root_ui_theme() -> Theme:
	if _host == null:
		return _ui_root_theme
	var tree := _host.get_tree()
	if tree == null or tree.root == null:
		return _ui_root_theme
	if _ui_root_theme == null:
		_ui_root_theme = Theme.new()
	_ui_root_theme.default_font = get_ui_font()
	_ui_root_theme.default_font_size = UI_FONT_BASE_SIZE
	if tree.root.theme != _ui_root_theme:
		tree.root.theme = _ui_root_theme
	return _ui_root_theme


## 该 Label 是否「跟随界面字体」（无字体覆盖，或覆盖的就是可切换字体族之一）。
## 带 fallbacks 的运行时字体副本（如战斗 HUD 弹药标签为 ∞ 字形补 DotGothic16）
## 与真正自定义的字体一律返回 false —— 切换字体时不动它们。
## ⚠ Godot 4 没有 get_theme_font_override（只有 get_theme_font，会沿主题链解析），
##    所以这里用「解析后的字体的 resource_path 是否属于字体族」来判定；
##    运行时构造的字体副本用 ui_font_custom 元数据显式排除。
func _label_follows_ui_font(lbl: Label) -> bool:
	if lbl.has_meta(&"ui_font_custom"):
		return false
	var cur: Font = lbl.get_theme_font("font")
	if cur == null:
		return true
	var p: String = cur.resource_path
	if p.is_empty():
		# 主题默认 / ThemeDB 兜底（含未入树的 Label）→ 视为跟随
		return true
	return p in FONT_OPTION_PATHS


## 递归给一棵 UI 树换字体（运行中切换字体用）。返回改动过的 Label 数。
## Label 是 GradientLabel 的内部节点，会被自然遍历到（套同一份字体无副作用）。
func reapply_ui_font_recursive(root: Node) -> int:
	if root == null or not is_instance_valid(root):
		return 0
	var font := get_ui_font()
	if font == null:
		return 0
	var touched: int = 0
	if root is Label:
		var lbl := root as Label
		if _label_follows_ui_font(lbl):
			lbl.add_theme_font_override("font", font)
			touched += 1
	elif root is RichTextLabel:
		var rtl := root as RichTextLabel
		rtl.add_theme_font_override("normal_font", font)
		rtl.add_theme_font_override("bold_font", font)
		touched += 1
	for child: Node in root.get_children():
		touched += reapply_ui_font_recursive(child)
	return touched


## 切换界面字体：写盘由 Global 负责；本函数只做「套主题 + 重套当前场景」，返回重套的 Label 数。
func apply_font_option(index: int) -> int:
	var i: int = clampi(index, 0, FONT_OPTION_PATHS.size() - 1)
	if i == font_option:
		return 0
	font_option = i
	ensure_root_ui_theme()
	var touched: int = 0
	if _host != null:
		var tree := _host.get_tree()
		if tree != null and tree.current_scene != null:
			touched = reapply_ui_font_recursive(tree.current_scene)
	print("[Global] 界面字体已重套到当前场景 %d 个 Label" % touched)
	print("[Global] 界面字体 → %s（%s｜实测缺字 %d/1733，缺处由系统字体顶替）" % [
		font_option_label(), get_ui_font_path().get_file(),
		FONT_OPTION_MISSING_HINT[clampi(font_option, 0, FONT_OPTION_MISSING_HINT.size() - 1)]])
	return touched


## 启动自检：把「字体能不能用、缺哪些字」直接写进日志。
## 用户反馈的「玩家电脑上缺字」需要一条能对证的线索，而不是让它表现为字形突变。
func log_font_self_check() -> void:
	var path := get_ui_font_path()
	var font := get_ui_font()
	if font == null:
		printerr("[Global] ★界面字体不可用：%s —— 已回退系统字体，字形将与其他机器不同。" % path)
		return
	var missing: String = ""
	for i: int in range(FONT_SELF_CHECK_TEXT.length()):
		var ch: String = FONT_SELF_CHECK_TEXT[i]
		if not font.has_char(ch.unicode_at(0)):
			missing += ch
	if missing.is_empty():
		print("[Global] 界面字体自检 OK: %s（%d 个可选字体，自检样本字形全覆盖）" % [
			path.get_file(), FONT_OPTION_PATHS.size()])
	else:
		printerr("[Global] ★界面字体缺字形：%s 缺少「%s」—— 这些字会由系统字体顶替（各机器表现不同）。" % [
			path.get_file(), missing])


## UI 字体审计：找出**没有跟随界面字体**的可见 Label（漏接全局链接的窗口）。
## 返回 {"total": int, "foreign": Array[String]}。供 harness / 手动排查使用。
func audit_ui_fonts(root: Node) -> Dictionary:
	var foreign: Array[String] = []
	var total: int = _audit_ui_fonts_recursive(root, foreign)
	return {"total": total, "foreign": foreign}


func _audit_ui_fonts_recursive(node: Node, foreign: Array[String]) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var total: int = 0
	if node is Label:
		total += 1
		if not _label_follows_ui_font(node as Label):
			var cur: Font = (node as Label).get_theme_font("font")
			var p: String = cur.resource_path if cur else "<null>"
			if p.is_empty():
				p = "<无资源的运行时字体>"
			foreign.append("%s → %s" % [String(node.get_path()), p])
	for child: Node in node.get_children():
		total += _audit_ui_fonts_recursive(child, foreign)
	return total
