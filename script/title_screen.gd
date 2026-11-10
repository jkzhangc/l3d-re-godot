extends Control

## ── 架构定位 ──
## 系统：标题画面 ｜ 层：表现（Control）
## 联机：不涉及
## 职责：RM2K3 风格标题画面：窗口绘制、光标动画、渐变文字与单机/联机入口分流。
## 依赖：GradientLabel、Global 文字默认值

## 标题画面控制器 — RM2K3 风格窗口
##
## 文字颜色：GradientLabel 从色表取固定色（上亮下暗的渐变已移除）。
## 支持阴影（暗色偏移）和粗体（1px 偏移叠加）。
##
## 操作：
##   上/下   → 移动光标
##   确定键  → 确认


## ★2026-10-23 子菜单改版（用户定）：顶层只保留游戏入口，说明/成就/设置/日志/退出
## 收进「其他」二级页 —— 原本 7 项平铺再塞「收藏馆」会顶破窗口。
## ★2026-10-03 新增「继续游戏」（置顶）：读取手动存档点的存档。
## ⚠ 窗口高度不再手工同步：`_window_size_for()` 按项数推导（见 _ready），
##   加项不会再出现「最后一项被挤进滚动区」。
const MENU_ITEMS: Array[String] = [
	"继续游戏", "开始游戏", "联机游戏", "收藏馆", "其他",
]
## 「其他」二级菜单（6 项，含返回）。
const OTHER_ITEMS: Array[String] = [
	"操作说明", "成就", "设置", "竞速记录", "游玩统计", "更新日志", "退出游戏", "返回",
]
const WINDOW_TITLE: String = "のび太的求生之路"

# ═══════════════════════════════════════
# 布局参数
# ═══════════════════════════════════════

@export_group("窗口布局")
## 2026-09-14：5 个菜单项 + RM 窗口样式（角色选择/选择战役同款 WindowBg+WindowFrame）
@export var window_size: Vector2 = Vector2(300, 320)
@export var window_y_offset: float = 130.0
@export var show_title: bool = false
@export var title_position: Vector2 = Vector2(28, 16)
@export var separator_y: float = 60.0
@export var panel_margin: float = 6.0

@export_group("选项布局")
@export var title_font_size: int = 32
@export var item_font_size: int = 32
@export var item_start_y: float = 32.0
@export var item_height: float = 44.0
@export var item_spacing: float = 12.0
@export var item_margin_bottom: float = 0.0
@export var item_title_gap: float = 12.0
@export var item_text_x: float = 6.0
@export var item_width: float = 0.0
@export var item_centered: bool = false

@export_group("文字颜色")
@export var text_color_index: int = 1:
	set(v):
		text_color_index = clampi(v, 0, 19)
@export var text_color_row: int = 0:
	set(v):
		text_color_row = clampi(v, 0, 3)
@export var text_title_color_index: int = 1:
	set(v):
		text_title_color_index = clampi(v, 0, 19)

@export_group("文字效果")
@export var text_bold: bool = true
@export var text_outline: bool = false
@export var text_outline_color: Color = Color.BLACK
@export var text_shadow: bool = true
@export var text_shadow_color: Color = Color(0, 0, 0, 1)
@export var text_shadow_offset: Vector2 = Vector2(2, 2)

@export_group("光标框")
@export var cursor_base_height: float = 48.0
@export var cursor_scale_y: float = 1.0:
	set(v):
		cursor_scale_y = maxf(0.5, snapped(v, 0.5))
@export var cursor_snap_to_item: bool = false
## 选择框默认宽度 = 窗口宽度 - 左右内间距（2026-09-14 用户定稿）；
## cursor_override_width > 0 时仍可强制指定固定宽。
@export var cursor_window_padding: float = 12.0
@export var cursor_offset_y: float = -4.0
@export var cursor_min_width: float = 96.0
@export var cursor_override_width: float = 0.0

@export_group("资源路径")
## 留空 = 跟随「设置 → 界面字体」（2026-09-24）。旧默认 DotGothic16 是纯日文字体，
## 实测缺字 506/1733；填具体路径 = 本窗口固定用该字体（不随开关变化）。
@export var font_path: String = ""
@export var bg_pattern_path: String = "res://art/System/Background pattern for menu screens (16 x 16).png"
@export var cursor_frame_path: String = "res://art/System/Frames for command cursor 2 types (each 32 x 32).png"
@export var arrow_down_path: String = "res://art/System/arrow_down.png"
@export var arrow_up_path: String = "res://art/System/arrow_up.png"
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
## RM 窗口样式已节点化（2026-09-15）：WindowBg/WindowFrame/CursorFrame 预置在
## title_screen.tscn 里，编辑器 Inspector 可直接换贴图；脚本按 window_size 同步尺寸。
@export var campaign_select_scene: String = "res://scene/campaign_select.tscn"
@export var controls_guide_scene: String = "res://scene/controls_guide.tscn"

@export_group("界面音效")
## 留空 = 用 Global 的 ui_*_sfx_path。标题画面默认用专属的タイトルカーソル/タイトルキャンセル。
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cursor_path: String = "res://sound/タイトルカーソル.WAV"
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_confirm_path: String = ""
@export_file("*.wav", "*.ogg", "*.mp3") var sfx_cancel_path: String = "res://sound/タイトルキャンセル.WAV"


var _cursor_idx: int = 0
var _scroll_offset: int = 0
var _visible_items: int = 0

## ── 「其他」二级菜单（2026-10-23）──
## 两级菜单共用同一批 GradientLabel 节点与光标框：进入二级页时只换「当前项列表」
## 与窗口高度，退出时恢复。两个光标各自记住位置，来回切不会丢选择。
var _in_other_menu: bool = false
var _other_cursor_idx: int = 0
var _main_cursor_idx: int = 0

var _scroll_arrow_down: TextureRect = null
var _scroll_arrow_up: TextureRect = null
var _title_gradient_label: GradientLabel = null

var _cursor_atlas: Array[AtlasTexture] = []
var _cursor_frame_idx: int = 0

var _color_img: Image = null

## 设置面板状态
var _in_settings: bool = false
var _settings_cursor_idx: int = 0
var _settings_labels: Array[GradientLabel] = []
var _settings_value_labels: Array[GradientLabel] = []
var _settings_bar_bg: Array[ColorRect] = []
var _settings_bar_fill: Array[ColorRect] = []
## 设置项（2026-09-30：移动端多一项「按键布局」—— 手机端可自由拖动按键/摇杆位置）。
## ⚠ 用函数而非 const（项数随平台变）。「按键布局」**插在「返回」之前**，
##   所以 0~4（音量 / 固定朝向 / 文字居中 / 界面字体）的序号在所有平台上都不变。
func _settings_items() -> Array[String]:
	var out: Array[String] = ["音乐音量", "音效音量", "固定朝向", "文字居中", "界面字体", "拾取方式",
		"灯光闪烁", "人物影子", "遮挡阴影", "影子质量", "血液颜色", "血液特效"]
	if Global.is_mobile_platform():
		out.append("按键布局")
	out.append("返回")
	return out
## 菜单窗口与画布上下边的最小留白（像素）。窗口太高时按它夹紧纵向位置，见 `_create_menu_window`。
const WINDOW_TOP_MARGIN: float = 8.0
const WINDOW_BOTTOM_MARGIN: float = 8.0
## 设置页窗口尺寸（2026-09-14）：音量条/数值标签比菜单项宽，进设置时窗口加宽、退出还原
const SETTINGS_WINDOW_SIZE: Vector2 = Vector2(520, 336)


## 设置窗实际尺寸：**按项数推导高度**（2026-10-26 加「拾取方式」后桌面也是 7 行）。
## `_settings_row_step()` 会把行距压到 `avail / 行数`，行数多了会压到和 32px 字号 + 光标框打架，
## 所以每多一行给 48px；6 行及以下沿用旧高度 336。
func _settings_window_size() -> Vector2:
	var rows: int = _settings_items().size()
	if rows <= 6:
		return Vector2(520.0, 336.0)
	return Vector2(520.0, 392.0 + float(rows - 7) * 48.0)
## 音量条宽度——背景条与填充条必须同宽（旧版填充刷新写死 80、背景 160，
## 填充永远只有背景一半长，2026-09-15 用户截图复现）
const SETTINGS_BAR_W: float = 160.0
## 场景里作者的原始窗口尺寸（宽度基准）。设置页会临时改 `window_size`，退出要用它还原。
var _base_window_size: Vector2 = Vector2.ZERO

## 场景节点引用（2026-09-15 节点化）：窗口底图/九宫格框/光标框预置在 title_screen.tscn
@onready var _window_bg: TextureRect = $MenuWindow/WindowBg
@onready var _window_frame: NinePatchRect = $MenuWindow/WindowFrame
@onready var _cursor_frame: NinePatchRect = $MenuWindow/CursorFrame
## 菜单项节点化（2026-09-15）：Item0..Item4 预置在 title_screen.tscn，GradientLabel
## 是 @tool —— 编辑器里直接可见可调字体/字号/位置；运行时复用这些节点，不再删建。
@onready var _menu_item_labels: Array = [
	$MenuWindow/Item0, $MenuWindow/Item1, $MenuWindow/Item2, $MenuWindow/Item3, $MenuWindow/Item4,
]


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════

