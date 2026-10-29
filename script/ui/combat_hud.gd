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
## ── 每帧刷新脏检查缓存（2026-10-08 性能）──
## refresh() 每帧都跑，但绝大多数帧只是打开菜单/移动、数值根本没变。旧实现每帧无条件：
## 重建弹药字符串（`"%d/%d" % [...]`）、给 TextureRect 重赋 texture+size、线性扫 inventory
## 数备弹。改为「值未变则跳过」，与 _last_tp 同款范式。显示结果完全一致。
var _last_hp_ratio: float = -1.0
var _last_spray_total: int = -1
var _last_primary_weapon: WeaponData = null
var _last_secondary_weapon: WeaponData = null
## 哨兵：真实弹药文本形如 "12/30" / "5/∞"，绝不可能等于该值。
const AMMO_TEXT_UNSET: String = "<unset>"
var _last_primary_ammo_text: String = AMMO_TEXT_UNSET
var _last_secondary_ammo_text: String = AMMO_TEXT_UNSET
var _last_throwable_item: ItemData = null
var _last_throwable_count: int = -1
var _last_support_item: ItemData = null
## 背包指示（仅小夫显示「背包 1/2」；普通角色隐藏）。
var _backpack_label: Label = null
## 首次刷新强制应用：场景里的图标节点预置了占位纹理（非空），若首帧缓存恰为 null 且当前值
## 也是 null，脏检查会判定"未变"而跳过 → 占位图残留（显示 bug）。首刷绕过所有脏检查。
var _force_refresh: bool = true


func _ready() -> void:
	layer = 10
	add_to_group(GROUP_NAME)
	# 倒计时默认隐藏：编辑器里它可见便于预览，运行时先收起，待 show_holdout() 再显示
	if is_instance_valid(_holdout_root):
		_holdout_root.visible = false
	_configure_tp_label()
	_apply_ammo_font()
	_ensure_backpack_label()
	_cache_action_hint_rows()
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
	var ammo_font := _make_crisp_copy(base, true)
	## 描边一律关掉：像素字体加描边等于在字形周围再糊一圈（用户报的就是"周围有像素点"）。
	for label: Label in [primary_ammo_label, secondary_ammo_label, throwable_count_label]:
		_apply_font_override(label, ammo_font)
	## 右下角操作提示也是 36px（12 的 3 倍），同样要「像素字体应有的样子」：
	## 2026-10-28 用户实测 C / S 曾显示成其它字形（数字）—— 与弹药数字当初「边缘零散白点」
	## 是同一类 36px 栅格化问题（共用字体 oversampling 跟随视口 + 分数缩放）。
	## ⚠ 这里**不带 ∞ 兜底链**：提示文字用不到 ∞，而 DotGothic16 的行高更大，
	## 带上会让每行高出 ~17px（面板整体变高一大截）。
	_crisp_ui_font = _make_crisp_copy(base, false)
	_apply_crisp_font_to_rows()


## 构造一份「像素字体应有的样子」的副本：关抗锯齿 / 次像素定位 / 钉 1:1 栅格化。
## with_ammo_fallback=true 时追加 ∞ 的 DotGothic16 兜底（仅弹药数字需要）。
func _make_crisp_copy(base: Font, with_ammo_fallback: bool) -> FontFile:
	var out := base.duplicate() as FontFile
	if out == null:
		return null
	if with_ammo_fallback:
		var fallback := load(AMMO_FONT_FALLBACK_PATH) as FontFile
		if fallback:
			## fallback 同样要关抗锯齿 + 次像素定位 + 钉 1:1 栅格化：
			## 否则 ∞ 这类走兜底的字形照样会在 36px 下渗出零散白点（2026-09-30 用户实测）。
			fallback.antialiasing = TextServer.FONT_ANTIALIASING_NONE
			fallback.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
			fallback.oversampling = 1.0
			out.fallbacks = [fallback]
	## duplicate() 出来的副本也要显式关一遍（基字体已在 Global.load_ui_font 里关过，
	## 但这里再做一次可保证「本标签的字体链」整体干净）。
	## ⚠ `oversampling` 是手机端残留白点的关键项：移动端是分数缩放，留 0（跟随视口）
	## 会让字形被按 1.125 倍栅格化再缩回 36px → 边缘零散白点。
	out.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	out.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	out.oversampling = 1.0
	return out


