class_name CombatHud extends CanvasLayer

## ── 架构定位 ──
## 系统：战斗 HUD ｜ 层：表现（CanvasLayer）
## 联机：跟随本地玩家
## 职责：战斗 HUD：左上 HP 条与急救喷雾数量、右上主副武器图标，并承载防守战倒计时面板。
## 依赖：art/Ui 素材、PlayerState、HoldoutMachine

## 战斗 HUD — 左上：HP 框 + HP 填充（横缩放）+ 急救喷雾数量；右上：主/副武器图标
##
## 每个 UI 图都是一个 TextureRect 子节点，可在编辑器里直接拖动改位置。
##
## 【防守战倒计时】本节点同时承载防守战倒计时（见文件末尾「防守战倒计时」区块）。
## 倒计时作为 combat_hud.tscn 内的持久子节点 HoldoutCountdown（PanelContainer 树）存在，
## 在编辑器里可直接看到并拖动定位；默认 hidden，由 show_holdout() 在防守战开始时显示。
## 它自动继承本 HUD 的 layer（10）与生命周期：换图时随地图内的 CombatHUD 一起释放，
## 不会残留悬空的 UI 层。查找方式：本节点在 _ready() 加入 "combat_hud" 组。

## 供 HoldoutMachine / NetworkWorld 查找本场景的 CombatHUD。
## 地图里每张图都实例化了 scene/ui/combat_hud.tscn，因此正常只有一个。
const GROUP_NAME: StringName = &"combat_hud"

## 弹药/投掷物数字字体：跟随「设置 → 界面字体」（2026-09-24，12px 基底，字号 36=12×3）。
## 若缺 ∞ 字形（无限备弹符号），回退到 DotGothic16 补齐 —— 这是**只为特殊字形**保留的
## 自定义兜底字体：它本身缺 506/1733 常用字，绝不能当界面字体用。
const AMMO_FONT_FALLBACK_PATH: String = "res://art/System/DotGothic16-Regular.ttf"

const SPRAY_TEXTS: Array[Texture2D] = [
	preload("res://art/Ui/回復薬×０.png"),
	preload("res://art/Ui/回復薬×１.png"),
	preload("res://art/Ui/回復薬×２.png"),
	preload("res://art/Ui/回復薬×３.png"),
	preload("res://art/Ui/回復薬×４.png"),
	preload("res://art/Ui/回復薬×５.png"),
	preload("res://art/Ui/回復薬×６.png"),
	preload("res://art/Ui/回復薬×７.png"),
	preload("res://art/Ui/回復薬×８.png"),
	preload("res://art/Ui/回復薬×９.png"),
	preload("res://art/Ui/回復薬×１０.png"),
	preload("res://art/Ui/回復薬×１１.png"),
	preload("res://art/Ui/回復薬×１２.png"),
	preload("res://art/Ui/回復薬×１３.png"),
	preload("res://art/Ui/回復薬×１４.png"),
	preload("res://art/Ui/回復薬×１５.png"),
]

@onready var hp_frame: TextureRect = $HPFrame
@onready var hp_fill: TextureRect = $HPFill
@onready var spray_count: TextureRect = $SprayCount
@onready var primary_icon: TextureRect = $PrimaryWeaponIcon
@onready var secondary_icon: TextureRect = $SecondaryWeaponIcon
@onready var tp_label: GradientLabel = $TPLabel
@onready var primary_ammo_label: Label = $PrimaryAmmoLabel
@onready var secondary_ammo_label: Label = $SecondaryAmmoLabel
@onready var throwable_icon: TextureRect = $ThrowableIcon
@onready var throwable_count_label: Label = $ThrowableCountLabel
@onready var support_icon: TextureRect = $SupportIcon

var _last_tp: int = -1