## 当前菜单项列表（顶层 / 「其他」二级页）。
func _active_items() -> Array[String]:
	return OTHER_ITEMS if _in_other_menu else MENU_ITEMS


## 按项数推导窗口高度（2026-10-23）。
## 之前窗口高度写在场景里、每加一项都要手改，注释里已经记过一次「7 项顶破窗口」；
## 改成按项数算之后，加项/改行距都不会再漏。
## 宽度取**场景原始宽度**（`_base_window_size`），不能读运行中的 `window_size.x` ——
## 设置页会把窗口临时加宽到 520，退出时若拿它当基准，主菜单就永久变宽了。
func _window_size_for(items: Array[String]) -> Vector2:
	var base_w: float = _base_window_size.x if _base_window_size.x > 0.0 else window_size.x
	var rows_h: float = float(items.size()) * item_height \
			+ maxf(0.0, float(items.size() - 1)) * item_spacing
	return Vector2(base_w, item_start_y + rows_h + 24.0)


func _ready() -> void:
	## 窗口高度按当前项数推导（主菜单 5 项 / 「其他」6 项各自不同）。
	_base_window_size = window_size
	window_size = _window_size_for(MENU_ITEMS)
	## 成就入口（2026-10-02）：菜单项比场景里预置的 Item 节点多一个 →
	## 在这里**复制**最后一个预置节点补足（不手写 tscn：GradientLabel 是 @tool，
	## 节点化时字体/字号/位置都调好了，复制即可继承）。
	_ensure_menu_item_nodes()
	# 仅供双进程联机烟测使用：从默认标题场景直接进入联机大厅，
	# 正常启动和玩家手动进入“联机游戏”菜单的流程不受影响。
	var user_args := OS.get_cmdline_user_args()
	if "--net-test=host" in user_args or "--net-test=client" in user_args:
		print("[标题画面] 检测到联机自动测试参数，跳转到联机大厅")
		call_deferred("_go_to_network_lobby")
		return

	_load_defaults_from_global()
	var color_texture := ResourceLoader.load(color_sheet_path) as Texture2D
	_color_img = color_texture.get_image() if color_texture else null
	if _color_img:
		print("[标题画面] 色表已加载 %d×%d" % [_color_img.get_width(), _color_img.get_height()])
	else:
		printerr("[标题画面] 色表加载失败: %s" % color_sheet_path)
	# 将背景音乐路由到 Music 总线
	var bgm: AudioStreamPlayer = get_node_or_null("AudioStreamPlayer")
	if bgm:
		bgm.bus = "Music"
	_create_cursor_frames()
	if _cursor_frame and not _cursor_atlas.is_empty():
		_cursor_frame.texture = _cursor_atlas[0]
	_create_menu_window()
	_refresh_all()
	## 字体切换后重排本窗口（2026-09-24）：字号宽度随字体变，居中/量宽要重算。
	if Global.has_signal("font_changed") and not Global.font_changed.is_connected(_on_global_font_changed):
		Global.font_changed.connect(_on_global_font_changed)
	_start_cursor_blink()
	_build_footer_info()
	_build_update_log_icon()
	_maybe_show_update_log_on_first_launch()


## 首次启动 / 换版本时自动打开更新日志（2026-09-29 用户需求）。
## 【为什么需要】手机上只有虚拟按钮、没有 F1 键，新玩家根本不知道更新了什么。
## 用 `Global.changelog_seen_version` 记录「已看过的版本」：为空（首次启动）或与当前
## 版本不符（更新后第一次进）时自动弹一次并立即记下；之后按 F1 仍可随时打开。
func _maybe_show_update_log_on_first_launch() -> void:
	if CHANGELOG_VERSION_TEXT.is_empty():
		return
	if Global.changelog_seen_version == CHANGELOG_VERSION_TEXT:
		return
	Global.changelog_seen_version = CHANGELOG_VERSION_TEXT
	Global.save_config()
	## 本帧窗口还在 _ready 里搭，延后一帧再开面板（面板也依赖本帧建好的字体主题）。
	call_deferred("_open_update_log")


## ── F1 更新日志（2026-09-17 用户需求）──
## 右上角「F1 更新日志」角标 + RM 窗口样式的更新日志面板（F1/Esc/确定键关闭）。

const CHANGELOG_VERSION_TEXT := "v0.45（2026-11-09）"
## 更新日志正文字号（12 整数倍铁律）。★折行量宽与建行必须用同一个值（`_wrap_text_to_width`）。
const CHANGELOG_FONT_SIZE: int = 24

## ⚠ CHANGELOG_VERSION_TEXT 是「本版已看过」的判据（`Global.changelog_seen_version`）：
## 改了它 → 玩家下次启动会**自动弹一次**更新日志。所以每次发版必须换新字符串。
const CHANGELOG_BODY := """【v0.45 · 新增】
· 新角色「安雄」可以选了 —— 原作说明书里的爆破手：手枪 / 冲锋枪 / 步枪 /
  霰弹枪 / 榴弹发射器 / 火箭筒 / 四联火箭 / 地对空导弹 / 十字弩 / 空手；
  没画过持枪动作的武器他拿不了（走过去不会出按键提示），安全屋里也有他自己的台词
· 安雄的两个专属能力：
  · 安雄魂 —— 举着枪按觉醒键（耗 TP10），5 秒内**每一次**受到的伤害都变成 1；
    生效中再按一次就续 5 秒（可叠，状态栏显示倒计时与 ×层数），换人也不会消失；
    发动时有他的喊声和一瞬金光
  · 自爆无效体质 —— 自己打出的榴弹 / 火箭爆炸不会伤到自己（零距离爆破）
· 血条右边会列出你身上的状态（安雄魂 / 镇痛剂 / 肾上腺素 / 燃烧 / 过热 …），
  带剩余时间和叠加层数；正负面用颜色区分。状态名统一成中文了
  （以前 Heat / 鎮痛剤 / アドレナリン 混着英文日文）
· 收藏馆多了「角色」「状态」两页：
  · 角色页 —— 每个人的定位、简介、HP / 攻击 / 防御、见切反击、能装备哪些武器、
    被动特性和技能，不用开一局也能查
  · 状态页 —— 安雄魂 / 觉醒 / 镇痛剂 / 肾上腺素 / 燃烧 / 过热 / 武器损耗 / 毅力，
    每条都写了效果、怎么获得、以及要不要占状态栏
· 安雄在选人界面补上了技能介绍（安雄魂），觉醒那行也说明「觉醒键改发安雄魂」，
  不再是一个空的「——」
· 「过热」期间不能换人是原作设定（说明书写着「キャラチェンジ不可」），
  不是按键坏了 —— 状态栏会直接标成「过热·禁换人」，操作提示也会写明原因
· 「开始游戏」前多了一步「游戏模式」：
  · 标准模式 —— 原来的玩法，没有计时压力
  · 计时竞速 —— 屏幕中下方常驻计时器，整局一直在走；每局结束（通关或中途放弃）
    都会留下记录：用时、死亡次数、击杀数
· 标题「其他」里多了两份报表：
  · 竞速记录 —— 每个战役的最佳成绩，以及最近 10 局的明细
  · 游玩统计 —— 总游玩时长、局数、通关率、击杀 / 爆头 / 死亡、造成与承受伤害
· 给想直播的玩家加了两个开关（设置页最下面）：
  · 血液颜色 —— 红 / 绿 / 紫 / 灰，默认红；只改「喷血」这类血效，
    枪口火光、爆炸、酸液都不受影响
  · 血液特效 —— 直接关掉喷血动画
· SA 技能和觉醒发动都有音效了（以前按下去只有画面变化，没有声音）

【v0.45 · 修复】
· 联机时近战打中敌人没有「打中」的音效 —— 已补上（和单机一致）
· 命中音再调大了一档（普通枪械那记默认命中音改成原调之后，这次整体再抬一点）

【v0.44 · 新增】
· 推击有了起手声；真把敌人推出去时另有一记打击音，挥空只响起手那一声
· 推击动作改成三段各自计时：抬手 → 推出 → 收势，出手时机和收招速度不再一刀切
· 远程武器打中敌人有命中打击音了（以前普通枪械打中是静音的）；
  火 / 雷 / 冰 / 酸 武器仍然用自己的属性命中音，不会被盖掉

【v0.44 · 修复】
· 举着枪 / 刀站在手雷、燃烧瓶上按 D 换不了手里的投掷物 —— 已修
  （以前必须先放下武器才能换）
· 冲锋枪 / 步枪 / 轻机枪的枪声比别的枪响一大截，会把命中音、僵尸叫、脚步盖掉
  —— 已压到和手枪同一档；霰弹枪也顺手压低了一点
· 打中敌人的「命中音」偏小、经常被枪声盖住 —— 已整体调大一档；
  普通枪械那记默认命中音还改回了原调（以前是升调的，听着偏尖）
· 狂暴丧尸变回普通形态后，有一部分走路不再踏步、整张图平移 —— 已修
· 狂暴丧尸力竭时，趴下的姿势只闪一下就又站起来 —— 现在会稳稳趴满 1 秒再起身
· 联机时主机与客户端都看不到近战攻击的「武器动作图」—— 拿刀 / 球棒 / 斧头
  挥击时，本该单独画出来的那把武器一直不出现；现在与单机一致
· 联机时角色倒地 / 阵亡没有倒下音效 —— 已补上
· 联机时使用急救喷雾、鎮痛剤、アドレナリン 没有使用音效，屏幕也不闪 —— 已修好
· 联机时捡起武器 / 投掷物 / 急救喷雾没有拾取音 —— 已补上
· 联机时队友开枪打中敌人的命中音，在没配命中特效的武器上完全听不到 —— 已修

【v0.43 · 新增】
· 设置里新增四项灯光 / 画面选项：灯光闪烁（动态 / 静态）、人物影子、遮挡阴影、
  影子质量（低 / 中 / 高）。手机一开灯就卡的话，把「人物影子」「遮挡阴影」关掉、
  把影子质量调到低，会明显顺很多；想让画面更稳也可以把灯光设成「静态」
· 狂暴丧尸跑一阵（约 10 秒）会力竭趴下 1 秒，然后变回普通丧尸接着追；
  以前围殴时它永远不会累（只算"真在跑"的时间），现在站着打也算消耗

【v0.43 · 修复】
· 弹药数字、右下角按键提示、存档成功的提示等文字，有时会变成别的字
  （数字变字母、中文变成别的字，还时好时坏）—— 已修好
· 小夫 / 静香捡起 M202 四联火箭、便携式地对空导弹后会整个变成大雄；
  现在谁没画过这把武器的持枪动作，就谁也拿不了它（走过去不会出按键提示）
· 火箭筒打空弹夹后，人物会跳成别的图形（图标 / 倒地姿势）—— 已换成正常的空仓站姿
· 死亡队友倒下时人还站着；最后一个角色阵亡时放的是上一个角色的音效 —— 已修
· 进联机战斗后大厅背景音乐还在响 —— 已修
· 贴着墙换枪时旧枪会掉到墙的另一侧 —— 现在只会掉在自己脚下附近
· 联机里替换武器会换错格子（举着第 1 格却换掉第 2 格）—— 已和单机统一
· 联机投掷瞄准时不能调距离、不能原地转身 —— 已和单机一致
· 玩家昵称、联机大厅的提示文字字号不规整、字发虚 —— 已调清晰
· 标题画面设置项变多后，最后一行「返回」被挤出屏幕外 —— 已修
"""