## 把字体套到 Label 上，并标记 `ui_font_custom`：Global 的整树字体重套会跳过它，
## 由本文件在 font_changed 时重建（否则会丢掉兜底链，或把字体换回共用实例）。
func _apply_font_override(label: Label, font: FontFile) -> void:
	if label == null or font == null:
		return
	label.set_meta(&"ui_font_custom", true)
	label.add_theme_font_override("font", font)
	label.add_theme_constant_override("outline_size", 0)


func _apply_crisp_font(label: Label) -> void:
	_apply_font_override(label, _crisp_ui_font)


func _apply_crisp_font_to_rows() -> void:
	for row: Array in _hint_rows:
		_apply_crisp_font(row[0])
		_apply_crisp_font(row[1])


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
	_update_remote_bars()
	_update_action_hints()
	_force_refresh = false


func _update_hp() -> void:
	if hp_fill == null:
		return
	var state: PlayerState = Players.get_active_state()
	var hp: float = state.current_hp
	var max_hp: float = state.get_max_hp()
	var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
	if _force_refresh or ratio != _last_hp_ratio:
		_last_hp_ratio = ratio
		hp_fill.scale = Vector2(ratio, 1.0)


func _configure_tp_label() -> void:
	# TP 数值标签（场景节点 $TPLabel）—— 与伤害数字同款像素字体
	# 资源路径/位置在场景里设置；字号和效果属性在代码里设置（_ready 阶段覆盖 _enter_tree 的 Global 默认值）
	# 字号铁律 12 的整数倍（2026-09-24 用户确认）：32 非整倍 → 像素字体非整数缩放会糊，改 36=12×3
	# ★2026-10-03 用户实测「UI 字体多出几个像素点」：根因是节点曾用 `scale = 1.5`
	#   （非整数缩放像素字体 → 笔画粗细不均、边缘出杂点）。现改为 **scale = 1 + 字号 48**（=12×4），
	#   视觉尺寸与原 `36 × 1.5 = 54` 接近，且是 1:1 硬边栅格化，不再渗点。
	#   ⚠ 今后任何 HUD 文字都**不要用非整数 scale 放大**，要放大就放大字号（取 12 的整倍）。
	tp_label.text_font_size = 48
	tp_label.color_index = 1
	tp_label.color_row = 0
	tp_label.bold = false
	tp_label.shadow = true
	tp_label.shadow_color = Color(0, 0, 0, 1)
	tp_label.shadow_offset = Vector2(2, 2)
	tp_label.outline = false


func _update_tp() -> void:
	var state: PlayerState = Players.get_active_state()
	## ★显示前再钳一次（数据层已有 set_tp 唯一入口，这里兜底）：
	##   HUD 是最终门面，绝不允许出现超过上限的数字（用户实测「默认 TP 显示 133」）。
	var tp: int = state.current_tp
	var mx: int = state.get_max_tp()
	if mx > 0:
		tp = clampi(tp, 0, mx)
	if tp != _last_tp:
		_last_tp = tp
		tp_label.text = "%d" % tp


func _update_spray() -> void:
	# 单机=队伍共用池总数；联机=本地玩家自己的喷雾槽位（2026-09-24 用户定稿）。
	# 不要改回 spray_total()：联机那是各座位求和，客户端会显示主机的数量而自己恒 0。
	var total: int = Players.spray_display_count()
	var n: int = clampi(total, 0, SPRAY_TEXTS.size() - 1)
	if spray_count and (_force_refresh or n != _last_spray_total):
		_last_spray_total = n
		spray_count.texture = SPRAY_TEXTS[n]
		spray_count.size = SPRAY_TEXTS[n].get_size()


