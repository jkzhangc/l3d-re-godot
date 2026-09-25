extends Node

## ── 架构定位 ──
## 系统：全局配置 ｜ 层：单例（autoload: Global）
## 联机：仅本机设置，不放权威事实
## 职责：跨场景共享的本机设置：调试开关、文字渲染默认值、色表缓存、音量总线、死亡演出参数、待生效到达点与检查点。
## 依赖：被几乎所有脚本读取；不反向依赖玩法实体

## 全局单例 — 跨场景共享的数据和开关
##
## 这里适合放本机设置、UI 缓存、战役选择和跨场景配置；不要把联机 HP、背包、伤害、敌人等
## 权威事实写在 Global。联机状态由 PlayerState + Players 保存，并由 Host 的 NetworkWorld/Net 写入。
# ═══════════════════════════════════════
# Debug 开关
# ═══════════════════════════════════════
var debug_enabled: bool = true:
	set(v):
		debug_enabled = v
		print("[Global] debug = %s" % v)

var debug_visuals: bool = false

# ═══════════════════════════════════════
# 设置（音量 / 固定朝向）
# ═══════════════════════════════════════
var music_volume: int = 80      ## 音乐音量 0–100
var sfx_volume: int = 80        ## 音效音量 0–100
var facing_lock_mode: int = 0   ## 固定朝向模式: 0=切换式, 1=按住式
var menu_item_centered: bool = true  ## 标题菜单文字居中排列（设置里可开关，2026-09-14 用户要求默认居中）


## 武器/物品快捷键（1~5）统一轮询入口。
## Godot 动作默认子集匹配：Ctrl+1 会同时命中「主武器键」(裸1)——表现为
## Ctrl+1~3 切换队员的同时举起武器（2026-09-14 用户报告）。这里在 Ctrl 按住时
## 统一忽略 1~5，让位给「选择队员N键」。
## ⚠ 行走键=Ctrl（按住式）：按住 Ctrl 行走期间 1~5 暂不可用，松开 Ctrl 再按即可。
func item_key_just_pressed(action: StringName) -> bool:
	return Input.is_action_just_pressed(action) and not Input.is_physical_key_pressed(KEY_CTRL)

## 角色显示名映射（CharacterData.character_name 日文键 → 中文显示）。
## 终章 ED 对话与 credits 战报共用（2026-09-14）。查不到的键原样返回。
const CHARACTER_NAME_ZH: Dictionary = {
	"のび太": "野比大雄",
	"ジャイアン": "刚田武（胖虎）",
	"静香": "源静香",
	"スネ夫": "骨川小夫",
	"聖奈": "绿川圣奈",
	"健治": "翁蛾健治",
	"出木杉": "出木杉英才",
	"安雄": "手雷安雄",
	"サーシャ": "莎莎",
	"咲夜": "樱井咲夜",
}

# ═══════════════════════════════════════
# 文字渲染全局设置（各 UI 场景读取这些默认值）
# ═══════════════════════════════════════
@export_group("文字默认")
## ⚠ 2026-09-24：字体路径**不再从这里取**。界面字体统一由「设置 → 界面字体」选择，
## 并经 get_ui_font() / resolve_ui_font_path() / apply_ui_font() 三个入口提供
## （见下方「界面字体」区块）。旧的 text_font_path(ark-16px，实测缺字 1513/1733)
## 与 text_font_path_small(ark-12px，缺 56) 已删除 —— 它们是「同一界面两套字体家族
## 混用」与「玩家机器上缺字」的来源之一。
@export var text_color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var text_color_index: int = 0
@export var text_color_row: int = 0
@export var text_bold: bool = false
@export var text_outline: bool = false
@export var text_outline_color: Color = Color.BLACK
@export var text_outline_width: float = 1.0
@export var text_shadow: bool = true
@export var text_shadow_color: Color = Color(0, 0, 0, 1)
@export var text_shadow_offset: Vector2 = Vector2(2, 2)

# ═══════════════════════════════════════
# 文字资源缓存（避免重复 Image.load_from_file）
# ═══════════════════════════════════════
var _cached_color_img: Image = null
var _cached_color_img_path: String = ""


## 返回缓存的色表 Image，供 GradientLabel 共享使用。
## Image.load_from_file() 无缓存，统一从这里获取避免重复 I/O。
func get_cached_color_image() -> Image:
	if _cached_color_img and _cached_color_img_path == text_color_sheet_path:
		return _cached_color_img
	var color_texture := ResourceLoader.load(text_color_sheet_path) as Texture2D
	_cached_color_img = color_texture.get_image() if color_texture else null
	_cached_color_img_path = text_color_sheet_path
	if _cached_color_img:
		print("[Global] 色表缓存: %d×%d" % [_cached_color_img.get_width(), _cached_color_img.get_height()])
	else:
		printerr("[Global] 色表加载失败: %s" % text_color_sheet_path)
	return _cached_color_img