var _update_log_icon: GradientLabel = null
var _update_log_panel: Control = null
var _log_content: VBoxContainer = null
var _log_clip_height: float = 0.0
var _scroll_log_y: float = 0.0


## 左下角版本/作者/官网/群信息块（2026-09-16 用户需求）。
## 12px fusion-pixel 基底（字号铁律 12 整数倍），行距 28，沿 1280×960 设计分辨率贴左下。
##
## ★可用宽度限制（2026-09-30 用户实测「左下角文字盖住选项窗口」）：
## 菜单窗口被 `window_y_offset`(300) 压到底部（y 630~930），与本信息块**纵向完全重叠**，
## 只能靠**左边界**避让 → 超宽的行按「菜单窗口左边界 − 留白」自动折行。
## 实测：`本游戏处于测试阶段，遇到 bug 欢迎在交流群反馈` 24px 下宽 540px（x 14→554），
## 已越进窗口左边界 520 → 压住窗口左下角。折行后每行 ≤ 可用宽，任何窗口尺寸/偏移都不会再压住。
## ⚠ 字体切换会改变字宽（zpix 13/7 > fusion 12/6）→ 由 _on_global_font_changed 重建本块。
const FOOTER_X: float = 14.0
const FOOTER_LINE_H: float = 28.0
const FOOTER_BOTTOM_MARGIN: float = 10.0
const FOOTER_DESIGN_H: float = 960.0
const FOOTER_FONT_SIZE: int = 24
## 折行时与菜单窗口左边界保留的最小留白（含阴影偏移余量）。
const FOOTER_GAP: float = 12.0
var _footer_labels: Array[GradientLabel] = []


## 信息块可用宽度 = 菜单窗口左边界 − 留白 − 起始 x。
## 取不到窗口时退回整幅设计宽度（不会折行，但也不会崩）。
func _footer_max_width() -> float:
	var limit: float = FOOTER_DESIGN_H * (1280.0 / 960.0)
	var win: Control = get_node_or_null("MenuWindow")
	if win != null:
		limit = win.position.x - FOOTER_GAP
	return maxf(160.0, limit - FOOTER_X)


## 按可用宽度逐字符折行（保留原文，不丢字）。单字即超宽时也至少吐出一个字符，防死循环。
## `continuation_indent`：第二行起的缩进（子项换行后仍能看出属于上一条），计入量宽。
## ★**统一入口**：左下信息块与更新日志正文都走它 —— 两处都必须「不裁剪右侧」。
func _wrap_text_to_width(text: String, max_w: float, font_size: int, continuation_indent: String = "") -> Array[String]:
	var out: Array[String] = []
	var prefix: String = ""
	var current: String = ""
	for i: int in text.length():
		var ch: String = text[i]
		if current.is_empty() or _measure_text(prefix + current + ch, font_size).x <= max_w:
			current += ch
		else:
			out.append(prefix + current)
			prefix = continuation_indent
			current = ch
	if not current.is_empty():
		out.append(prefix + current)
	return out


func _wrap_footer_line(text: String, max_w: float) -> Array[String]:
	return _wrap_text_to_width(text, max_w, FOOTER_FONT_SIZE)


func _build_footer_info() -> void:
	## 幂等：字体切换会重新调用本函数（见 _on_global_font_changed）。
	for old: Node in _footer_labels:
		if is_instance_valid(old):
			remove_child(old)
			old.queue_free()
	_footer_labels.clear()

	var version: String = str(ProjectSettings.get_setting("application/config/version", ""))
	var vi: Dictionary = Engine.get_version_info()
	var engine_text: String = "Godot Engine %d.%d" % [int(vi.get("major", 4)), int(vi.get("minor", 6))]
	var lines: Array[String] = []
	if not version.is_empty():
		lines.append("v%s ｜ %s" % [version, engine_text])
	else:
		lines.append(engine_text)
	lines.append("制作：剑客")
	lines.append("官网：https://l3dre.xyz:8443")
	lines.append("QQ交流群：1125775141")
	lines.append("本游戏处于测试阶段，遇到 bug 欢迎在交流群反馈")

	## 折行后按总行数**自下而上**排版（底边固定），行数变化不会把首行推出画布。
	var max_w: float = _footer_max_width()
	var wrapped: Array[String] = []
	for line: String in lines:
		wrapped.append_array(_wrap_footer_line(line, max_w))
	var start_y: float = FOOTER_DESIGN_H - FOOTER_BOTTOM_MARGIN - wrapped.size() * FOOTER_LINE_H
	var win: Control = get_node_or_null("MenuWindow")
	for i: int in wrapped.size():
		var gl := _make_menu_gradient_label(wrapped[i], Vector2(FOOTER_X, start_y + i * FOOTER_LINE_H), FOOTER_FONT_SIZE, text_color_index)
		add_child(gl)
		## ★绘制次序是本问题的**另一半根因**：信息块在 _ready 里晚于 MenuWindow 建，
		## 直接 add_child = 画在窗口**之上**（用户看到的「文字盖住选项窗口」）。
		## 只靠折行避让也挡不住设置窗（520 宽 → 左边界 380，比主菜单窗口更靠左），
		## 所以必须把信息块钉到 MenuWindow **之前**：宁可被窗口压住，绝不压住窗口。
		if win != null:
			move_child(gl, mini(win.get_index(), get_child_count() - 1))
		_footer_labels.append(gl)


## 右上角「F1 更新日志」角标（12px fusion 基底，贴 1280×960 设计分辨率右上）。
## ★文案按平台取（2026-09-30 用户需求）：手机没有 F1 → 只写「更新日志」。
func _build_update_log_icon() -> void:
	if _update_log_icon != null:
		return
	var log_text: String = "更新日志" if Global.is_mobile_platform() else "F1 更新日志"
	_update_log_icon = _make_menu_gradient_label(log_text, Vector2.ZERO, 24, text_color_index)
	add_child(_update_log_icon)
	# GradientLabel 自算宽 → 延后一帧按实际宽右对齐
	await get_tree().process_frame
	if _update_log_icon != null and is_instance_valid(_update_log_icon):
		## ⚠ 不能写死 1280：逻辑画布会按屏幕比例横向加宽（16:9 → 1706），
	## 写死会让"更新日志"角标停在画布中间偏左。
		_update_log_icon.position = Vector2(get_viewport_rect().size.x - _update_log_icon.size.x - 14.0, 10.0)


