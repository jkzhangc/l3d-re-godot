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


const MENU_ITEMS: Array[String] = ["开始游戏", "联机游戏", "操作说明", "成就", "设置", "退出游戏"]
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
	var out: Array[String] = ["音乐音量", "音效音量", "固定朝向", "文字居中", "界面字体"]
	if Global.is_mobile_platform():
		out.append("按键布局")
	out.append("返回")
	return out
## 设置页窗口尺寸（2026-09-14）：音量条/数值标签比菜单项宽，进设置时窗口加宽、退出还原
const SETTINGS_WINDOW_SIZE: Vector2 = Vector2(520, 336)


## 设置窗实际尺寸。移动端多一行「按键布局」→ 加高一点：
## `_settings_row_step()` 会把行距压到 `avail / 行数`，7 行时压到 ~42px，
## 和 32px 字号 + 光标框打架（2026-09-30）。
func _settings_window_size() -> Vector2:
	return Vector2(520.0, 392.0 if Global.is_mobile_platform() else 336.0)
## 音量条宽度——背景条与填充条必须同宽（旧版填充刷新写死 80、背景 160，
## 填充永远只有背景一半长，2026-09-15 用户截图复现）
const SETTINGS_BAR_W: float = 160.0
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

func _ready() -> void:
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
	_base_window_size = window_size
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

const CHANGELOG_VERSION_TEXT := "v0.32（2026-10-01 ~ 10-03）"
## 更新日志正文字号（12 整数倍铁律）。★折行量宽与建行必须用同一个值（`_wrap_text_to_width`）。
const CHANGELOG_FONT_SIZE: int = 24