# ═══════════════════════════════════════
# 统一文字样式辅助（普通 Label 的 GradientLabel 等价路径）
# ═══════════════════════════════════════
## 拿不到 GradientLabel 的场合（多行自动换行 / 容器内 Label / 运行时创建的提示字），
## 用这两个方法套上全局字体与阴影；参数一律以本文件的 text_* 导出项为准，
## 改这里的值即可整体调整全游戏字体效果。

## 取全局界面字体。2026-09-24 起**不再按字号分 12/16px 两个家族** —— 界面字体统一为
## 可切换的 12px 基底字体，字号只由调用方给（须是 12 的整数倍，见 apply_ui_font）。
func get_text_font(_font_size: int = UI_FONT_BASE_SIZE) -> Font:
	var ff := get_ui_font()
	return ff if ff else ThemeDB.fallback_font


## 给普通 Label 套全局阴影（Label 原生 shadow 主题项）。
## GradientLabel 与 style_plain_label 内部也走同一组参数。
func apply_text_shadow(lbl: Label) -> void:
	if lbl == null:
		return
	if text_shadow:
		lbl.add_theme_color_override("font_shadow_color", text_shadow_color)
		lbl.add_theme_constant_override("shadow_offset_x", int(round(text_shadow_offset.x)))
		lbl.add_theme_constant_override("shadow_offset_y", int(round(text_shadow_offset.y)))


# ═══════════════════════════════════════
# 界面字体（可切换）—— 全 UI 取字体的唯一入口
# ═══════════════════════════════════════
## 玩家可在「标题画面 → 设置 → 界面字体」切换的两套像素字体。两套都是 **12px 基底**，
## 所以字号铁律（12 的整数倍：12/24/36）对两者通用，切换只换字体资源、不动任何字号。
##
## 【为什么需要这个开关】2026-09 用户反馈「玩家下载的版本没问题，但电脑上字体缺字」。
## 像素字体的字形覆盖差异极大，缺字时 Godot 会走 FontFile.allow_system_fallback →
## 拿**玩家机器上的系统字体**顶上：同一份游戏在不同电脑上字形不同，系统里没有合适
## CJK 字体时直接显示豆腐块。实测覆盖（对全项目 1733 个中日文字符取样，
## 探针脚本 .workbuddy/tmp/probe_font.gd）：
##   fusion-pixel-12px-monospaced-zh_hans   缺 0      ← 界面定稿（默认）
##   ark-pixel-12px-monospaced-zh_cn        缺 56
##   ark-pixel-16px-monospaced-zh_cn        缺 1513   ⚠ 纯日文覆盖，不可作界面字体
##   DotGothic16-Regular（日文字体）         缺 506    ⚠ 不可作界面字体
##
## 【铁律】任何 UI 都不许再硬编码 .ttf 路径 —— 一律经 resolve_ui_font_path() /
## get_ui_font() / apply_ui_font() 取值。否则「切换字体」覆盖不到那个窗口。
const FONT_OPTION_PATHS: Array[String] = [
	"res://art/System/fusion-pixel-12px-monospaced-zh_hans.ttf",
	"res://art/System/ark-pixel-12px-monospaced-zh_cn.ttf",
]
const FONT_OPTION_LABELS: Array[String] = ["缝合像素 12px", "方舟像素 12px"]
## 各选项对上述 1733 字样本的实测缺字数（仅用于日志提示，不参与取字体逻辑）。
const FONT_OPTION_MISSING_HINT: Array[int] = [0, 56]
## 界面字号基底（铁律：界面字号必须是它的整数倍，否则像素字体缩放会糊）
const UI_FONT_BASE_SIZE: int = 12
## 自检样本（缺任何一个都会在启动日志里点名，用来直接回答「为什么缺字」）
const FONT_SELF_CHECK_TEXT: String = "开始游戏联机设置退出操作说明装备物品难度简单普通困难专家急救喷雾武器弹药章节安全屋のび太ゾンビ"

## 字体切换广播（运行中需要立刻换字的 UI 可连它重新套字体；常规路径由
## set_font_option → reapply_ui_font_recursive 统一处理，一般不必自己连）。
signal font_changed(font_path: String)

var font_option: int = 0
var _ui_font_cache: Dictionary = {}      ## path → FontFile（null 表示加载失败，避免重复报错）
var _ui_root_theme: Theme = null         ## 挂在场景树根上的默认主题（提供默认字体）


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
	_ui_font_cache[path] = ff
	return ff


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
## 解析规则见 resolve_ui_font_path；加载失败回退系统字体并醒目报错。
func resolve_and_load_font(path: String) -> Font:
	var resolved := resolve_ui_font_path(path)
	var ff := load_ui_font(resolved)
	return ff if ff else ThemeDB.fallback_font