func _open_update_log(play_sfx: bool = true) -> void:
	if _update_log_panel != null:
		return
	if play_sfx:
		Global.play_ui_sfx("confirm", sfx_confirm_path)
	var panel := Control.new()
	panel.name = "UpdateLogPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(dim)

	## 与 controls_guide（操作说明）完全同款窗口：960×840 居中，WindowBg 整图拉伸
	## （默认 STRETCH_SCALE，渐变条平铺会出色带）+ WindowFrame 九宫（margins 20）。
	var win := Control.new()
	win.name = "LogWindow"
	win.size = Vector2(960, 840)
	## 同上：按**当前**画布尺寸居中，别写死 1280。
	win.position = ((get_viewport_rect().size - win.size) * 0.5).floor()
	panel.add_child(win)

	var bg := TextureRect.new()
	bg.texture = load("res://art/System/Window background color.png")
	bg.size = win.size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(bg)

	var frame := NinePatchRect.new()
	frame.texture = load("res://art/System/Window frame.png")
	frame.patch_margin_left = 20
	frame.patch_margin_top = 20
	frame.patch_margin_right = 20
	frame.patch_margin_bottom = 20
	frame.size = win.size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(frame)

	# 标题 36px，两帧后按实际宽居中（GradientLabel 首帧测宽不稳）
	var title := _make_menu_gradient_label("更 新 日 志", Vector2.ZERO, 36, text_color_index)
	win.add_child(title)
	## 居中走 resized 信号跟随——GradientLabel 内部重建时序不稳，帧等待测宽仍会偏；
	## 信号在每次 size 变化时自动回正（2026-09-17 用户反馈"还是不够居中"）。
	title.resized.connect(func() -> void:
		title.position.x = (win.size.x - title.size.x) / 2.0
	)
	title.position.y = 20.0

	# 分隔线（操作说明同款）
	var sep := ColorRect.new()
	sep.color = Color(0.5, 0.5, 0.7, 0.5)
	sep.position = Vector2(24, 72)
	sep.size = Vector2(win.size.x - 48, 2)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(sep)

	# 滚动裁剪区 + VBox 自动排版（操作说明同款，杜绝手算行高溢出）
	var clip := Control.new()
	clip.name = "ScrollClip"
	clip.position = Vector2(28, 88)
	clip.size = Vector2(win.size.x - 56, win.size.y - 88 - 52)
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(clip)

	var flow := VBoxContainer.new()
	flow.name = "Content"
	flow.position = Vector2(6, 6)
	## 不显式设 size（对齐 controls_guide）：高度由子行 min 自动撑起，size.y 才能用于滚动量程
	flow.add_theme_constant_override("separation", 8)
	clip.add_child(flow)
	_log_content = flow
	_log_clip_height = clip.size.y
	_scroll_log_y = 0.0

	var g2: Node = get_node_or_null("/root/Global")
	## ★正文按裁剪区宽度**预先折行**（2026-09-30 用户截图：右侧被裁，长句后半段看不见）。
	## `clip_contents` 会直接切掉超宽部分，而 Label 默认不折行 → 必须自己在建行前折。
	## ⚠ **不用 `Label.autowrap_mode`**：`flow` 的父节点是普通 Control（不是 Container），
	## VBox 宽度不确定 → Label 的折行高度会算错，`get_combined_minimum_size().y`（滚动量程）
	## 随之失真。预先折行则每行都是独立 Label，高度与量程都保持原有语义。
	var body_w: float = clip.size.x - 24.0
	for line: String in CHANGELOG_BODY.split("\n"):
		if line.strip_edges().is_empty():
			continue
		for piece: String in _wrap_text_to_width(line, body_w, CHANGELOG_FONT_SIZE, "  "):
			var lbl := Label.new()
			lbl.text = piece
			if g2 and g2.has_method("apply_hint_font"):
				g2.apply_hint_font(lbl, CHANGELOG_FONT_SIZE)
			if g2 and g2.has_method("apply_text_shadow"):
				g2.apply_text_shadow(lbl)
			if piece.begins_with("【"):
				lbl.add_theme_color_override("font_color", Color(1, 0.95, 0.55))
			else:
				lbl.add_theme_color_override("font_color", Color(1, 1, 1))
			_add_changelog_row(flow, lbl)

	# 底部提示（文案按平台取：手机用触摸层的摇杆 / 取消按钮名）
	var hint_text: String = "↑↓ / 滚轮 滚动    F1 / Esc 返回" if not Global.is_mobile_platform() \
		else "摇杆上下 滚动    %s 返回" % Global.key_hint(&"取消键")
	var hint := _make_menu_gradient_label(hint_text, Vector2(24, win.size.y - 46.0), 24, text_color_index)
	win.add_child(hint)

	add_child(panel)
	_update_log_panel = panel
	print("[标题画面] 打开更新日志（v%s）" % str(ProjectSettings.get_setting("application/config/version", "")))


## 更新日志正文行挂进 VBox。
## 32px 行高下限（24px 字号的 12 整数倍）：12px 基底像素字实际渲染格比字体报告的
## 高度更高，按 min size 算会"恰好塞下"→ 滚动范围恒 0、末行被裁剪边切掉
## （2026-09-17 用户反馈：还是不能滚）。
func _add_changelog_row(flow: VBoxContainer, lbl: Label) -> void:
	lbl.custom_minimum_size = Vector2(0, 32)
	flow.add_child(lbl)


## 更新日志滚动（内容高于裁剪区时 ↑↓/滚轮 平移 VBox）。
## 更新日志滚动（2026-09-17 手感对齐 controls_guide）：↑↓ 按住连续滚 420px/s + 滚轮。
## 在 _process 里驱动；不显式设 VBox size，量程用 get_combined_minimum_size().y。
func _process_log_scroll(delta: float) -> void:
	if _log_content == null or not is_instance_valid(_log_content):
		return
	var dir: float = 0.0
	if Input.is_action_pressed("上"):
		dir -= 1.0
	if Input.is_action_pressed("下"):
		dir += 1.0
	_scroll_log_y = clampf(_scroll_log_y + dir * 420.0 * delta, 0.0, _log_scroll_max())
	_log_content.position.y = 6.0 - _scroll_log_y


func _log_scroll_max() -> float:
	if _log_content == null or not is_instance_valid(_log_content):
		return 0.0
	return maxf(0.0, _log_content.get_combined_minimum_size().y - _log_clip_height)


func _scroll_update_log(delta_y: float) -> void:
	_scroll_log_y = clampf(_scroll_log_y + delta_y, 0.0, _log_scroll_max())
	_log_content.position.y = 6.0 - _scroll_log_y


func _close_update_log() -> void:
	if _update_log_panel != null and is_instance_valid(_update_log_panel):
		_update_log_panel.queue_free()
	_update_log_panel = null
	_log_content = null
	_scroll_log_y = 0.0
	Global.play_ui_sfx("cursor", sfx_cursor_path)


func _load_defaults_from_global() -> void:
	var g = get_node_or_null("/root/Global")
	if not g:
		return
	## 字体（2026-09-24）：font_path 只是**本窗口的偏好路径**，实际取值一律经
	## Global.resolve_and_load_font / GradientLabel 的 resolve_ui_font_path 解析 ——
	## 留空或值属于可切换字体族（fusion/ark 12px）时跟随「设置 → 界面字体」。
	## 色表路径仍以场景导出为准。颜色/阴影等样式参数从 Global 同步。
	if g.text_color_sheet_path != "" and color_sheet_path.is_empty():
		color_sheet_path = g.text_color_sheet_path
	text_color_index = g.text_color_index
	text_color_row = g.text_color_row
	text_bold = g.text_bold
	text_outline = g.text_outline
	text_outline_color = g.text_outline_color
	text_shadow = g.text_shadow
	text_shadow_color = g.text_shadow_color
	text_shadow_offset = g.text_shadow_offset
	print("[标题画面] Global 同步 — 色表索引=%d 粗体=%s 描边=%s 阴影=%s" % [text_color_index, text_bold, text_outline, text_shadow])




func _process(delta: float) -> void:
	if _update_log_panel != null:
		_process_log_scroll(delta)


func _input(event: InputEvent) -> void:
	# ── 成就页（2026-10-02）：打开时吞掉全部菜单输入（与下方 F1 更新日志同款做法）──
	# 按键由叠加层自己处理并关闭它，这里只需不把同一按键再喂给菜单。
	if _achievements_overlay != null:
		return
	# ── 存档槽位叠加层（2026-10-03）：打开时吞掉全部菜单输入（按键由叠加层自己处理）──
	if _slot_overlay != null:
		return
	# ── 收藏馆叠加层（2026-10-23）：同上，按键全交给收藏馆自己处理 ──
	if _collection_overlay != null:
		return
	# ── 游戏模式 / 记录报表叠加层（2026-11-10）：同上 ──
	if _mode_overlay != null:
		return
	if _records_overlay != null:
		return
	# ── F1 更新日志（2026-09-17）：打开时吞掉全部菜单输入，F1/Esc/确定键关闭 ──
	var f1_pressed: bool = event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_F1
	if _update_log_panel != null:
		if f1_pressed or event.is_action_pressed("取消键") or event.is_action_pressed("确定键"):
			_close_update_log()
			return
		# 滚动：滚轮（↑↓ 的连续滚动在 _process 驱动，这里不再叠加按键跳变，
		# 否则第一次按下会先瞬移 48px 再开始滑——2026-09-17 用户反馈）
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_scroll_update_log(-48.0)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_scroll_update_log(48.0)
			return
		return
	if f1_pressed:
		_open_update_log()
		return

	if _in_settings:
		_handle_settings_input(event)
		return

	## 「其他」二级页：取消键返回主菜单（主菜单本身没有取消行为）。
	if _in_other_menu and event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		_exit_other_menu()
		return

	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		_confirm()
		return

	var item_count: int = _active_items().size()
	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
	else:
		return

	if _cursor_idx < _scroll_offset:
		_scroll_offset = _cursor_idx
		_rebuild_menu_items()
	elif _cursor_idx >= _scroll_offset + _visible_items:
		_scroll_offset = _cursor_idx - _visible_items + 1
		_rebuild_menu_items()

	_refresh_all()