func _update_weapons() -> void:
	var state: PlayerState = Players.get_active_state()
	var primary: WeaponData = state.get_equipped_weapon("primary")
	var secondary: WeaponData = state.get_equipped_weapon("secondary")
	## 图标脏检查：只有"当前武器对象变化"才重赋 texture/size（武器引用不变 → 图标必不变）。
	if primary_icon and (_force_refresh or primary != _last_primary_weapon):
		_last_primary_weapon = primary
		if primary and primary.icon:
			primary_icon.texture = primary.icon
			primary_icon.size = primary.icon.get_size()
			primary_icon.visible = true
		else:
			primary_icon.visible = false
	if secondary_icon and (_force_refresh or secondary != _last_secondary_weapon):
		_last_secondary_weapon = secondary
		if secondary and secondary.icon:
			secondary_icon.texture = secondary.icon
			secondary_icon.size = secondary.icon.get_size()
			secondary_icon.visible = true
		else:
			secondary_icon.visible = false
	_update_ammo_label(primary_ammo_label, primary, state, true)
	_update_ammo_label(secondary_ammo_label, secondary, state, false)
	_update_backpack_label(state)


## 小夫的第二背包指示（2026-10-29）。普通角色完全不显示，避免多出一个无意义标签。
func _ensure_backpack_label() -> void:
	if _backpack_label != null:
		return
	_backpack_label = Label.new()
	_backpack_label.name = "BackpackLabel"
	_backpack_label.position = Vector2(760, 28)
	_backpack_label.size = Vector2(160, 36)
	_backpack_label.z_index = 3
	_backpack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_backpack_label.add_theme_font_size_override("font_size", 24)
	_backpack_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.55))
	_backpack_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	_backpack_label.add_theme_constant_override("shadow_offset_x", 2)
	_backpack_label.add_theme_constant_override("shadow_offset_y", 2)
	if _crisp_ui_font != null:
		_backpack_label.add_theme_font_override("font", _crisp_ui_font)
	_backpack_label.visible = false
	add_child(_backpack_label)


func _update_backpack_label(state: PlayerState) -> void:
	if _backpack_label == null:
		return
	## 联机 Client 的 backpack_index 不在快照里（只同步当前背包的两把武器），
	## 显示「背包 1/2」可能与 Host 实际不符 → 只在单机 / Host 显示。
	var online: bool = Net != null and Net.has_method("has_network") and bool(Net.has_network())
	var show: bool = state != null and state.has_second_backpack() and (not online or Net.is_host)
	_backpack_label.visible = show
	if show:
		_backpack_label.text = "背包 %d/2" % (state.backpack_index + 1)


## 武器图标上的「弹夹/备弹」显示；近战等无弹夹武器（magazine_capacity=0）隐藏。
## 备弹无限（WeaponData.ammo_is_infinite，如手枪）显示「弹夹/∞」。
## `is_primary` 决定脏检查用哪一份缓存（两把武器各自独立）。
func _update_ammo_label(label: Label, weapon: WeaponData, state: PlayerState, is_primary: bool) -> void:
	if not label:
		return
	var last_text: String = _last_primary_ammo_text if is_primary else _last_secondary_ammo_text
	if weapon == null or weapon.magazine_capacity <= 0:
		if last_text != "":
			if is_primary:
				_last_primary_ammo_text = ""
			else:
				_last_secondary_ammo_text = ""
			label.visible = false
		return
	## last_text 为 AMMO_TEXT_UNSET（哨兵）时必然 != text → 首次必刷，无需特殊分支。
	var mag: int = state.get_magazine_ammo(weapon.item_id)
	var text: String
	if weapon.ammo_is_infinite:
		text = "%d/∞" % mag
	else:
		text = "%d/%d" % [mag, state.count_ammo_item(weapon.ammo_item_id)]
	if text != last_text:
		if is_primary:
			_last_primary_ammo_text = text
		else:
			_last_secondary_ammo_text = text
		label.text = text
	label.visible = true


## 投掷物 / 辅助品图标：持有对应物品时显示其 icon，位于副武器图标列下方。
func _update_consumables() -> void:
	var state: PlayerState = Players.get_active_state()
	if _force_refresh or state.throwable != _last_throwable_item:
		_last_throwable_item = state.throwable
		_set_item_icon(throwable_icon, state.throwable)
	if _force_refresh or state.support_item != _last_support_item:
		_last_support_item = state.support_item
		_set_item_icon(support_icon, state.support_item)
	_update_throwable_count(state)