## 把界面字体套到 Label 上。字号被夹到 UI_FONT_BASE_SIZE 的整数倍（像素字体铁律）。
## 代码创建的提示字（传送点/安全门/拾取点/医疗箱/防守战/事件/Boss/爆破墙）一律走这里。
func apply_ui_font(lbl: Label, size: int = UI_FONT_BASE_SIZE) -> void:
	if lbl == null:
		return
	var font := get_ui_font()
	if font:
		lbl.add_theme_font_override("font", font)
	var s: int = maxi(UI_FONT_BASE_SIZE, int(round(float(size) / float(UI_FONT_BASE_SIZE))) * UI_FONT_BASE_SIZE)
	lbl.add_theme_font_size_override("font_size", s)


## 兼容旧名（2026-09-17 起各玩法节点调用）：等价 apply_ui_font。
func apply_hint_font(lbl: Label, size: int = UI_FONT_BASE_SIZE) -> void:
	apply_ui_font(lbl, size)


## 根 Theme：让**未显式指定字体**的控件（Label/Button/RichTextLabel…）也拿到界面字体。
## 没有它时这些控件走 ThemeDB.fallback_font + 系统字体回退 —— 同一份游戏在不同机器上
## 字形不同，系统缺 CJK 字体时直接豆腐块（scene/network_lobby.tscn 的 13 个 Label、
## map_output.tscn 的 Button 此前都属于这一类）。
## 只设 default_font/default_font_size，其余样式照旧落到 Godot 内置主题。
## 自动化用例专用：抑制受击表现（闪红 Tween + 伤害数字）。
## 【为什么需要它】2026-09-25：给灼烧 DoT 补上权威侧表现后，headless harness 里反复 tick
## 会累积活 Tween，退出时必踩引擎
## BUG: Unreferenced static string to 0: Physics2DConstraintSolveIslands -> 进程挂死。
## 只影响测试进程（游戏内正常运行无此问题）；**默认 false**，任何游戏逻辑都不得依赖它。
var suppress_hit_presentation: bool = false


func ensure_root_ui_theme() -> Theme:
	var tree := get_tree()
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


## 切换界面字体：写盘 + 立刻重套当前场景可见 UI + 广播。
func set_font_option(index: int) -> void:
	var i: int = clampi(index, 0, FONT_OPTION_PATHS.size() - 1)
	if i == font_option:
		return
	font_option = i
	ensure_root_ui_theme()
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		var touched: int = reapply_ui_font_recursive(tree.current_scene)
		print("[Global] 界面字体已重套到当前场景 %d 个 Label" % touched)
	save_config()
	font_changed.emit(get_ui_font_path())
	print("[Global] 界面字体 → %s（%s｜实测缺字 %d/1733，缺处由系统字体顶替）" % [
		font_option_label(), get_ui_font_path().get_file(),
		FONT_OPTION_MISSING_HINT[clampi(font_option, 0, FONT_OPTION_MISSING_HINT.size() - 1)]])


## 启动自检：把「字体能不能用、缺哪些字」直接写进日志。
## 用户反馈的「玩家电脑上缺字」需要一条能对证的线索，而不是让它表现为字形突变。
func _log_font_self_check() -> void:
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


# ═══════════════════════════════════════
# 全队共享数据
# ═══════════════════════════════════════
## gold 为全队共享资源；每名玩家状态由 Players / PlayerState 管理。
var gold: int = 0
# ═══════════════════════════════════════
# 行走动画频率基准（2026-09-15）
# ═══════════════════════════════════════
## 玩家默认步行 150px/s ↔ 每帧 0.18s（= 每帧走 27px）。角色/敌人的移动动画帧时长
## 按当前速度换算：duration = ANIM_BASE_FRAME_DURATION × ANIM_BASE_SPEED / 当前速度
## （速度越快帧间隔越短）。固定常量：改角色速度不影响敌人动画基准。
const ANIM_BASE_SPEED: float = 150.0
const ANIM_BASE_FRAME_DURATION: float = 0.18

# ═══════════════════════════════════════
# 战役 / 难度
# ═══════════════════════════════════════
var selected_campaign: CampaignData = null
var selected_difficulty: int = 0  ## 0=Easy, 1=Normal, 2=Hard, 3=Expert
var difficulty_multipliers: Dictionary = {
	0: {"enemy_hp": 0.7, "enemy_damage": 0.5, "director_intensity": 0.6},
	1: {"enemy_hp": 1.0, "enemy_damage": 1.0, "director_intensity": 1.0},
	2: {"enemy_hp": 1.5, "enemy_damage": 1.5, "director_intensity": 1.5},
	3: {"enemy_hp": 2.0, "enemy_damage": 2.0, "director_intensity": 2.0},
}