# ═══════════════════════════════════════
# 色表采样（CPU）
# ═══════════════════════════════════════

func _load_pixel_font(_base_size: int = 16) -> Font:
	## 2026-09-24：字体改由 Global 单一入口解析 —— font_path 留空、或值属于可切换
	## 字体族（fusion/ark 12px）时跟随「设置 → 界面字体」的当前选择；真正自定义的值原样用。
	var g: Node = get_node_or_null("/root/Global")
	if g and g.has_method("resolve_and_load_font"):
		return g.resolve_and_load_font(font_path)
	var font_file: FontFile = load(font_path) as FontFile
	if not font_file:
		printerr("[标题画面] 无法加载字体: %s" % font_path)
		return ThemeDB.fallback_font
	return font_file


func _measure_text(text: String, font_size: int) -> Vector2:
	var font := _load_pixel_font(font_size)
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)


# ═══════════════════════════════════════
# 光标框
# ═══════════════════════════════════════

func _create_cursor_frames() -> void:
	var src: Texture2D = load(cursor_frame_path) as Texture2D
	if not src:
		return
	for i: int in range(2):
		var at := AtlasTexture.new()
		at.atlas = src
		at.region = Rect2(i * 64, 0, 64, 64)
		at.filter_clip = true
		_cursor_atlas.append(at)


func _start_cursor_blink() -> void:
	var timer := Timer.new()
	timer.name = "CursorBlinkTimer"
	timer.wait_time = 0.3
	timer.timeout.connect(_on_cursor_blink)
	add_child(timer)
	timer.start()


func _on_cursor_blink() -> void:
	if _cursor_atlas.is_empty() or not _cursor_frame:
		return
	_cursor_frame_idx = 1 - _cursor_frame_idx
	_cursor_frame.texture = _cursor_atlas[_cursor_frame_idx]


func _get_cursor_height() -> float:
	return cursor_base_height * cursor_scale_y


## 选择框几何：x = 左内间距，宽 = 窗口宽 - 左右内间距（override > 0 时用固定宽）。
func _cursor_rect_x() -> float:
	return cursor_window_padding


func _cursor_rect_w() -> float:
	if cursor_override_width > 0.0:
		return cursor_override_width
	return maxf(window_size.x - cursor_window_padding * 2.0, cursor_min_width)


func _calc_max_text_width() -> float:
	var max_w: float = 0.0
	for item: String in _active_items():
		var ts := _measure_text("  %s" % item, item_font_size)
		max_w = maxf(max_w, ts.x)
	return max_w


func _get_item_area_width() -> float:
	if item_width > 0.0:
		return item_width
	return _calc_max_text_width()


func _get_item_x() -> float:
	if not _is_centered():
		return item_text_x
	return item_text_x  ## 居中时由调用方按 GradientLabel 实际宽度二次定位（见 _center_label）


## 是否启用文字居中：旧 export（item_centered）或设置开关（Global.menu_item_centered）。
func _is_centered() -> bool:
	if item_centered:
		return true
	var g: Node = get_node_or_null("/root/Global")
	return g != null and bool(g.get("menu_item_centered"))


## 按**实际渲染字体量出的文本宽**做真居中。
##
## ★ 2026-10-02 修：原来用 `gl.size.x` —— 但 GradientLabel 的 size 是**延迟一帧**才刷新的
## （`text` 赋值当帧读到的还是上一个长度），于是「成就」「设置」这类同宽项会算出不同的 x
## （实测 96 vs 72，左边缘错开 24px，看起来就是"某一项文字往左移了"）。
## 量宽改用 `_measure_text`（同一份 fusion 像素字体、同一字号）→ 与最终渲染完全一致，且当帧可用。
func _center_label(gl: GradientLabel) -> float:
	var w: float = _measure_text(gl.text, item_font_size).x
	if w <= 0.0:
		w = gl.size.x                      ## 极端兜底：字体取不到时退回节点自身宽度
	gl.size.x = w                          ## 宽度也按实测值当帧写回（**不能用 maxf**：会锁死旧宽度）
	gl.position.x = (window_size.x - w) / 2.0
	return gl.position.x


# ═══════════════════════════════════════
# 窗口构建
# ═══════════════════════════════════════

func _create_menu_window() -> void:
	var win: Control = $MenuWindow

	## ⚠ 按**当前**画布宽度居中，不能写死 1280（手机端画布会横向加宽到 1706）。
	## 纵向 = 画布居中 + `window_y_offset`。menu_y_offset(tscn 里 = 268) 是**配合 6 项菜单**
	## 调出来的：窗口高 364 时顶部落在 566、**底边钉在 930**（与旧的 300 高 / offset 300 完全同一条底边），
	## 于是"窗口变高但底边不动"= 整体向上长，不会顶出 960 的画布底部。
	win.position = _menu_window_position(window_size)
	win.size = window_size

	# 窗口底图/九宫格框：节点化（2026-09-15），视觉元素在 title_screen.tscn 里，
	# 这里只按 window_size 同步尺寸（设置页加宽/还原共用 _apply_window_size）
	_window_bg.size = window_size
	_window_frame.size = window_size

	# 标题（可选）
	if show_title:
		_title_gradient_label = _make_menu_gradient_label(WINDOW_TITLE, title_position, title_font_size, text_title_color_index)
		win.add_child(_title_gradient_label)

		var sep := ColorRect.new()
		sep.name = "Separator"
		sep.color = Color(0.5, 0.5, 0.7, 0.5)
		sep.size = Vector2(window_size.x - 32, 1)
		sep.position = Vector2(16, separator_y)
		win.add_child(sep)

	# 可见区域
	_recalc_visible_items()

	# 光标框：节点化（tscn 预置），这里只按导出参数摆初始几何；
	# 宽度默认 = 窗口宽 - 左右内间距，之后 _refresh_cursor_frame 每次刷新
	if _cursor_frame:
		_cursor_frame.size = Vector2(_cursor_rect_w(), _get_cursor_height())
		_cursor_frame.position = Vector2(
			_cursor_rect_x(),
			item_start_y + (item_height - _get_cursor_height()) / 2.0 + cursor_offset_y
		)
	# 菜单项
	_rebuild_menu_items()

	# 滚动箭头
	_create_scroll_arrow(win, arrow_down_path, "ScrollArrowDown",
		item_start_y + _visible_items * (item_height + item_spacing) + 4)
	_create_scroll_arrow(win, arrow_up_path, "ScrollArrowUp",
		item_start_y - 16)


## 当前窗口高度 / 项数下能完整显示几项（子菜单切窗口后要重算）。
func _recalc_visible_items() -> void:
	var start_y: float = separator_y + item_title_gap if show_title else item_start_y
	var avail_h: float = window_size.y - start_y - item_margin_bottom
	var row_step: float = item_height + item_spacing
	_visible_items = clampi(int(avail_h / row_step), 1, _active_items().size())


func _create_scroll_arrow(parent: Control, path: String, pname: String, pos_y: float) -> void:
	var tex: Texture2D = load(path) as Texture2D
	if not tex:
		return
	var arrow := TextureRect.new()
	arrow.name = pname
	arrow.texture = tex
	arrow.size = tex.get_size()
	arrow.position = Vector2((window_size.x - tex.get_size().x) / 2.0, pos_y)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.hide()
	parent.add_child(arrow)
	if pname == "ScrollArrowDown":
		_scroll_arrow_down = arrow
	else:
		_scroll_arrow_up = arrow


func _rebuild_menu_items() -> void:
	## 菜单项已节点化（Item0..Item4 预置在 title_screen.tscn，编辑器直接调样式）。
	## 运行时只同步文本（居中开关加/去前缀）与位置，不再删建节点。
	## 2026-10-23：文本一律取「当前菜单」（顶层 / 「其他」），两级共用同一批节点。
	var items: Array[String] = _active_items()
	var end_idx: int = mini(_scroll_offset + _visible_items, items.size())
	for i: int in range(items.size()):
		if i >= _menu_item_labels.size():
			break
		var gl: GradientLabel = _menu_item_labels[i]
		## ★ 文本与位置**一律**设置（含被滚动隐藏的项）：隐藏项若保留上一次的 y，
		## 滚动回来时就会与相邻可见项同 y 叠放（2026-10-02 布局用例抓到）。
		## 显隐统一放在最后一行赋值。
		var display_idx: int = i - _scroll_offset
		# 居中模式去掉 "  " 前缀空格——否则量宽连空格一起居中，文字整体右偏
		var item_text := items[i] if _is_centered() else "  %s" % items[i]
		gl.text = item_text
		## 文字行内垂直位置（2026-09-15 两轮实测校准）：完全顶行首偏上、居中偏移
		## (44-24)/2=10 又偏下，+5（行高差四分之一）正好——fusion 度量 ascent20/descent4
		var text_y: float = item_start_y + display_idx * (item_height + item_spacing) \
				+ (item_height - item_font_size) * 0.25
		gl.position = Vector2(_get_item_x(), text_y)
		if item_width > 0.0:
			gl.size.x = item_width
		# 文字居中排列：按实际渲染字体量出的文本宽二次定位
		if _is_centered():
			_center_label(gl)
		gl.visible = display_idx >= 0 and i < end_idx

	## 多出来的预置/复制节点（两级菜单项数不同）必须显式隐藏 ——
	## 循环只覆盖当前菜单项数，上一级多出来的第 6 项否则会一直留在屏幕上。
	for j: int in range(items.size(), _menu_item_labels.size()):
		if is_instance_valid(_menu_item_labels[j]):
			_menu_item_labels[j].visible = false

	_update_scroll_arrows()