func _ready() -> void:
	layer = 10
	add_to_group(GROUP_NAME)
	# 倒计时默认隐藏：编辑器里它可见便于预览，运行时先收起，待 show_holdout() 再显示
	if is_instance_valid(_holdout_root):
		_holdout_root.visible = false
	_configure_tp_label()
	_apply_ammo_font()
	## 字体切换时重建弹药标签字体（本 HUD 的标签带 ∞ 兜底链，不能走整树字体重套）
	if Global.has_signal("font_changed") and not Global.font_changed.is_connected(_on_global_font_changed):
		Global.font_changed.connect(_on_global_font_changed)
	# HP 填充用 scale.x 横向缩放（配合 HPFill expand_mode=IGNORE_SIZE 自动贴合纹理）
	refresh()


## 给弹药标签挂上带 ∞ 回退的字体（一次性构造，见 AMMO_FONT_FALLBACK_PATH 注释）。
## 基字体跟随「设置 → 界面字体」；字体切换时由 _on_global_font_changed 重建。
func _apply_ammo_font() -> void:
	var base := Global.get_ui_font() if Global.has_method("get_ui_font") else null
	if base == null:
		return
	var out := base.duplicate() as FontFile
	if out == null:
		return
	var fallback := load(AMMO_FONT_FALLBACK_PATH) as FontFile
	if fallback:
		out.fallbacks = [fallback]
	for label: Label in [primary_ammo_label, secondary_ammo_label, throwable_count_label]:
		if label:
			## 标记为「自定义字体」：Global 的整树字体重套会跳过它们，
			## 由本文件自己在 font_changed 时重建（否则会丢掉 ∞ 的 fallbacks 链）。
			label.set_meta(&"ui_font_custom", true)
			label.add_theme_font_override("font", out)


## 字体切换：重建弹药标签字体（基字体换成新选项，∞ 兜底链保持不变）。
func _on_global_font_changed(_font_path: String) -> void:
	_apply_ammo_font()


func _process(delta: float) -> void:
	refresh()
	_tick_holdout(delta)


func refresh() -> void:
	_update_hp()
	_update_tp()
	_update_spray()
	_update_weapons()
	_update_consumables()


func _update_hp() -> void:
	var state: PlayerState = Players.get_active_state()
	var hp: float = state.current_hp
	var max_hp: float = state.get_max_hp()
	var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
	if hp_fill:
		hp_fill.scale = Vector2(ratio, 1.0)


func _configure_tp_label() -> void:
	# TP 数值标签（场景节点 $TPLabel）—— 与伤害数字同款像素字体
	# 资源路径/位置在场景里设置；字号和效果属性在代码里设置（_ready 阶段覆盖 _enter_tree 的 Global 默认值）
	# 字号铁律 12 的整数倍（2026-09-24 用户确认）：32 非整倍 → 像素字体非整数缩放会糊，改 36=12×3
	tp_label.text_font_size = 36
	tp_label.color_index = 1
	tp_label.color_row = 0
	tp_label.bold = false
	tp_label.shadow = true
	tp_label.shadow_color = Color(0, 0, 0, 1)
	tp_label.shadow_offset = Vector2(2, 2)
	tp_label.outline = false


func _update_tp() -> void:
	var state: PlayerState = Players.get_active_state()
	var tp: int = state.current_tp
	if tp != _last_tp:
		_last_tp = tp
		tp_label.text = "%d" % tp


func _update_spray() -> void:
	# 单机=队伍共用池总数；联机=本地玩家自己的喷雾槽位（2026-09-24 用户定稿）。
	# 不要改回 spray_total()：联机那是各座位求和，客户端会显示主机的数量而自己恒 0。
	var total: int = Players.spray_display_count()
	var n: int = clampi(total, 0, SPRAY_TEXTS.size() - 1)
	if spray_count:
		spray_count.texture = SPRAY_TEXTS[n]
		spray_count.size = SPRAY_TEXTS[n].get_size()