## ── 难度倍率的统一查询入口（2026-09-16 用户反馈「不管哪个难度丧尸血量攻击伤害都一样」）──
## 此前这张表里只有 enemy_damage 被消费过一处，而且还是**玩家自己**的灼烧 DoT；
## enemy_hp / director_intensity 全仓零引用 → 难度对敌人完全没生效。
## 现在接线：enemy_hp → 敌人最大生命（enemy._ready）、enemy_damage → 敌人对玩家的攻击伤害
## （EnemyAttackState / EnemyPounceState）、director_intensity → 紧张度（IntensityTracker）。
func difficulty_mult(key: String) -> float:
	var cfg: Variant = difficulty_multipliers.get(selected_difficulty, null)
	if cfg is Dictionary and cfg.has(key):
		return float(cfg[key])
	return 1.0


func difficulty_enemy_hp() -> float:
	return difficulty_mult("enemy_hp")


func difficulty_enemy_damage() -> float:
	return difficulty_mult("enemy_damage")


func difficulty_director_intensity() -> float:
	return difficulty_mult("director_intensity")

# ═══════════════════════════════════════
# 尸体管理
# ═══════════════════════════════════════
var corpse_list: Array = []
@export var max_corpses: int = 20
@export var corpses_to_remove: int = 10

# ═══════════════════════════════════════
# 死亡处理
# ═══════════════════════════════════════
@export var death_music_path: String = "res://sound/残念なお知らせ.ogg"  ## 死亡音乐文件路径（如 "res://music/death.ogg"）
@export var death_fade_duration: float = 8.0  ## 死亡黑屏淡入时长（秒）。总黑屏 = 本值 + death_black_hold，之后才开始重载场景（2026-09-14 用户定稿：总时长目标 ≈15 秒）
@export var death_black_hold: float = 2.0     ## 死亡全黑后等待时长（秒）
@export var death_music_volume_db: float = -10.0  ## 死亡音乐音量（dB, 0 为原始音量）
const CONFIG_FILE: String = "res://config.json"


func _ready() -> void:
	_load_config()
	_ensure_audio_buses()
	_setup_debug_capture()
	# 界面字体：先建根主题（未显式指定字体的控件也拿到像素字体），再打自检日志
	ensure_root_ui_theme()
	_log_font_self_check()


## 现场抓取器（F2 连拍+报告 / F4 只写报告）。挂在 Global 上，所有场景都能用，
## 不落进任何 .tscn，避免污染关卡场景。见 script/debug_capture.gd。
func _setup_debug_capture() -> void:
	if get_node_or_null("DebugCapture") != null:
		return
	var cap: Node = (load("res://script/debug_capture.gd") as GDScript).new()
	cap.name = "DebugCapture"
	add_child(cap)


# ═══════════════════════════════════════
# 内存 Checkpoint（安全屋存档点）
# ═══════════════════════════════════════
var checkpoint: Dictionary = {}  ## 安全屋捕获的快照（仅在内存中，不写磁盘）

# ═══════════════════════════════════════
# 剧情机关 flag（钥匙/炸药/门/墙等流程进度）
# ═══════════════════════════════════════
## 「获得提示 + 全局 flag」路线的存储核心：key=flag 名（如 "ch3_got_key"），
## value=true。刻意**不参与 checkpoint 回滚**——死亡回安全屋不会重置已开门/已炸墙，
## 否则会出现「门开着 flag 却关了」的矛盾存档；进度只随存档文件持久化。
## 联机：Host 权威，由 NetworkWorld 广播（apply_quest_flag）；Client 通过
## request_quest_flag 提交意图。命名约定：加章节前缀（ch3_），换章不自动清。
signal quest_flag_changed(flag_name: String, value: bool)
var quest_flags: Dictionary = {}

## 本机直接写入并广播信号。**只有** NetworkWorld 的同步回包与离线路径应调用；
## 玩法节点请走 request_quest_flag()。
func apply_quest_flag(flag_name: String, value: bool = true) -> void:
	if flag_name.is_empty():
		return
	var changed: bool = quest_flags.get(flag_name, false) != value
	quest_flags[flag_name] = value
	if changed:
		quest_flag_changed.emit(flag_name, value)
		print("[Global] quest_flag[%s] = %s" % [flag_name, str(value)])

func has_quest_flag(flag_name: String) -> bool:
	return quest_flags.get(flag_name, false)