func _make_menu_gradient_label(label_text: String, pos: Vector2, font_size: int, color_idx: int) -> GradientLabel:
	var gl := GradientLabel.new()
	gl.text = label_text
	gl.position = pos
	gl.text_font_size = font_size
	gl.color_index = color_idx
	gl.color_row = text_color_row
	gl.bold = text_bold
	gl.shadow = text_shadow
	gl.shadow_color = text_shadow_color
	gl.shadow_offset = text_shadow_offset
	gl.outline = text_outline
	gl.outline_color = text_outline_color
	gl.font_path_override = font_path
	gl.color_sheet_path_override = color_sheet_path
	if _color_img:
		gl.set_color_image(_color_img)
	return gl


## 菜单项显隐（进设置页时隐藏节点化菜单项，退出恢复）
func _set_menu_items_visible(v: bool) -> void:
	for gl in _menu_item_labels:
		if is_instance_valid(gl):
			gl.visible = v


func _update_scroll_arrows() -> void:
	if _scroll_arrow_down:
		_scroll_arrow_down.visible = (_scroll_offset + _visible_items < _active_items().size())
	if _scroll_arrow_up:
		_scroll_arrow_up.visible = (_scroll_offset > 0)


# ═══════════════════════════════════════
# 交互
# ═══════════════════════════════════════

func _refresh_all() -> void:
	_refresh_cursor_frame()
	_update_scroll_arrows()


func _refresh_cursor_frame() -> void:
	if not _cursor_frame:
		return
	var display_idx: int = _cursor_idx - _scroll_offset
	var cur_h := _cursor_frame.size.y
	_cursor_frame.position.y = item_start_y + display_idx * (item_height + item_spacing) + (item_height - cur_h) / 2.0 + cursor_offset_y
	# 宽度/横向位置随窗口尺寸实时同步（设置页加宽/还原时选择框跟着变）
	_cursor_frame.size.x = _cursor_rect_w()
	_cursor_frame.position.x = _cursor_rect_x()


func _confirm() -> void:
	match _active_items()[_cursor_idx]:
		"继续游戏":
			_go_to_load_game()
		"开始游戏":
			_go_to_campaign_select()
		"联机游戏":
			_go_to_network_lobby()
		"收藏馆":
			_open_collection()
		"其他":
			_enter_other_menu()
		"操作说明":
			_go_to_controls_guide()
		"成就":
			_open_achievements()
		"设置":
			_enter_settings()
		"竞速记录":
			_open_records(0)
		"游玩统计":
			_open_records(1)
		"更新日志":
			## 确定音效已在 _input 里播过 → 这里不再重复。
			_open_update_log(false)
		"退出游戏":
			_quit_game()
		"返回":
			_exit_other_menu()


# ═══════════════════════════════════════
# 「其他」二级菜单（2026-10-23）
# ═══════════════════════════════════════

## 进入二级页：换项列表 + 按 6 项推导窗口高度；主菜单光标先存起来。
func _enter_other_menu() -> void:
	if _in_other_menu:
		return
	_main_cursor_idx = _cursor_idx
	_in_other_menu = true
	_cursor_idx = _other_cursor_idx
	_scroll_offset = 0
	_apply_window_size(_window_size_for(OTHER_ITEMS))
	_rebuild_menu_items()
	_refresh_all()


## 返回主菜单：恢复主菜单光标与窗口高度。
func _exit_other_menu() -> void:
	if not _in_other_menu:
		return
	_other_cursor_idx = _cursor_idx
	_in_other_menu = false
	_cursor_idx = _main_cursor_idx
	_scroll_offset = 0
	_apply_window_size(_window_size_for(MENU_ITEMS))
	_rebuild_menu_items()
	_refresh_all()


## 操作说明（2026-09-14 新增菜单项）：界面与 txt 文档内容待用户确认后实现，
## 届时切换到 controls_guide_scene；确认前先占位避免误触无反应。
func _go_to_controls_guide() -> void:
	if ResourceLoader.exists(controls_guide_scene):
		var err: Error = get_tree().change_scene_to_file(controls_guide_scene)
		if err != OK:
			printerr("[标题画面] 操作说明场景切换失败: %d" % err)
		return
	print("[标题画面] 操作说明界面尚未实现（内容待用户确认）")


# ═══════════════════════════════════════
# 成就页（2026-10-02）
# ═══════════════════════════════════════
var _achievements_overlay: Control = null


## 菜单项数多于场景里预置的 Item 节点时，复制最后一个补足。
## 复制的依据：Item 节点是 @tool 的 GradientLabel，节点化时已调好字体/字号/行距/位置，
## `duplicate()` 能一并继承；随后既有的布局代码（按 MENU_ITEMS.size() 迭代）自动生效。
func _ensure_menu_item_nodes() -> void:
	if _menu_item_labels.is_empty():
		return
	var parent: Node = _menu_item_labels[0].get_parent()
	## 两级菜单里项数较多的一边决定节点数（「其他」6 项 > 顶层 5 项）。
	var need: int = maxi(MENU_ITEMS.size(), OTHER_ITEMS.size())
	while _menu_item_labels.size() < need:
		var proto: Node = _menu_item_labels[_menu_item_labels.size() - 1]
		var clone: Node = proto.duplicate()
		parent.add_child(clone)
		_menu_item_labels.append(clone)


## 打开成就一览（叠加在标题之上；关闭后销毁）。
func _open_achievements() -> void:
	if _achievements_overlay != null:
		return
	_achievements_overlay = ACHIEVEMENTS_MENU.new()
	add_child(_achievements_overlay)
	_achievements_overlay.connect("closed", _close_achievements)


func _close_achievements() -> void:
	if _achievements_overlay == null:
		return
	_achievements_overlay.queue_free()
	_achievements_overlay = null


# ═══════════════════════════════════════
# 收藏馆（2026-10-23）
# ═══════════════════════════════════════
var _collection_overlay: Control = null
var _mode_overlay: Control = null
var _records_overlay: Control = null


## 打开收藏馆（叠加在标题之上；关闭后销毁）。
func _open_collection() -> void:
	if _collection_overlay != null:
		return
	_collection_overlay = COLLECTION_MENU.new()
	add_child(_collection_overlay)
	_collection_overlay.connect("closed", _close_collection)


func _close_collection() -> void:
	if _collection_overlay == null:
		return
	_collection_overlay.queue_free()
	_collection_overlay = null


# ═══════════════════════════════════════
# 继续游戏（读档，2026-10-03）
# ═══════════════════════════════════════
var _slot_overlay: Node = null
var _no_save_label: GradientLabel = null

## 「继续游戏」：有档 → 打开槽位选择（读取模式）；无档 → 原地提示一下。
func _go_to_load_game() -> void:
	if not SAVE_MANAGER.has_any_save():
		_show_no_save_hint()
		return
	if _slot_overlay != null:
		return
	_slot_overlay = SAVE_SLOT_MENU.new()
	_slot_overlay.setup(SAVE_SLOT_MENU.Mode.LOAD, false)
	_slot_overlay.connect("chosen", _on_load_slot_chosen)
	_slot_overlay.connect("closed", _on_slot_overlay_closed)
	add_child(_slot_overlay)


func _on_slot_overlay_closed() -> void:
	_slot_overlay = null


func _on_load_slot_chosen(idx: int) -> void:
	_slot_overlay = null
	## 载入 + 切图由 Global 统一负责（恢复队伍/场景/难度，并把玩家落回存档点）。
	if not Global.load_from_slot(idx):
		_show_no_save_hint("读取失败：存档已损坏或场景缺失")


## 窗口内的一条临时提示（无档 / 读取失败），约 1.6s 后消失。
func _show_no_save_hint(text: String = "还没有存档 —— 去游戏里的存档点存一个吧") -> void:
	if _no_save_label != null and is_instance_valid(_no_save_label):
		_no_save_label.queue_free()
	_no_save_label = _make_menu_gradient_label(text, Vector2(0, window_size.y - 52.0), 24, text_color_index)
	_no_save_label.size.x = window_size.x
	$MenuWindow.add_child(_no_save_label)
	_center_label(_no_save_label)

	var timer := Timer.new()
	timer.wait_time = 1.6
	timer.one_shot = true
	add_child(timer)
	var cb: Callable = func():
		if _no_save_label != null and is_instance_valid(_no_save_label):
			_no_save_label.queue_free()
		_no_save_label = null
	timer.timeout.connect(cb)
	timer.start()


const SAVE_MANAGER := preload("res://script/save_manager.gd")
const SAVE_SLOT_MENU := preload("res://script/ui/save_slot_menu.gd")