## 投掷物数量：与弹药标签同款（ark-pixel + 阴影，见 _apply_ammo_font），
## 显示在投掷物图标正下方（combat_hud.tscn 里可拖动定位）。无投掷物时隐藏。
func _update_throwable_count(state: PlayerState) -> void:
	if not throwable_count_label:
		return
	var shown: int = state.throwable_count if (state.throwable and state.throwable_count > 0) else -1
	if _force_refresh or shown != _last_throwable_count:
		_last_throwable_count = shown
		if shown > 0:
			throwable_count_label.text = "×%d" % shown
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
# 联机队友血条（2026-10-20 用户需求）
# ═══════════════════════════════════════════════════════════════
#
# 需求：多人模式下把「除自己之外」的玩家血条显示在自己血条的下方。
#
# 【为什么不是纯代码生成】节点树固定在 combat_hud.tscn 里：
#   RemotePlayerBars（VBoxContainer）—— 整体位置/行间距在这里拖动调整
#     └ RemoteBarTemplate（Control，visible=false）—— 单条外观：
#         HPBar（TextureProgressBar，ＨＰバー+ＨＰメーター，scale=2 整数缩放）
#         NameLabel（昵称，字号 24=12×2）
# 运行期只做两件事：按队友人数 duplicate 模板、把 HP 比例与名字填进去。
# 于是「位置、尺寸、间距、字号」全部是场景里所见即所得的可调属性，代码里没有
# 任何 new()/add_child 造 UI 的痕迹。
#
# 【素材选择】主血条用 `ＨＰバーＴ.png`，那张框上自带 Time/HP/TP 字样，排成多行会与
# 昵称叠字；队友条因此改用同源的 `ＨＰバー.png`（120×16 纯条，与联机头顶名牌一致），
# 2x 缩放后 240×32 —— 清晰、不糊、也不抢主血条的视觉重量。
#
# 【单机为什么不显示】单机一个实体可编 3 个角色（Q 切换），座位数 > 1 但真人只有 1 个，
# 直接把座位表当队友会显示「自己的另外两个角色」，因此严格要求联机会话。

@onready var _remote_bars_root: VBoxContainer = $RemotePlayerBars
@onready var _remote_bar_template: Control = $RemotePlayerBars/RemoteBarTemplate

## 已复用的行（第 i 行对应队友列表第 i 项），以及每行上次应用的 HP 比例（脏检查）。
var _remote_rows: Array[Control] = []
var _remote_row_ratios: Array[float] = []


## 每帧刷新队友血条（行数变化才增删节点，数值不变则跳过重设）。
func _update_remote_bars() -> void:
	if _remote_bars_root == null or _remote_bar_template == null:
		return
	var seats: Array[int] = _remote_seat_indices()
	_ensure_remote_rows(seats.size())
	for i: int in range(_remote_rows.size()):
		var row: Control = _remote_rows[i]
		if i >= seats.size():
			row.visible = false
			continue
		var state: PlayerState = Players.get_seat(seats[i])
		if state == null:
			row.visible = false
			continue
		row.visible = true
		_apply_remote_row(i, row, seats[i], state)


## 「除自己之外」的座位索引（按座位表顺序，UI 顺序因此稳定不跳）。单机恒为空。
func _remote_seat_indices() -> Array[int]:
	var out: Array[int] = []
	if not Players.is_online_session():
		return out
	var my_peer: int = 0
	if Net != null and Net.has_method("get_my_peer_id"):
		my_peer = int(Net.get_my_peer_id())
	for i: int in range(Players.seat_count()):
		## 双保险：active_seat_index 在座位表重建时可能滞后于 owner_peer_id，
		## 两个条件任一命中即视为「自己」。
		if i == Players.active_seat_index:
			continue
		var state: PlayerState = Players.get_seat(i)
		if state == null:
			continue
		if my_peer > 0 and state.owner_peer_id == my_peer:
			continue
		out.append(i)
	return out


## 按需复制模板补足行数。模板的外观完全来自场景，这里只改名字与可见性。
func _ensure_remote_rows(count: int) -> void:
	while _remote_rows.size() < count:
		var row := _remote_bar_template.duplicate() as Control
		if row == null:
			return
		row.name = "RemoteBar%d" % _remote_rows.size()
		## duplicate 会原样带上模板的 visible=false（模板必须隐藏，否则容器里多占一行）。
		row.visible = true
		_remote_bars_root.add_child(row)
		_remote_rows.append(row)
		_remote_row_ratios.append(-1.0)