func get_quest_flag(flag_name: String) -> bool:
	return has_quest_flag(flag_name)

## 玩法节点的统一入口：单机/Host 立即生效并广播；联机 Client 转交 Host 复核。
## 在联机 Client 上返回 false（尚未生效，等 Host 回包）。
func request_quest_flag(flag_name: String, value: bool = true) -> bool:
	if flag_name.is_empty():
		return false
	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("is_online_session") and bool(net.is_online_session()):
		var scene := get_tree().current_scene if get_tree() else null
		var world := scene.find_child("NetworkWorld", true, false) if scene else null
		if world and world.has_method("submit_quest_flag"):
			world.call("submit_quest_flag", flag_name, value)
			return false
		printerr("[Global] 联机中找不到 NetworkWorld，flag[%s] 未提交" % flag_name)
		return false
	apply_quest_flag(flag_name, value)
	return true

## 全队投掷物槽里是否还有「能炸墙的爆炸物」（explosion_radius>0 且叠数>0）。
## 供保底补给点的激活条件使用。
func team_has_explosive_throwable() -> bool:
	for s: PlayerState in Players.seats:
		if s and s.throwable and s.throwable.explosion_radius > 0 and s.throwable_count > 0:
			return true
	return false


## 队伍是否携带**能炸开可爆破墙**的投掷物（炸药）。2026-09-16 用户定稿：墙体只认炸药，
## 手雷/火箭筒/榴弹一律炸不开 —— 与上面「有爆炸物」（含手雷）的语义区分开，
## 供 blast_wall 提示文案用（否则"有手雷"会误报"能炸开"）。
func team_has_wall_breaker() -> bool:
	for s: PlayerState in Players.seats:
		if s and s.throwable and s.throwable.breaks_blast_wall and s.throwable_count > 0:
			return true
	return false


# 仅单机使用的一次性跨场景入口信息；联机由 Net 在场景转换握手中同步。
var _pending_arrival_scene: String = ""
var _pending_arrival_id: String = ""
var _pending_arrival_position: Variant = null

func set_pending_arrival(scene_path: String, arrival_id: String, arrival_position: Variant = null) -> void:
	_pending_arrival_scene = scene_path
	_pending_arrival_id = arrival_id.strip_edges()
	_pending_arrival_position = arrival_position if arrival_position is Vector2 else null


func consume_pending_arrival(scene_path: String) -> Dictionary:
	if _pending_arrival_scene != scene_path:
		if not _pending_arrival_scene.is_empty():
			push_warning("[Global] 丢弃失配的待到达入口: expected=%s actual=%s" % [_pending_arrival_scene, scene_path])
		_pending_arrival_scene = ""
		_pending_arrival_id = ""
		_pending_arrival_position = null
		return {}
	var arrival := {
		"id": _pending_arrival_id,
		"position": _pending_arrival_position,
	}
	_pending_arrival_scene = ""
	_pending_arrival_id = ""
	_pending_arrival_position = null
	return arrival


## 在安全屋捕获 checkpoint —— 深拷贝当前状态为快照
func capture_checkpoint() -> void:
	var scene_path: String = ""
	if get_tree() and get_tree().current_scene:
		scene_path = get_tree().current_scene.scene_file_path

	var seat_clones: Array[PlayerState] = []
	for s: PlayerState in Players.seats:
		seat_clones.append(s.clone())

	checkpoint = {
		"scene_path": scene_path,
		"seats": seat_clones,
		"active_seat_index": Players.active_seat_index,
		"team_spray_count": Players.team_spray_count,
		"gold": gold,
		"selected_campaign": selected_campaign,
		"selected_difficulty": selected_difficulty,
	}
	print("[Checkpoint] 已捕获: 场景=%s 座位=%d %s" % [
		scene_path, seat_clones.size(), Players.get_active_state().describe(),
	])

## 返回 checkpoint 中的安全屋场景路径（用于死亡后切回安全屋）
func get_checkpoint_scene() -> String:
	return checkpoint.get("scene_path", "")

## 从内存 checkpoint 恢复游戏状态（死亡时调用）
func restore_checkpoint() -> void:
	if checkpoint.is_empty():
		print("[Checkpoint] 无 checkpoint，保持当前状态")
		return
	var seat_clones: Array = checkpoint.get("seats", [])
	if not seat_clones.is_empty():
		Players.clear_seats()
		for s: PlayerState in seat_clones:
			Players.add_seat(s.clone())
		Players.seats_authored = true
		Players.active_seat_index = clampi(
			checkpoint.get("active_seat_index", 0), 0, Players.seat_count() - 1
		)
	gold = checkpoint.get("gold", 0)
	Players.team_spray_count = int(checkpoint.get("team_spray_count", Players.team_spray_count))
	selected_campaign = checkpoint.get("selected_campaign")
	selected_difficulty = checkpoint.get("selected_difficulty", 0)
	print("[Checkpoint] 已恢复: 座位=%d %s" % [
		Players.seat_count(), Players.get_active_state().describe(),
	])