## 成就页脚本（**preload 常量而不是 class_name**：本项目 class_name 不进全局类缓存，
## 跨文件按名字引用会在 headless / 导出时报 Parse Error）。
const ACHIEVEMENTS_MENU := preload("res://script/ui/achievements_menu.gd")
## 收藏馆页脚本（同上：preload，不用 class_name）。
const COLLECTION_MENU := preload("res://script/ui/collection_menu.gd")
## 游戏模式选择（2026-11-10）：单人选战役之前的一道选择，代码构建叠加层。
const GAME_MODE_MENU := preload("res://script/ui/game_mode_menu.gd")
## 竞速记录 / 游玩统计（2026-11-10）：同一个报表页，用 page 区分。
const RECORDS_MENU := preload("res://script/ui/records_menu.gd")


# ═══════════════════════════════════════
# 设置面板
# ═══════════════════════════════════════

## 菜单窗口的唯一定位入口：水平居中 + `window_y_offset`，纵向再**夹紧到可视野内**。
##
## ★2026-11-04：旧公式 `(960 - h)/2 + offset` 在窗口变高时是**上下对称长**的
## （顶边上移 h/2、底边下移 h/2）。设置页加到 11 行（584 高）时底边跑到 1040，
## 最后一行「返回」被画布切掉。底边钉回可视野内即可：
## 主菜单（364 高）算出 566 < 588，位置**分毫不变**。
## ⚠ 进设置与退设置两条路必须同源，否则窗口会跳。
func _menu_window_position(size: Vector2) -> Vector2:
	var y: float = (960.0 - size.y) / 2.0 + window_y_offset
	y = clampf(y, WINDOW_TOP_MARGIN, 960.0 - size.y - WINDOW_BOTTOM_MARGIN)
	return Vector2((get_viewport_rect().size.x - size.x) / 2.0, y)


func _apply_window_size(s: Vector2) -> void:
	## 运行时改窗口尺寸（设置页加宽 / 退出还原）：窗口、RM 底图、九宫格框同步，
	## 并按新尺寸重新居中。
	window_size = s
	var win: Control = $MenuWindow
	win.position = _menu_window_position(s)
	win.size = s
	if _window_bg:
		_window_bg.size = s
	if _window_frame:
		_window_frame.size = s
	_recalc_visible_items()


## 当前菜单该用的窗口尺寸（设置页退出时恢复到「进去之前那一级」）。
func _menu_window_size() -> Vector2:
	return _window_size_for(OTHER_ITEMS) if _in_other_menu else _window_size_for(MENU_ITEMS)


## 设置页行距。默认与主菜单同（item_height + item_spacing），行数多到超出设置窗时
## 自动压缩 —— 2026-09-24 加了「界面字体」后共 6 行，56×6 会顶出 336 高的窗口。
func _settings_row_step() -> float:
	var step: float = item_height + item_spacing
	var count: int = _settings_items().size()
	if count <= 0:
		return step
	var avail: float = _settings_window_size().y - item_start_y - 8.0
	return minf(step, avail / float(count))


func _enter_settings() -> void:
	_in_settings = true
	_settings_cursor_idx = 0
	_apply_window_size(_settings_window_size())
	_set_menu_items_visible(false)
	_build_settings_items()
	_refresh_settings_cursor()


func _exit_settings() -> void:
	_in_settings = false
	_clear_settings_ui()
	## 从「其他」子菜单进设置 → 退出要回到子菜单尺寸，否则 6 项会挤进 5 行窗口。
	_apply_window_size(_menu_window_size())
	_rebuild_menu_items()
	_refresh_all()