func _update_weapons() -> void:
	var state: PlayerState = Players.get_active_state()
	var primary: WeaponData = state.get_equipped_weapon("primary")
	var secondary: WeaponData = state.get_equipped_weapon("secondary")
	if primary_icon:
		if primary and primary.icon:
			primary_icon.texture = primary.icon
			primary_icon.size = primary.icon.get_size()
			primary_icon.visible = true
		else:
			primary_icon.visible = false
	if secondary_icon:
		if secondary and secondary.icon:
			secondary_icon.texture = secondary.icon
			secondary_icon.size = secondary.icon.get_size()
			secondary_icon.visible = true
		else:
			secondary_icon.visible = false
	_update_ammo_label(primary_ammo_label, primary, state)
	_update_ammo_label(secondary_ammo_label, secondary, state)


## 武器图标上的「弹夹/备弹」显示；近战等无弹夹武器（magazine_capacity=0）隐藏。
## 备弹无限（WeaponData.ammo_is_infinite，如手枪）显示「弹夹/∞」。
func _update_ammo_label(label: Label, weapon: WeaponData, state: PlayerState) -> void:
	if not label:
		return
	if weapon == null or weapon.magazine_capacity <= 0:
		label.visible = false
		return
	var mag: int = state.get_magazine_ammo(weapon.item_id)
	if weapon.ammo_is_infinite:
		label.text = "%d/∞" % mag
	else:
		label.text = "%d/%d" % [mag, state.count_ammo_item(weapon.ammo_item_id)]
	label.visible = true


## 投掷物 / 辅助品图标：持有对应物品时显示其 icon，位于副武器图标列下方。
func _update_consumables() -> void:
	var state: PlayerState = Players.get_active_state()
	_set_item_icon(throwable_icon, state.throwable)
	_set_item_icon(support_icon, state.support_item)
	_update_throwable_count(state)


## 投掷物数量：与弹药标签同款（ark-pixel + 阴影，见 _apply_ammo_font），
## 显示在投掷物图标正下方（combat_hud.tscn 里可拖动定位）。无投掷物时隐藏。
func _update_throwable_count(state: PlayerState) -> void:
	if not throwable_count_label:
		return
	if state.throwable and state.throwable_count > 0:
		throwable_count_label.text = "×%d" % state.throwable_count
		throwable_count_label.visible = true
	else:
		throwable_count_label.visible = false


func _set_item_icon(rect: TextureRect, item: ItemData) -> void:
	if not rect:
		return
	if item and item.icon:
		rect.texture = item.icon
		rect.visible = true
	else:
		rect.texture = null
		rect.visible = false


# ═══════════════════════════════════════════════════════════════
# 防守战倒计时
# ═══════════════════════════════════════════════════════════════
#
# 阶段（与 HoldoutMachine.Phase 一致，通过 int 传递以便跨 RPC）：
#   0 = IDLE（隐藏）  1 = PREPARE（准备）  2 = ACTIVE（进行）  3 = SETTLE（结算）
#
# 三个入口（操作 combat_hud.tscn 内持久存在的 HoldoutCountdown 节点树）：
#   show_holdout()                         —— 开场，显示节点（外观以 combat_hud.tscn 编辑器设置为准）
#   update_holdout(phase, remaining, total) —— 权威刷新（单机由机器直接调用；
#                                              联机由 NetworkWorld 收到 Host 广播后调用）
#   hide_holdout()                          —— 收场，隐藏并复位（节点持久存在、复用）
#
# 【防漂移】update_holdout 传入的 remaining 是权威值，调用时立即覆盖本地值；
# 两次权威包之间由 _tick_holdout 本地递减，仅用于让数字平滑跳动。
# 因此本地计时误差永远不会累积，最多为一个广播间隔内的插值偏差。