# ═══════════════════════════════════════
# 队伍管理 —— 已迁至 Players（script/player_registry.gd）
# ═══════════════════════════════════════

## 过渡期 shim：队伍规模。新代码请直接用 Players.seat_count()。
func get_team_size() -> int:
	return Players.seat_count()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("调试可视化键"):
		debug_visuals = not debug_visuals
		print("[Global] 调试可视化: %s" % ("开启" if debug_visuals else "关闭"))
		# 切换导航网格可视化
		ProjectSettings.set_setting("debug/navigation/enable_edge_lines", debug_visuals)
		ProjectSettings.set_setting("debug/navigation/enable_geometry_face_random_color", debug_visuals)
		var tree: SceneTree = get_tree()
		if tree:
			var root: Window = tree.root
			if root:
				_trigger_redraw_recursive(root)


func _trigger_redraw_recursive(node: Node) -> void:
	if node is CanvasItem:
		(node as CanvasItem).queue_redraw()
	for child: Node in node.get_children():
		_trigger_redraw_recursive(child)


func _load_config() -> void:
	if FileAccess.file_exists(CONFIG_FILE):
		var f: FileAccess = FileAccess.open(CONFIG_FILE, FileAccess.READ)
		if f:
			var text: String = f.get_as_text()
			f.close()
			var cfg: Dictionary = JSON.parse_string(text) if text else {}
			if cfg:
				debug_enabled = cfg.get("debug", false)
				music_volume = cfg.get("music_volume", 80)
				sfx_volume = cfg.get("sfx_volume", 80)
				facing_lock_mode = cfg.get("facing_lock_mode", 0)
				font_option = clampi(int(cfg.get("font_option", 0)), 0, FONT_OPTION_PATHS.size() - 1)


func save_config() -> void:
	var cfg: Dictionary = {
		"debug": debug_enabled,
		"music_volume": music_volume,
		"sfx_volume": sfx_volume,
		"facing_lock_mode": facing_lock_mode,
		"font_option": font_option
	}
	var f: FileAccess = FileAccess.open(CONFIG_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(cfg, "\t"))
		f.close()


# ═══════════════════════════════════════
# 音频总管理
# ═══════════════════════════════════════

@export var max_sfx_concurrency: int = 2  ## 同一音效最大同时播放数（防止音量叠加；2026-09-13 用户要求 4→2）

@export_group("UI 窗口音效")
## 各界面窗口通用的光标（选择）/确定/取消音效（2026-09-15）。
## 各界面脚本可用自己的 sfx_cursor/sfx_confirm/sfx_cancel_path 导出覆盖（留空=用这里的全局值）。
@export_file("*.wav", "*.ogg", "*.mp3") var ui_cursor_sfx_path: String = "res://sound/カーソル1.ogg"
@export_file("*.wav", "*.ogg", "*.mp3") var ui_confirm_sfx_path: String = "res://sound/決定1.ogg"
@export_file("*.wav", "*.ogg", "*.mp3") var ui_cancel_sfx_path: String = "res://sound/キャンセル1.ogg"

@export_group("拾取音效")
## 拾取掉落物（武器/物品/重要物品）的全局默认音效（2026-09-15 用户定稿 bio1_アイテム入手２）。
## 数据资源（ItemData.pickup_sound）与拾取点（ItemPickupPoint.pickup_sound）留空时回退到这里。
@export_file("*.wav", "*.ogg", "*.mp3") var default_pickup_sfx_path: String = "res://sound/bio1_アイテム入手２.ogg"

## 播放拾取音效：override 非空用之，否则用全局默认；pitch <=0 视为原调。
## 播放器挂当前场景（非定位）——拾取物节点随即释放，不能挂；拾取都发生在玩家身边，
## 与 UI 音同等的非定位处理（沿用 ItemPickupPoint 既有行为）。
func play_pickup_sfx(override: AudioStream = null, pitch: float = 1.0) -> void:
	var stream := override
	if stream == null:
		if default_pickup_sfx_path.is_empty():
			return
		stream = load(default_pickup_sfx_path) as AudioStream
	if stream == null:
		return
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		scene = self
	play_sfx_managed(stream, scene, false, maxf(pitch, 0.01))

## 同一音效资源的活跃播放器计数（resource_path → Array[AudioStreamPlayer]）
var _active_sfx: Dictionary = {}