## 填一行：HP 比例 + 昵称 + 归零淡出。
## 血条是 TextureProgressBar（texture_under=ＨＰバー / texture_progress=ＨＰメーター，
## 与联机头顶名牌同一套素材），2x 整数缩放由场景里的 HPBar.scale 决定。
func _apply_remote_row(index: int, row: Control, seat_index: int, state: PlayerState) -> void:
	var ratio: float = clampf(state.current_hp / maxf(state.get_max_hp(), 1.0), 0.0, 1.0)
	if absf(ratio - _remote_row_ratios[index]) > 0.001:
		_remote_row_ratios[index] = ratio
		var bar := row.get_node_or_null("HPBar") as TextureProgressBar
		if bar:
			bar.value = ratio * 100.0
	var label := row.get_node_or_null("NameLabel") as Label
	if label:
		var text: String = _remote_bar_text(seat_index, state)
		if label.text != text:
			label.text = text
	## 血量归零（倒地或真死亡）→ 整行淡出，避免「0 血站着」的误导（与头顶名牌同语义）。
	row.modulate.a = 1.0 if state.current_hp > 0.0 else 0.45


## 行标题：与头顶名牌同格式「2P 昵称」；拿不到昵称时只显示座位号。
func _remote_bar_text(seat_index: int, state: PlayerState) -> String:
	var nick: String = ""
	if state.owner_peer_id > 0 and Net != null and Net.has_method("get_player_name"):
		nick = String(Net.get_player_name(state.owner_peer_id))
	if nick.is_empty():
		return "%dP" % (seat_index + 1)
	return "%dP %s" % [seat_index + 1, nick]


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


# ═══════════════════════════════════════
# 右下角操作提示（2026-10-28 用户需求）
# ═══════════════════════════════════════
#
# 场景里是**可视化节点**（`combat_hud.tscn` 的 ActionHints → Margin → VBox → Row1..4），
# 每行 = Key（键帽底 Label）+ Text（说明 Label），样式/字号都在编辑器里直接改。
# 脚本只负责「按当前状态挑哪几行、填什么字」：
#   · 未举枪：提示 1 / 2 举起对应武器（没有的槽位不提示）；
#   · 举枪中：Shift/1 放下武器、Z 攻击、（弹匣未满时）A 装填、X 固定朝向 / 解除固定。
# 最多 4 行，超出的按优先级丢弃；一行都没有时整块隐藏。

## 字号与弹药数字一致（36 = 12 的整倍，项目 UI 铁律）。
const ACTION_HINT_FONT_SIZE: int = 36

@onready var _action_hints: PanelContainer = $ActionHints
@onready var _action_hint_vbox: VBoxContainer = $ActionHints/Margin/VBox

## [[KeyLabel, TextLabel], ...]，按场景里的行顺序缓存。
var _hint_rows: Array = []
## 36px 提示统一使用的「锐利字体副本」（AA/次像素关、oversampling=1，见 _apply_ammo_font）。
var _crisp_ui_font: FontFile = null


func _cache_action_hint_rows() -> void:
	_hint_rows.clear()
	if not is_instance_valid(_action_hint_vbox):
		return
	for row: Node in _action_hint_vbox.get_children():
		var key_label := row.get_node_or_null("Key") as Label
		var text_label := row.get_node_or_null("Text") as Label
		if key_label == null or text_label == null:
			continue
		## 字体跟随「设置 → 界面字体」（与其它 HUD 文字同源）。
		Global.apply_hint_font(key_label, ACTION_HINT_FONT_SIZE)
		Global.apply_hint_font(text_label, ACTION_HINT_FONT_SIZE)
		## 再套 36px 锐利副本（见 _apply_ammo_font 末尾的说明）。
		_apply_crisp_font(key_label)
		_apply_crisp_font(text_label)
		_hint_rows.append([key_label, text_label])