## 倒计时根节点（combat_hud.tscn 内的持久子节点 HoldoutCountdown 树）。
## 在编辑器里直接可见、可拖动定位；默认 hidden，由 show_holdout() 在防守战开始时显示。
## 继承自本 CanvasLayer 的 layer（10），随地图内 CombatHUD 一起释放，不会残留。
@onready var _holdout_root: PanelContainer = $HoldoutCountdown
@onready var _holdout_margin: MarginContainer = $HoldoutCountdown/Margin
@onready var _holdout_vbox: VBoxContainer = $HoldoutCountdown/Margin/VBox
@onready var _holdout_title: Label = $HoldoutCountdown/Margin/VBox/TitleLabel
@onready var _holdout_time: GradientLabel = $HoldoutCountdown/Margin/VBox/TimeLabel
@onready var _holdout_message: Label = $HoldoutCountdown/Margin/VBox/MessageLabel

## 阶段标题 / 告警行为等「非排版」参数放在本 HUD 节点上编辑（与 HoldoutMachine 无关）。
## 排版类（位置、字号、颜色、背板、内边距）一律在 combat_hud.tscn 里直接改节点。
@export var holdout_title_prepare: String = "准备防守"
@export var holdout_title_active: String = "防守剩余"
@export var holdout_title_settle: String = "防守成功"
@export_range(0.0, 120.0, 1.0) var holdout_warning_threshold: float = 10.0  ## 剩余多少秒进入告警（0=关闭）
@export var holdout_warning_blink: bool = true                             ## 告警时闪烁
@export var holdout_show_minutes: bool = true                              ## true="1:05"，false="65"

## 倒计时数字配色：与 TP 同为色表固定色，切换色表索引即可。
const HOLDOUT_COLOR_NORMAL: int = 1    ## 正常态（与 TP 同款近白）
const HOLDOUT_COLOR_WARNING: int = 10  ## 告警态（色表红色系）

## 运行时状态
var _holdout_visible: bool = false
var _holdout_phase: int = 0
var _holdout_remaining: float = 0.0
var _holdout_total: float = 0.0
var _holdout_blink_phase: float = 0.0
var _holdout_last_shown_text: String = ""
var _holdout_color_index: int = -1      ## 当前已应用的配色索引（避免每帧重渲）
var _holdout_message_timer: float = 0.0  ## 提示语（MessageLabel）淡出计时（当前完成事件未用，保留以防扩展）


## 开始一场防守战的 UI 展示。重复调用是幂等的：只显示节点，不会叠加（解决"重复叠加"边界）。
## 不再接收任何外观配置 —— 位置/字号/颜色/背板/提示语一律以 combat_hud.tscn 里
## HoldoutCountdown 节点的编辑器设置为准，所见即所得。
func show_holdout() -> void:
	_holdout_color_index = -1   # 强制下次刷新重新应用配色索引
	_holdout_visible = true
	_holdout_root.visible = true
	_holdout_root.modulate.a = 1.0


## 权威刷新。phase/remaining/total 均来自权威端（单机=本机，联机=Host）。
func update_holdout(phase: int, remaining: float, total: float) -> void:
	if phase <= 0:
		hide_holdout()
		return
	if not _holdout_visible:
		# 中途加入 / 断线重连：先收到状态包但还没收到 show_holdout，直接补显示，
		# 避免这些玩家看不到倒计时。
		show_holdout()
	_holdout_phase = phase
	_holdout_remaining = maxf(remaining, 0.0)
	_holdout_total = maxf(total, 0.0)
	_refresh_holdout_labels()


## 结束展示。节点保留但隐藏，供同一张图内的下一台机器复用。
func hide_holdout() -> void:
	_holdout_visible = false
	_holdout_phase = 0
	_holdout_remaining = 0.0
	_holdout_total = 0.0
	_holdout_blink_phase = 0.0
	_holdout_last_shown_text = ""
	_holdout_color_index = -1
	if is_instance_valid(_holdout_root):
		_holdout_root.visible = false
		_holdout_root.modulate.a = 1.0


func is_holdout_visible() -> bool:
	return _holdout_visible