## 播放音效（带并发限制，防止同音效多实例叠加导致音量过大）。
## 超过 max_sfx_concurrency 的新请求会被丢弃。
## positional=true 且 parent 是 Node2D 时用 AudioStreamPlayer2D —— 音量随距离衰减、
## 带声像（丧尸叫等世界内音效必须走这个，否则屏外的僵尸和贴脸的一样响）。
func play_sfx_managed(stream: AudioStream, parent: Node, positional: bool = false, pitch: float = 1.0) -> void:
	if not stream:
		return

	var key := stream.resource_path
	if key.is_empty():
		key = "inline_%d" % stream.get_instance_id()

	# 清理已完成/已释放的播放器
	var arr: Array = _active_sfx.get(key, [])
	var i: int = arr.size() - 1
	while i >= 0:
		# AudioStreamPlayer 与 AudioStreamPlayer2D 不是同一继承链，用鸭子读取 playing
		if not is_instance_valid(arr[i]) or not arr[i].playing:
			arr.remove_at(i)
		i -= 1

	if arr.size() >= max_sfx_concurrency:
		# 声音窃取（voice stealing）：停掉最旧的，让新触发的音效必有声。
		# 旧实现「丢弃新的」会让连发武器的枪声每隔几发漏一声（枪口火光有、声音没有，
		# 用户 2026-09-13 回归：发射音效跟全局不同步）。总并发仍被上限封顶。
		var oldest: Node = arr[0]
		if is_instance_valid(oldest):
			oldest.stop()
			oldest.queue_free()
		arr.remove_at(0)

	var player: Node = null
	if positional and parent is Node2D:
		var p2d := AudioStreamPlayer2D.new()
		# 可视世界半径 ≈ 分辨率/2（zoom=2x）≈ 640×480；衰减到屏外一圈即无声
		p2d.max_distance = 1100.0
		player = p2d
	else:
		player = AudioStreamPlayer.new()
	player.stream = stream
	player.bus = "SFX"
	player.autoplay = true
	player.pitch_scale = pitch  ## 每音效音调（2026-09-15：敌人各音效可独立设调）
	var cb: Callable = func():
		arr.erase(player)
		player.queue_free()
	player.finished.connect(cb)
	parent.add_child(player)
	arr.append(player)
	_active_sfx[key] = arr


## 播放界面窗口音效（2026-09-15）。kind = "cursor" | "confirm" | "cancel"；
## override_path 非空时优先（各界面自己的 sfx_*_path 导出），否则用全局 ui_*_sfx_path。
## 播放器挂在 Global 下——确认音后立刻切场景也不会被掐断。
func play_ui_sfx(kind: String, override_path: String = "") -> void:
	var path := override_path
	if path.is_empty():
		match kind:
			"cursor":
				path = ui_cursor_sfx_path
			"confirm":
				path = ui_confirm_sfx_path
			"cancel":
				path = ui_cancel_sfx_path
			_:
				return
	if path.is_empty():
		return
	var stream: AudioStream = load(path) as AudioStream
	if stream == null:
		push_warning("[Global] UI 音效加载失败: %s" % path)
		return
	play_sfx_managed(stream, self)


func _ensure_audio_buses() -> void:
	var bc: int = AudioServer.bus_count
	if bc < 2:
		AudioServer.add_bus(1)
	if bc < 3:
		AudioServer.add_bus(2)
	AudioServer.set_bus_name(1, "SFX")
	AudioServer.set_bus_name(2, "Music")
	_apply_volume()
	print("[Global] 音频总线已创建: Master, SFX, Music")


func _apply_volume() -> void:
	var sfx_idx: int = AudioServer.get_bus_index("SFX")
	var music_idx: int = AudioServer.get_bus_index("Music")
	if sfx_idx >= 0:
		AudioServer.set_bus_volume_db(sfx_idx, linear_to_db(sfx_volume / 100.0))
	if music_idx >= 0:
		AudioServer.set_bus_volume_db(music_idx, linear_to_db(music_volume / 100.0))


func set_music_volume(pct: int) -> void:
	music_volume = clampi(pct, 0, 100)
	_apply_volume()
	save_config()


func set_sfx_volume(pct: int) -> void:
	sfx_volume = clampi(pct, 0, 100)
	_apply_volume()
	save_config()


func set_facing_lock_mode(mode: int) -> void:
	facing_lock_mode = clampi(mode, 0, 1)
	save_config()


# ═══════════════════════════════════════
# 大厅音乐（2026-09-13 用户需求）
# ═══════════════════════════════════════
## 选角色 / 选战役 / 选难度三个界面共用一首 BGM：播放器挂在 autoload 上，
## 切界面不释放 → 音乐连续不断；难度确认（正式开局）时 stop。
const LOBBY_MUSIC_PATH: String = "res://music/l3d_lobby.mp3"
var _lobby_music_player: AudioStreamPlayer = null