func _build_settings_items() -> void:
	var win: Control = $MenuWindow
	var row_step: float = _settings_row_step()
	var start_y: float = item_start_y
	var label_x: float = item_text_x
	var bar_x: float = label_x + _measure_text("  音乐音量", item_font_size).x + 16.0
	var bar_w: float = SETTINGS_BAR_W
	var bar_h: float = 24.0

	var items: Array[String] = _settings_items()
	for i: int in range(items.size()):
		var pos_y: float = start_y + i * row_step
		var text: String = items[i]

		var gl := _make_menu_gradient_label("  %s" % text, Vector2(label_x, pos_y), item_font_size, text_color_index)
		win.add_child(gl)
		_settings_labels.append(gl)
		if i < 2:
			# 音量条：背景 + 填充 + 百分比标签
			var bar_y: float = pos_y + (item_height - bar_h) / 2.0

			var bg := ColorRect.new()
			bg.name = "VolBarBg%d" % i
			bg.color = Color(0.15, 0.15, 0.15, 0.8)
			bg.size = Vector2(bar_w, bar_h)
			bg.position = Vector2(bar_x, bar_y)
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			win.add_child(bg)
			_settings_bar_bg.append(bg)

			var fill := ColorRect.new()
			fill.name = "VolBarFill%d" % i
			fill.color = Color(0.30, 0.30, 0.60, 0.9)
			fill.size = Vector2(bar_w, bar_h)
			fill.position = Vector2(bar_x, bar_y)
			fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			win.add_child(fill)
			_settings_bar_fill.append(fill)

			var pct_label := _make_menu_gradient_label("", Vector2(bar_x + bar_w + 12, pos_y), item_font_size, text_color_index)
			win.add_child(pct_label)
			_settings_value_labels.append(pct_label)
		elif i == 2:
			# 固定朝向模式标签
			var mode_text: String = "切换式" if Global.facing_lock_mode == 0 else "按住式"
			var mode_label := _make_menu_gradient_label(mode_text, Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(mode_label)
			_settings_value_labels.append(mode_label)
		elif i == 3:
			# 文字居中开关（2026-09-14 新增）
			var center_text: String = "开" if Global.menu_item_centered else "关"
			var center_label := _make_menu_gradient_label(center_text, Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(center_label)
			_settings_value_labels.append(center_label)
		elif i == 4:
			# 界面字体（2026-09-24 新增）：左右或确定键切换，立即重套全 UI
			var font_label := _make_menu_gradient_label(
				Global.font_option_label(), Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(font_label)
			_settings_value_labels.append(font_label)
		elif text == "拾取方式":
			# 物品获取/替换的交互方式（2026-10-26）：点击一下（默认）/ 按住
			var pick_label := _make_menu_gradient_label(
				Global.pickup_hold_label(), Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(pick_label)
			_settings_value_labels.append(pick_label)
		elif text == "灯光闪烁":
			var ls_label := _make_menu_gradient_label(
				Global.light_static_label(), Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(ls_label)
			_settings_value_labels.append(ls_label)
		elif text == "人物影子":
			var cs_label := _make_menu_gradient_label(
				Global.on_off_label(Global.char_shadows), Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(cs_label)
			_settings_value_labels.append(cs_label)
		elif text == "遮挡阴影":
			var oc_label := _make_menu_gradient_label(
				Global.on_off_label(Global.light_occluders), Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(oc_label)
			_settings_value_labels.append(oc_label)
		elif text == "影子质量":
			var sq_label := _make_menu_gradient_label(
				Global.shadow_quality_label(), Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(sq_label)
			_settings_value_labels.append(sq_label)
		elif text == "血液颜色":
			## 直播和谐（2026-11-10）：只改「血」类特效的色相，不动枪口/爆炸/酸液。
			var bc_label := _make_menu_gradient_label(
				Global.blood_color_label(), Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(bc_label)
			_settings_value_labels.append(bc_label)
		elif text == "血液特效":
			var bf_label := _make_menu_gradient_label(
				Global.on_off_label(Global.blood_enabled), Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(bf_label)
			_settings_value_labels.append(bf_label)
		elif i == items.size() - 2 and Global.is_mobile_platform():
			# 按键布局（2026-09-30，仅移动端）：显示「默认 / 自定义」，
			# 确定键 → 进入触摸层的拖动调整模式（见 _enter_touch_layout_edit）。
			var lay_text: String = "自定义" if Global.has_custom_touch_layout() else "默认"
			var lay_label := _make_menu_gradient_label(lay_text, Vector2(bar_x, pos_y), item_font_size, text_color_index)
			win.add_child(lay_label)
			_settings_value_labels.append(lay_label)
		else:
			# "返回" — 无额外控件
			_settings_value_labels.append(null)

	_update_all_settings_volume_display()


func _clear_settings_ui() -> void:
	for gl in _settings_labels:
		if is_instance_valid(gl):
			gl.queue_free()
	_settings_labels.clear()
	for vl in _settings_value_labels:
		if is_instance_valid(vl):
			vl.queue_free()
	_settings_value_labels.clear()
	for bg in _settings_bar_bg:
		if is_instance_valid(bg):
			bg.queue_free()
	_settings_bar_bg.clear()
	for fg in _settings_bar_fill:
		if is_instance_valid(fg):
			fg.queue_free()
	_settings_bar_fill.clear()


func _handle_settings_input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		Global.play_ui_sfx("cancel", sfx_cancel_path)
		_exit_settings()
		return

	var items: Array[String] = _settings_items()
	var item_count: int = items.size()
	if event.is_action_pressed("上"):
		_settings_cursor_idx = (_settings_cursor_idx - 1 + item_count) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_settings_cursor()
		return
	if event.is_action_pressed("下"):
		_settings_cursor_idx = (_settings_cursor_idx + 1) % item_count
		Global.play_ui_sfx("cursor", sfx_cursor_path)
		_refresh_settings_cursor()
		return

	## ★按**项名**分派，不硬编码序号（2026-09-30）：移动端多一项「按键布局」，
	## 序号会变；用名字判断后，以后再加项也不会串行。
	var cur: String = items[_settings_cursor_idx] if _settings_cursor_idx < items.size() else ""
	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		match cur:
			"固定朝向":
				var new_mode: int = 1 if Global.facing_lock_mode == 0 else 0
				Global.set_facing_lock_mode(new_mode)
				var mode_text: String = "切换式" if new_mode == 0 else "按住式"
				if _settings_value_labels[2]:
					_settings_value_labels[2].text = mode_text
			"文字居中":
				Global.menu_item_centered = not Global.menu_item_centered
				if _settings_value_labels[3]:
					_settings_value_labels[3].text = "开" if Global.menu_item_centered else "关"
				# 立即重排当前设置行（标签居中、音量条跟随）
				_clear_settings_ui()
				_build_settings_items()
				_refresh_settings_cursor()
			"界面字体":
				_cycle_ui_font(1)
			"拾取方式":
				Global.set_pickup_hold_mode(not Global.pickup_hold_mode)
				## 值标签按**项名**定位（不写死序号：移动端多一项「按键布局」）
				var pick_idx: int = items.find("拾取方式")
				if pick_idx >= 0 and pick_idx < _settings_value_labels.size() \
						and _settings_value_labels[pick_idx]:
					_settings_value_labels[pick_idx].text = Global.pickup_hold_label()
			"灯光闪烁":
				Global.set_light_static(not Global.light_static)
				_set_settings_value(items, "灯光闪烁", Global.light_static_label())
			"人物影子":
				Global.set_char_shadows(not Global.char_shadows)
				_set_settings_value(items, "人物影子", Global.on_off_label(Global.char_shadows))
			"遮挡阴影":
				Global.set_light_occluders(not Global.light_occluders)
				_set_settings_value(items, "遮挡阴影", Global.on_off_label(Global.light_occluders))
			"影子质量":
				Global.cycle_shadow_quality(1)
				_set_settings_value(items, "影子质量", Global.shadow_quality_label())
			"血液颜色":
				Global.cycle_blood_color(1)
				_set_settings_value(items, "血液颜色", Global.blood_color_label())
			"血液特效":
				Global.set_blood_enabled(not Global.blood_enabled)
				_set_settings_value(items, "血液特效", Global.on_off_label(Global.blood_enabled))
			"按键布局":
				_enter_touch_layout_edit()
			"返回":
				_exit_settings()
		return

	# 左/右 调音量
	var delta_vol: int = 0
	if event.is_action_pressed("左"):
		delta_vol = -5
	elif event.is_action_pressed("右"):
		delta_vol = 5
	else:
		return

	match cur:
		"音乐音量":
			Global.set_music_volume(clampi(Global.music_volume + delta_vol, 0, 100))
			_update_settings_volume_display(0)
		"音效音量":
			Global.set_sfx_volume(clampi(Global.sfx_volume + delta_vol, 0, 100))
			_update_settings_volume_display(1)
		"界面字体":  # 左右 = 上一个 / 下一个
			_cycle_ui_font(-1 if delta_vol < 0 else 1)
		"影子质量":  # 左右 = 降一档 / 升一档
			Global.cycle_shadow_quality(-1 if delta_vol < 0 else 1)
			_set_settings_value(items, "影子质量", Global.shadow_quality_label())
		"血液颜色":  # 左右 = 上一种 / 下一种
			Global.cycle_blood_color(-1 if delta_vol < 0 else 1)
			_set_settings_value(items, "血液颜色", Global.blood_color_label())
		"血液特效":
			Global.set_blood_enabled(not Global.blood_enabled)
			_set_settings_value(items, "血液特效", Global.on_off_label(Global.blood_enabled))
		"灯光闪烁":
			Global.set_light_static(not Global.light_static)
			_set_settings_value(items, "灯光闪烁", Global.light_static_label())
		"人物影子":
			Global.set_char_shadows(not Global.char_shadows)
			_set_settings_value(items, "人物影子", Global.on_off_label(Global.char_shadows))
		"遮挡阴影":
			Global.set_light_occluders(not Global.light_occluders)
			_set_settings_value(items, "遮挡阴影", Global.on_off_label(Global.light_occluders))


## ── 按键布局调整（2026-09-30，仅移动端）──
## 交给触摸层自己的编辑模式（拖动 / 保存 / 恢复默认都在那边），设置页只负责
## 「进入」+「结束后刷新这一行的『默认 / 自定义』显示」。
func _enter_touch_layout_edit() -> void:
	var tc: Node = Global.touch_controls()
	if tc == null or not tc.has_method("enter_layout_edit"):
		push_warning("[标题画面] 触摸层不存在，无法进入按键布局调整（桌面端属正常）")
		return
	if not tc.is_connected("layout_edit_finished", _on_touch_layout_edit_finished):
		tc.connect("layout_edit_finished", _on_touch_layout_edit_finished)
	tc.call("enter_layout_edit")


func _on_touch_layout_edit_finished(_saved: bool) -> void:
	if not _in_settings:
		return
	## 重建设置行：值标签要跟着「默认 / 自定义」变。
	## ⚠ 不能调 `_rebuild_menu_items()` —— 它会把隐藏中的主菜单项 show() 回来。
	_clear_settings_ui()
	_build_settings_items()
	_refresh_settings_cursor()


## 按**项名**刷新某一行右侧的值文本（不写死序号：项数会随平台/版本变）。
func _set_settings_value(items: Array[String], item_text: String, value_text: String) -> void:
	var idx: int = items.find(item_text)
	if idx >= 0 and idx < _settings_value_labels.size() and _settings_value_labels[idx]:
		_settings_value_labels[idx].text = value_text


## 循环切换界面字体并刷新该行显示（Global 会广播 font_changed → 本窗口重排）。
func _cycle_ui_font(delta: int) -> void:
	if Global.ui_font_option_count() <= 0:
		return
	var count: int = Global.ui_font_option_count()
	var next: int = posmod(Global.font_option + delta, count)
	Global.set_font_option(next)
	if _settings_value_labels.size() > 4 and _settings_value_labels[4]:
		_settings_value_labels[4].text = Global.font_option_label()


## 字体切换回调（Global.font_changed）：设置页里只重建设置行 —— 不能调
## _rebuild_menu_items()，它会把隐藏中的主菜单项 show() 回来。
func _on_global_font_changed(_font_path: String) -> void:
	if _in_settings:
		_clear_settings_ui()
		_build_settings_items()
		_refresh_settings_cursor()
	else:
		_rebuild_menu_items()
		_refresh_all()
	## ★左下角信息块的折行是按**当前字体**量的宽（zpix 比 fusion 宽 ~8%），
	## 不重建就会在换字体后重新压住菜单窗口（2026-09-30）。
	_build_footer_info()


func _refresh_settings_cursor() -> void:
	if not _cursor_frame:
		return
	var cur_h := _cursor_frame.size.y
	_cursor_frame.position.y = item_start_y + _settings_cursor_idx * _settings_row_step() + (item_height - cur_h) / 2.0 + cursor_offset_y
	_cursor_frame.size.x = _cursor_rect_w()
	_cursor_frame.position.x = _cursor_rect_x()


func _update_settings_volume_display(idx: int) -> void:
	var vol: int = Global.music_volume if idx == 0 else Global.sfx_volume
	if idx < _settings_value_labels.size() and _settings_value_labels[idx]:
		_settings_value_labels[idx].text = "%d%%" % vol
	if idx < _settings_bar_fill.size() and _settings_bar_fill[idx]:
		_settings_bar_fill[idx].size.x = SETTINGS_BAR_W * vol / 100.0


func _update_all_settings_volume_display() -> void:
	_update_settings_volume_display(0)
	_update_settings_volume_display(1)

func _go_to_network_lobby() -> void:
	const lobby_scene := "res://scene/network_lobby.tscn"
	print("[标题画面] 联机游戏 → 大厅")
	var err: Error = get_tree().change_scene_to_file(lobby_scene)
	if err != OK:
		printerr("[标题画面] 大厅场景切换失败: %s (err=%d)" % [lobby_scene, err])

func _go_to_campaign_select() -> void:
	## 2026-11-10 用户需求：单人选战役之前先选「游戏模式」（标准 / 计时竞速）。
	## 模式只影响表现与记账（计时器、竞速记录），战役/难度/角色流程完全不变。
	print("[标题画面] 开始游戏 → 游戏模式")
	if _mode_overlay != null:
		return
	_mode_overlay = GAME_MODE_MENU.new()
	add_child(_mode_overlay)
	_mode_overlay.connect("closed", _close_mode_menu)


func _close_mode_menu() -> void:
	if _mode_overlay == null:
		return
	_mode_overlay.queue_free()
	_mode_overlay = null


## 竞速记录（page=0）/ 游玩统计（page=1）。
func _open_records(page: int) -> void:
	if _records_overlay != null:
		return
	var menu: Control = RECORDS_MENU.new()
	menu.set("page", page)
	_records_overlay = menu
	add_child(menu)
	menu.connect("closed", _close_records)


func _close_records() -> void:
	if _records_overlay == null:
		return
	_records_overlay.queue_free()
	_records_overlay = null


func _quit_game() -> void:
	print("[标题画面] 退出游戏")
	get_tree().quit()