## 每帧本地插值 + 提示语淡出 + 告警闪烁。不改变权威值的语义，只做平滑显示。
func _tick_holdout(delta: float) -> void:
	if not _holdout_visible or not is_instance_valid(_holdout_root):
		return

	# 本地递减只用于让数字平滑；下一个权威包到达即被覆盖。
	# 无计量模式（total<=0，HoldoutMachine EXTERNAL 永续型）不递减，数字保持权威值。
	if (_holdout_phase == 1 or _holdout_phase == 2) and _holdout_total > 0.0:
		_holdout_remaining = maxf(_holdout_remaining - delta, 0.0)

	if _holdout_message_timer > 0.0:
		_holdout_message_timer -= delta
		if _holdout_message_timer <= 0.0 and is_instance_valid(_holdout_message):
			_holdout_message.visible = false

	# 告警闪烁只在"进行中"阶段生效；准备/结算阶段保持稳定不闪。
	var should_warn: bool = _holdout_phase == 2 and holdout_warning_threshold > 0.0 and _holdout_remaining <= holdout_warning_threshold
	if should_warn and holdout_warning_blink:
		_holdout_blink_phase += delta * 8.0
		_holdout_root.modulate.a = 0.55 + 0.45 * absf(sin(_holdout_blink_phase))
	else:
		_holdout_blink_phase = 0.0
		_holdout_root.modulate.a = 1.0

	_refresh_holdout_labels()


func _refresh_holdout_labels() -> void:
	if not is_instance_valid(_holdout_time):
		return

	# ── 始终只显示数字（用户 2026-09-13）：标题（准备防守/防守剩余等）与提示语不再显示，
	#    数字单行。SETTLE 无数字可显 → 整个面板收起（避免空背板挂着）。
	if is_instance_valid(_holdout_title):
		_holdout_title.visible = false
	if is_instance_valid(_holdout_message):
		_holdout_message.visible = false

	if _holdout_phase == 3:
		_holdout_time.visible = false
		if is_instance_valid(_holdout_root):
			_holdout_root.visible = false
		return
	## 无计量模式（HoldoutMachine EXTERNAL 永续型：无计时无击杀目标）→ 面板收起
	if _holdout_remaining <= 0.0 and _holdout_total <= 0.0:
		if is_instance_valid(_holdout_root):
			_holdout_root.visible = false
		return
	if is_instance_valid(_holdout_root):
		_holdout_root.visible = true
	_holdout_time.visible = true

	var text: String = _format_holdout_time(_holdout_remaining)
	if text != _holdout_last_shown_text:
		_holdout_last_shown_text = text
		_holdout_time.text = text

	# ── 倒计时数字配色：色表索引切换，警告态切到红色系 ──
	var warn: bool = _holdout_phase == 2 and holdout_warning_threshold > 0.0 and _holdout_remaining <= holdout_warning_threshold
	var time_index: int = HOLDOUT_COLOR_WARNING if warn else HOLDOUT_COLOR_NORMAL
	if is_instance_valid(_holdout_time) and time_index != _holdout_color_index:
		_holdout_color_index = time_index
		_holdout_time.color_index = time_index   # 仅索引变化时触发 GradientLabel 重渲


func _format_holdout_time(seconds: float) -> String:
	var total_sec: int = int(ceilf(seconds))
	if holdout_show_minutes:
		return "%d:%02d" % [total_sec / 60, total_sec % 60]
	return str(total_sec)


# ── 静态查找 ─────────────────────────────────────────────

## 在当前场景里找 CombatHUD。地图内已实例化的那一个会通过 "combat_hud" 组自动登记。
static func find_in_scene(from: Node) -> CombatHud:
	if not from or not from.is_inside_tree():
		return null
	var nodes: Array[Node] = from.get_tree().get_nodes_in_group(GROUP_NAME)
	for node: Node in nodes:
		var hud := node as CombatHud
		if is_instance_valid(hud):
			return hud
	return null