## ⚠ CHANGELOG_VERSION_TEXT 是「本版已看过」的判据（`Global.changelog_seen_version`）：
## 改了它 → 玩家下次启动会**自动弹一次**更新日志。所以每次发版必须换新字符串。
const CHANGELOG_BODY := """【新内容】
· 必杀（背刺）：绕到敌人背后攻击，可以直接秒杀普通敌人
  Boss 免疫秒杀，但会吃到更高的伤害
  潜行接近「还没发现你」的敌人时，从哪个方向都能发动
· 成就系统：标题画面新增「成就」入口，能看到全部成就与进度
  通关后在制作人员名单之前，会展示这一局解锁的成就
  联机时还能看到队友都拿了哪些成就
· 报错界面：游戏出错时会自动暂停并显示报错详情
  同时在游戏目录生成报错文件（l3d_error_log.txt）
  请把这个文件发到交流群里，方便我们定位问题
· 被敌人挤进墙里 / 屋顶出不来时，角色会自己脱困（不用重开）

【调整】
· 爆炸范围全面调整：榴弹系 96 → 64、火箭筒 240 → 96、手雷 80 → 48
· 火箭筒的爆炸动画换成新版
· 步枪与冲锋枪现在能打出暴击（暴击时伤害更高）
· 单人难度会影响刷怪数量：简单 0.5 / 普通 0.75 / 困难 1 / 专家 1.25 倍
  多人模式只按人数缩放，不受难度影响
· 联机延迟继续优化：网络稳定时远端角色更跟手
  （最差情况也压在 70 毫秒以内）
· 敌人死亡时会按概率掉落物品，越强的敌人掉得越好
· 掉落池加入新武器：弩、平底锅、金属球棒、酸性 / 冰结 / 电击榴弹
· 调试模式（TAB 键）里，爆炸会显示实际范围，方便调参
· 霰弹枪备弹 200 → 300 发
· 街道路口、学校走廊、矿洞三张图的普通刷怪间隔调稀（不再一进图就冒出一堆）
· 靠近拾取物 / 防守战机器 / 门时的那行提示文字放大一倍（手机上也能看清了）
· 拾取 / 替换武器的按键小标签、传送点的「前进」提示保持小字（跟着放大反而太抢眼）

【修复】
· 敌人被打死时偶尔没有死亡音效
· 敌人死亡掉落偶发报错
· 部分武器在不同角色身上的枪口位置与特效偏移不统一
· 标题画面菜单文字排列不齐
· 联机大厅的端口输入框显示不全（手机与电脑都有）
· 队友全灭后尸潮还在继续、尸潮音乐停不下来
· 把枪丢在地上再捡回来，子弹会回满（现在会保留剩余弹药）
· 防守战机器有时按了没反应、启动不了
· 打完一局回到标题画面后，尸潮音乐还在继续播
· 回到标题再开新局，一出安全屋就直接爆发尸潮，而且丧尸全是狂暴形态
· 玩家死亡一次后，急救喷雾再也用不了（数量还在扣却没效果）
· 举着武器时更换武器，换完之后角色行走图对不上
· 开房间时「UPnP 映射失败」的提示不再被当成报错弹窗
· 联机打完一局后重开房，换了角色却还是上一把的角色、血量和武器
· 回到标题画面后会清掉上一局的进度，不会自动读档回到上次的安全屋
· 不举起武器时仍被强制固定朝向、无法转身
· 举枪定向移动时切换角色，新角色会一直保持固定朝向无法转身
· 显示成就的 3 秒结束后流程不继续（要按菜单键才行）
· 显示成就期间敌人还在继续攻击玩家
· 敌人互相挤会把同伴挤进墙里或屋顶里出不来了
· 资源加载失败之类不影响玩法的报错不再弹窗打断（仍会写进报错文件）

──────────────  v0.31（2026-09-29 ~ 09-30）  ──────────────

【手机版 · 本次重点】
· 新增「按键布局」：设置里可自由拖动虚拟摇杆和所有按键的位置，
  用不到的按键还能收起来（调整完点「保存」才生效）
· 补齐三个缺失的触摸按键：「举枪」「慢走」「觉醒」—— 以前在手机上没法操作
· 按键提示全部改成手机上的按钮名（以前写「按 D」「按 Shift」，手机玩家找不到）
· 联机时举不起武器已修复：手机上按「主武器」按钮能正常举枪 / 收枪
· 多个按键同时按不再失灵（以前按住摇杆时其它按键点不动）
· 按键的触发位置与看到的按钮对齐了（以前要按在旁边空白处），画面上下拉伸也修好了
· 720p 手机画面被裁掉一块的问题已修复，现在按屏幕自动适配
· 手机上改的设置不再丢失（以前退出游戏就还原）
· 关卡里打开暂停菜单 / 安全屋台词时，按键不再被窗口盖住
· 结算界面的按钮不会再被挡住

【新内容】
· 尸潮开始前会有一次预警音效，听到就知道要来了
· 多人模式左下角显示网络延迟（ms）：当客户端时看自己到主机的延迟，
  当主机时看各客户端里最差的一条 —— 卡不卡一眼就能分清是网络还是机器
· 防守战机器新增「防守战结束音效」（默认开锁音），每台机器都能单独换

【修复】
· 敌人死亡音效有时不播放
· 标题画面左下角的文字会压住选项窗口
· 空手对着武器按功能键捡不起来（现在和替换武器的手感一致）
· 满血时用急救喷雾会白消耗一瓶（现在满血不再消耗）
· 防守战刚开始（预备阶段）附近的丧尸就被切成狂暴形态
· 「返回标题画面」偶发的报错
· HUD 弹药数字周围出现零散白点（手机端上一版仍未修好，这次一并修掉了）
· 手机端进入「设置」后虚拟按键全部失效 —— 摇杆推不动、确定/取消点不动、退不出去
· 矿洞里可以炸的墙炸开后没有爆炸音效

【调整】
· 弹夹打空但还有备弹时会自动换弹，不用再手动按装填键
· 真的把子弹打光时，扣扳机有音效了
· 「退出游戏」改为「返回标题画面」
· 联机当主机时每秒数百次的重复计算已清理（长时间联机会更稳；性能还会继续优化）

──────────────  v0.30（2026-09-18 ~ 09-28）  ──────────────

【新内容】
· 手机版支持：画面自动适配手机屏幕（像素画质不打折扣）
  左下虚拟摇杆 + 右下「动作 / 物品 / 系统」三组触摸按钮
· 角色台词：进入安全屋时会说出当前角色的专属台词（带头像与名字）
· 画面氛围色调：部分场景加入气氛色调，夜晚与室内更有味道
· 联机内容大幅补齐 —— 两端的画面与声音终于完全一致：
  · 特感、丧尸变体、敌人音效、命中特效全部同步
  · 觉醒、SA 技能、见切与反击在联机下可用
  · 被吞、倒地、救援、尸体表现两端一致
  · 尸潮与 Boss 战的音乐两端一致
· 联机大厅改版：拆成「大厅 / 房间」两级界面，在房间里就能直接选章节
· 静香加入可选角色（联机也能选）

【修复】
· 联机开局没有备弹；替换武器时捡不起来
· 联机治疗品不同步；急救喷雾「按 3 用不了」
· 联机时丧尸盖住玩家；掉落物周期性消失、掉进墙里捡不到
· 联机特感攻击动画显示错图；被吞的玩家仍能移动
· 多人时前方补怪反而比单人少
· 多人出生点卡在墙里
· 手枪备弹显示为无限（实际会打完）
· 终章结算：客户端点不了准备、名单少算自己、音乐重叠
· 联机大厅标题与新窗口标题重叠
· 防守战机器有时整台看不见
· 队友倒下后尸体会挡住你和敌人（现在可以直接穿过去）
· 中弹着火后不掉血，也看不到火焰
· 见切成功时没有「无效」提示
· 倒地救援偶尔会被打断，救人的进度直接消失
· 丢在地上的武器会被自己马上捡回来
· 刚进图时敌人会刷在脸上；切换安全屋偶尔会卡住
· 部分角色拿枪的走路姿势不对（例如胖虎拿狙击枪）

【调整】
· 刷怪随人数缩放：3 人 1.5 倍、4 人 2 倍，同屏上限同步提高
· 尸潮改为「持续一段时间的连续压制」，不再一次性放完
· Tank 只能用爆炸物（手雷 / RPG）打断
· 防守战改用固定刷怪点，敌人不再从屏外乱刷
· 敌人挤在一起时不再互相加速（被围住不会突然变快）
· 开场立刻进入战斗，不再有开局空窗期
· 路障、护栏、立柱不再是「看着挡路、实际能穿」——敌人不会再从里面挤过去
· 急救喷雾在联机里改成每人各带一份：自己捡、自己用，不会被队友拿走
· 医疗箱在联机里每人各能用一次，而且只治自己，用过的箱子会变暗
· 静香暂时无法使用狙击枪（专属行走图尚未完成）
· 界面字体换新，中文显示更完整
· 地图细节补完：部分场景补画装饰与安全屋标识"""


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