func _update_action_hints() -> void:
	if not is_instance_valid(_action_hints):
		return
	var hints: Array = _collect_action_hints()
	var shown_count: int = mini(hints.size(), _hint_rows.size())
	for i: int in _hint_rows.size():
		var row: Array = _hint_rows[i]
		var key_label: Label = row[0]
		var text_label: Label = row[1]
		var use_row: bool = i < shown_count
		key_label.visible = use_row
		text_label.visible = use_row
		## 行容器也要一起隐藏：只隐藏 Label 的话 VBox 仍会为这一行留出 separation 间距，
		## 只剩 1 条提示时面板会莫名高出一截。
		var row_box: Control = key_label.get_parent() as Control
		if row_box != null:
			row_box.visible = use_row
		if use_row:
			key_label.text = str(hints[i][0])
			text_label.text = str(hints[i][1])
	_action_hints.visible = shown_count > 0


## 按本地玩家此刻的状态生成 [[按键文本, 说明], ...]。
## 顺序 = 优先级，超出 8 行的尾部会被丢弃（`_update_action_hints` 只填前 N 行）。
func _collect_action_hints() -> Array:
	var out: Array = []
	if not Global.show_action_hints:
		return out
	var player: Node2D = Players.get_local_entity()
	if player == null or not is_instance_valid(player):
		return out
	## 倒地 / 死亡时不提示（站着尸体还教玩家"按 1 举枪"没有意义）。
	if player.get("_is_dying") == true:
		return out
	var state: PlayerState = Players.get_state_for_entity(player)
	if state != null and state.current_hp <= 0.0:
		return out
	var in_weapon: bool = player.get("player_in_weapon_state") == true
	var locked: bool = player.has_method("is_facing_locked") and bool(player.call("is_facing_locked"))
	## ── 投掷物瞄准（举起手雷/燃烧瓶）：按键与举枪完全不同，必须先判 ──
	## 投掷状态也会把 player_in_weapon_state 置 true，不先拦就会提示「Shift/1 放下武器」——
	## 而投掷状态下 Shift 根本不响应（放下的键是 5，见 PlayerThrowableState._process_ready）。
	if _is_throwable_state(player):
		_push_hint(out, &"投掷物键", "放下投掷物")
		_push_hint(out, &"确定键", "按住瞄准 · 松开投掷")
		var inc_key: String = _action_key_text(&"投掷加格键")
		var dec_key: String = _action_key_text(&"投掷减格键")
		if not inc_key.is_empty() and not dec_key.is_empty():
			out.append(["%s / %s" % [inc_key, dec_key], "调整投掷距离"])
		_push_hint(out, &"取消键", "取消瞄准")
		return out
	if in_weapon:
		var down_key: String = _action_key_text(&"举起放下武器键")
		## 放下键跟着「举的是哪格」走：第 1 格 → Shift / 1，第 2 格 → Shift / 2。
		## 拿不到槽位（早期帧）时只显示 Shift，不猜。
		var slot: String = _active_weapon_slot(state)
		var slot_key: String = ""
		if slot == "secondary":
			slot_key = _action_key_text(&"副武器键")
		elif slot == "primary":
			slot_key = _action_key_text(&"主武器键")
		var combined: String = down_key if slot_key.is_empty() else "%s / %s" % [down_key, slot_key]
		if not combined.is_empty():
			out.append([combined, "放下武器"])
		_push_hint(out, &"确定键", "攻击")
		if _active_weapon_needs_reload(state):
			_push_hint(out, &"装填键", "装填")
		_push_hint(out, &"取消键", "解除固定朝向" if locked else "固定朝向")
		_push_skill_hints(out, state, true)
		_push_hint(out, &"推击键", "推击")
		return out
	## ── 未举枪（地面态）：能做的都在这里 ──
	var slot: String = _preferred_weapon_slot(state)
	if slot == "secondary":
		_push_hint(out, &"副武器键", "举起第 2 格武器")
	elif slot == "primary":
		_push_hint(out, &"主武器键", "举起第 1 格武器")
	## 觉醒只能在举枪（構え）中发动 → 地面态不传它。
	_push_skill_hints(out, state, false)
	_push_hint(out, &"推击键", "推击")
	_push_consumable_hints(out, state)
	if _can_switch_character():
		_push_hint(out, &"切换角色键", "切换角色")
	return out