## 播放大厅音乐。幂等：已在播同曲时直接返回（切界面不会重头播）。
func play_lobby_music() -> void:
	if _lobby_music_player and is_instance_valid(_lobby_music_player) and _lobby_music_player.playing:
		return
	if _lobby_music_player == null or not is_instance_valid(_lobby_music_player):
		_lobby_music_player = AudioStreamPlayer.new()
		_lobby_music_player.name = "LobbyMusicPlayer"
		_lobby_music_player.bus = "Music"
		add_child(_lobby_music_player)
	if not ResourceLoader.exists(LOBBY_MUSIC_PATH):
		return
	_lobby_music_player.stream = load(LOBBY_MUSIC_PATH)
	_lobby_music_player.play()


## 停止大厅音乐（难度确认 / 回标题等正式离开大厅时调用）。
func stop_lobby_music() -> void:
	if _lobby_music_player and is_instance_valid(_lobby_music_player):
		_lobby_music_player.stop()


# ═══════════════════════════════════════
# 尸体管理
# ═══════════════════════════════════════

func register_corpse(corpse: Node2D) -> void:
	corpse_list.append(corpse)
	print("[Global] 尸体注册: 当前 %d 具（上限 %d）" % [corpse_list.size(), max_corpses])
	if corpse_list.size() > max_corpses:
		_cleanup_corpses()


## 尸体淡出结束后的摘除（2026-09-16：尸体改为「3 秒生命周期」，见 enemy._start_corpse_lifecycle）。
## 不摘除也不会出错（_cleanup_corpses 会剔除失效引用），但会让列表堆积无效项、虚增计数。
func unregister_corpse(corpse: Node2D) -> void:
	corpse_list.erase(corpse)


func _cleanup_corpses() -> void:
	var valid_corpses: Array = []
	for corpse: Variant in corpse_list:
		if corpse == null:
			continue
		if not is_instance_valid(corpse):
			continue
		if corpse is Node2D:
			valid_corpses.append(corpse)
		else:
			continue

	var overflow: int = maxi(0, valid_corpses.size() - max_corpses)
	if overflow <= 0:
		corpse_list = valid_corpses
		return

	var remove_count: int = mini(corpses_to_remove, overflow)
	print("[Global] 尸体超限！移除最旧 %d 具..." % remove_count)
	for i: int in range(remove_count):
		var corpse: Node2D = valid_corpses[i] as Node2D
		if corpse and is_instance_valid(corpse):
			corpse.queue_free()
	valid_corpses = valid_corpses.slice(remove_count)
	corpse_list = valid_corpses


# ═══════════════════════════════════════
# 游戏初始化
# ═══════════════════════════════════════

func init_new_game() -> void:
	# 座位表为空时 Players.get_active_state() 会懒创建座位 0（のび太，单角色回退模式），
	# 所以旧实现那条独立的「回退分支」不再需要 —— 两条初始化路径已统一。
	Players.get_active_state()
	Players.active_seat_index = 0
	# 新游戏不得继承上一局的 checkpoint（否则死亡重载会回到上一局的安全屋）
	checkpoint.clear()
	gold = 0
	corpse_list.clear()
	quest_flags.clear()
	# 战役累计统计（终章 ED 排名用）同步清零
	var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
	if chapter_stats and chapter_stats.has_method("reset_campaign"):
		chapter_stats.reset_campaign()
	print("[Global] 新游戏初始化完成 座位=%d %s" % [
		Players.seat_count(), Players.get_active_state().describe(),
	])


func try_load_or_init() -> void:
	# checkpoint 的恢复**只**由死亡重载路径（player._reload_from_save）显式调用，
	# 这里不再代劳 —— 否则每次进安全屋都会把队伍回滚到上一个 capture 点：
	# 座位/操控角色/HP/装备全部退回，用户表现为「进安全屋后我选的角色变了」（2026-09-13 回归）。
	# 座位表不是「菜单/存档/checkpoint 填出来的」才初始化新游戏；
	# 否则保留当前内存状态（从菜单流程过来 / 死亡重载但从未进入过安全屋）。
	# 用 seats_authored 而不是 seat_count()==0 判断 —— 因为任何一次对 Global
	# per-player shim 属性的读取都会触发座位懒创建，seat_count() 不可靠。
	if not Players.seats_authored:
		init_new_game()
	else:
		print("[Global] try_load_or_init: 保留当前状态 | 座位=%d %s" % [
			Players.seat_count(), Players.get_active_state().describe(),
		])