func _open_update_log() -> void:
	if _update_log_panel != null:
		return
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

	if event.is_action_pressed("确定键"):
		Global.play_ui_sfx("confirm", sfx_confirm_path)
		_confirm()
		return

	var item_count: int = MENU_ITEMS.size()
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
	for item: String in MENU_ITEMS:
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
	win.position = Vector2(
		(get_viewport_rect().size.x - window_size.x) / 2.0,
		(960.0 - window_size.y) / 2.0 + window_y_offset
	)
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
	var start_y: float = separator_y + item_title_gap if show_title else item_start_y
	var avail_h: float = window_size.y - start_y - item_margin_bottom
	var row_step: float = item_height + item_spacing
	_visible_items = clampi(int(avail_h / row_step), 1, MENU_ITEMS.size())

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
		item_start_y + _visible_items * row_step + 4)
	_create_scroll_arrow(win, arrow_up_path, "ScrollArrowUp",
		item_start_y - 16)


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
	var end_idx: int = mini(_scroll_offset + _visible_items, MENU_ITEMS.size())
	for i: int in range(MENU_ITEMS.size()):
		if i >= _menu_item_labels.size():
			break
		var gl: GradientLabel = _menu_item_labels[i]
		## ★ 文本与位置**一律**设置（含被滚动隐藏的项）：隐藏项若保留上一次的 y，
		## 滚动回来时就会与相邻可见项同 y 叠放（2026-10-02 布局用例抓到）。
		## 显隐统一放在最后一行赋值。
		var display_idx: int = i - _scroll_offset
		# 居中模式去掉 "  " 前缀空格——否则量宽连空格一起居中，文字整体右偏
		var item_text := MENU_ITEMS[i] if _is_centered() else "  %s" % MENU_ITEMS[i]
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
		_scroll_arrow_down.visible = (_scroll_offset + _visible_items < MENU_ITEMS.size())
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
	match MENU_ITEMS[_cursor_idx]:
		"开始游戏":
			_go_to_campaign_select()
		"联机游戏":
			_go_to_network_lobby()
		"操作说明":
			_go_to_controls_guide()
		"成就":
			_open_achievements()
		"设置":
			_enter_settings()
		"退出游戏":
			_quit_game()


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
	while _menu_item_labels.size() < MENU_ITEMS.size():
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


## 成就页脚本（**preload 常量而不是 class_name**：本项目 class_name 不进全局类缓存，
## 跨文件按名字引用会在 headless / 导出时报 Parse Error）。
const ACHIEVEMENTS_MENU := preload("res://script/ui/achievements_menu.gd")


# ═══════════════════════════════════════
# 设置面板
# ═══════════════════════════════════════

func _apply_window_size(s: Vector2) -> void:
	## 运行时改窗口尺寸（设置页加宽 / 退出还原）：窗口、RM 底图、九宫格框同步，
	## 并按新尺寸重新居中。
	window_size = s
	var win: Control = $MenuWindow
	win.position = Vector2(
		(get_viewport_rect().size.x - s.x) / 2.0,
		(960.0 - s.y) / 2.0 + window_y_offset
	)
	win.size = s
	if _window_bg:
		_window_bg.size = s
	if _window_frame:
		_window_frame.size = s


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
	_apply_window_size(_base_window_size)
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
	print("[标题画面] 开始游戏 → 战役选择")
	var err: Error = get_tree().change_scene_to_file(campaign_select_scene)
	if err != OK:
		printerr("[标题画面] 场景切换失败: %s (err=%d)" % [campaign_select_scene, err])


func _quit_game() -> void:
	print("[标题画面] 退出游戏")
	get_tree().quit()