## SA 技能（有才提示）+（可选）觉醒技能。
## ⚠ 觉醒只在举枪态可发动（`PlayerRangedState` 读觉醒键），地面态不要提示。
func _push_skill_hints(out: Array, state: PlayerState, include_awaken: bool) -> void:
	var character: CharacterData = state.character if state != null else null
	if character == null:
		return
	var sa_skill: SkillData = _find_sa_skill(character)
	if sa_skill != null:
		var skill_name: String = sa_skill.skill_name.strip_edges()
		var sa_text: String = ("SA · %s" % skill_name) if not skill_name.is_empty() else "SA 技能"
		_push_hint(out, &"SA键", sa_text)
	if include_awaken and String(character.awaken_type) != "none":
		_push_hint(out, &"覚醒键", "觉醒技能")


## 角色技能表里 command_trigger = "SA键" 的那一条（没有则 null）。
func _find_sa_skill(character: CharacterData) -> SkillData:
	for skill: SkillData in character.skills:
		if skill != null and String(skill.command_trigger).strip_edges() == "SA键":
			return skill
	return null


## 治疗品 / 辅助品 / 投掷物：只在**持有**时提示，标出剩余数量。
func _push_consumable_hints(out: Array, state: PlayerState) -> void:
	if state == null:
		return
	if state.healing_item != null and state.healing_item_count > 0:
		_push_hint(out, &"治疗品键", "治疗品 ×%d" % state.healing_item_count)
	if state.support_item != null:
		_push_hint(out, &"辅助品键", "辅助品")
	if state.throwable != null and state.throwable_count > 0:
		_push_hint(out, &"投掷物键", "投掷物 ×%d" % state.throwable_count)


## 单人 + 队伍里不止一个角色时才能换人（联机的「座位」是别的玩家，不能切）。
func _can_switch_character() -> bool:
	if Players.is_online_session():
		return false
	return Players.seat_count() > 1


## 是否处于投掷物瞄准。
## 优先看状态机（`Throwable` 是唯一真源）；`_throwable_mode` 只在外观切换时才置位
## （`PlayerThrowableState.enter` 里只有配了 held_walk_texture 才会调），不能单独依赖。
func _is_throwable_state(player: Node2D) -> bool:
	if player.get("_throwable_mode") == true:
		return true
	var sm: Node = player.get_node_or_null("StateMachine")
	if sm != null and sm.has_method("current_state_name"):
		return String(sm.call("current_state_name")) == "Throwable"
	return false


func _push_hint(out: Array, action: StringName, text: String) -> void:
	var key: String = _action_key_text(action)
	if key.is_empty():
		return
	out.append([key, text])


## 平台感知的按键文本；移动端没有对应按钮的动作返回 ""（整行不显示）。
func _action_key_text(action: StringName) -> String:
	if Global.has_method("has_key_hint") and not bool(Global.call("has_key_hint", action)):
		return ""
	return String(Global.key_hint(action))


## 优先提示哪一个武器槽：主武器优先，没有再提示副武器。
func _preferred_weapon_slot(state: PlayerState) -> String:
	if state == null:
		return ""
	if state.get_equipped_weapon("primary") != null:
		return "primary"
	if state.get_equipped_weapon("secondary") != null:
		return "secondary"
	return ""


## 当前举着的武器槽（"primary" / "secondary"）；取不到返回 ""。
## 「放下武器」那行用它对键位：举副武器时提示「Shift / 1」是错的，应为 2。
func _active_weapon_slot(state: PlayerState) -> String:
	if state == null:
		return ""
	var slot: String = String(state.active_weapon_slot)
	if slot == "primary" or slot == "secondary":
		return slot
	var weapon: WeaponData = state.get_active_weapon()
	return weapon.get_slot_key() if weapon != null else ""


## 当前武器是否远程且弹匣未满（满了就不提示装填）。
func _active_weapon_needs_reload(state: PlayerState) -> bool:
	if state == null:
		return false
	var weapon: WeaponData = state.get_active_weapon()
	if weapon == null or not weapon.is_ranged:
		return false
	var capacity: int = weapon.magazine_capacity
	if capacity <= 0:
		return false
	return state.get_magazine_ammo(weapon.item_id) < capacity


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
