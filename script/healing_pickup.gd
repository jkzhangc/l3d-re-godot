@tool
extends Node2D

## ── 架构定位 ──
## 系统：补给掉落物 ｜ 层：玩法（Node2D）
## 联机：Client 请求 / Host 校验提交
## 职责：治疗品/辅助品/投掷物掉落物：共用一个交互壳，但写入 PlayerState 的字段各不相同。
## 依赖：ItemData/ThrowableData、PlayerState、NetworkWorld

## 治疗品 / 投掷物掉落物。
## healing_item 与 throwable 共用交互壳，但写入 PlayerState 的库存字段不同。
## Client 必须走 _request_network_pickup()；只有 Host 明确标记的 presentation-only 镜像
## 才屏蔽请求，这一点对客户端拾取投掷物尤其重要。
## 治疗品/投掷物拾取物 — 放在地图上供玩家拾取
##
## 治疗品/辅助品：触碰自动拾取。
## 投掷物：空槽自动拾取；已持有则按住「确定键」替换（旧投掷物掉落回地面）。
##
## 支持 VX Ace 行走图渲染（与武器拾取物相同）：当 ItemData.pickup_texture 已配置时，
## 用 region 帧渲染 + 原地踏步动画；未配置则回退到 ItemData.icon 整图显示。

# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
## 行走图文件名特殊前缀（`$` = 单角色表）解析，见 script/vx_walk_sheet.gd
const WALK := preload("res://script/vx_walk_sheet.gd")
const DIRECTIONS: int = 4

## 拾取物模板场景（投掷物替换时掉落旧投掷物用）
const PICKUP_SCENE := preload("res://object/healing_pickup.tscn")
## 掉落物短时间不可拾取，防止替换后立即重新拾取造成循环
const PICKUP_DELAY_MSEC: int = 600

const INDICATOR_SCRIPT := preload("res://script/hold_indicator.gd")
## 提示文字统一渲染层（不被角色/图块遮挡、不吃夜图暗度），见 script/ui/hint_text_layer.gd
const HINT_LAYER := preload("res://script/ui/hint_text_layer.gd")
## 成就记账（拾取即用按「使用治疗品」同口径计入，与 player.gd / network_world.gd 一致）。
const ACHIEVEMENTS := preload("res://script/achievements.gd")
## 交互判定（点击一下 / 按住）的唯一入口，见 script/pickup_interaction.gd。
const PickupInteraction := preload("res://script/pickup_interaction.gd")
## 拾取范围的单一真源（与武器拾取物同规则，2026-09-23 用户：拾取范围调小一些）。
## ⚠ tscn 的 Area2D 半径须同为 WEAPON_PICKUP_SCRIPT.PICKUP_RANGE(16)。
const WEAPON_PICKUP_SCRIPT := preload("res://script/weapon_pickup.gd")

@export var item: ItemData:
	set(v):
		item = v
		## Inspector 里换物品即时刷编辑器预览（预览走 item.pickup_texture/icon）
		_refresh_sprite()  ## 要给予的物品（治疗品/投掷物）

## 2026-09-13 用户需求：开启后治疗品/辅助品不再触碰自动拾取，
## 改为靠近按住功能键(D)拾取（进度环提示）。投掷物替换仍按住确定键（旧机制）。
## ★2026-10-26：物品数据也可声明（`ItemData.pickup_requires_function_key`），
## 治疗品/辅助品已在各自 .tres 里打开；本字段保留为**节点级覆盖**（给单个预摆实例用）。
@export var require_function_key: bool = false

@export_group("Hold Settings")
## 按住替换所需时长（秒）
@export var hold_time: float = 1.2

@export_group("Hold Indicator")
## 是否启用按住进度指示器（圆环填充动画）
@export var hold_indicator_enabled: bool = true
## 指示器圆环半径（像素）
@export var hold_indicator_radius: float = 18.0
## 圆环线宽（像素）
@export var hold_indicator_thickness: float = 3.0
## 指示器位置偏移（相对拾取物原点，Y轴向上为负）
@export var hold_indicator_offset: Vector2 = Vector2(0, -48)
## 进度填充颜色
@export var hold_indicator_color: Color = Color(1.0, 0.9, 0.2, 1.0)
## 背景圆环颜色
@export var hold_indicator_bg_color: Color = Color(0.0, 0.0, 0.0, 0.55)
## 淡入淡出速度（alpha/秒，值越大过渡越快）
@export var hold_indicator_fade_speed: float = 5.0

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D

var _step_idx: int = 0           ## 当前踏步帧在序列中的索引
var _step_timer: float = 0.0     ## 踏步帧计时器
var _spawn_msec: int = 0         ## 生成时刻（掉落物拾取冷却用）
## 地面放置物上限豁免：地图预摆的拾取物（含 random_pickup 预摆实例刷出的）不参与
## GroundItemCap(8) 计数与淘汰 —— 它们是关卡设计的一部分，不是掉落杂物。
var cap_exempt: bool = false
var _player_in_range: bool = false
var _player_ref: CharacterBody2D = null
var _hold_timer: float = 0.0
var _indicator_alpha: float = 0.0
var _indicator_node: Node2D = null
## 头顶「D」键帽提示（2026-10-26）：需要按住功能键才能拾取时才显示，样式与武器拾取物同款。
const HINT_FONT_SIZE: int = 12
var _keycap_hint: Label = null

## 在线联机中由 NetworkWorld 分配；0 表示尚未收到 Host 的权威快照。
var network_pickup_id: int = 0
## ★来源补给点 key（2026-10-12）：由 random_pickup 预摆实例刷出时透传。
## 拾取成功时回标「本补给点已消耗」（走 quest_flags 持久化）→ 死亡重载/读档不复活。
## 空 = 非地图预摆补给（敌人掉落 / 玩家丢弃 / 动态投放）→ 不持久化。
var map_source_key: String = ""
var network_presentation_only: bool = false
var _network_pickup_request_pending: bool = false
var _network_request_msec: int = 0          ## 请求发出时刻（超时自愈用）
const NETWORK_REQUEST_RETRY_MS: int = 500


func _ready() -> void:
	if Engine.is_editor_hint():
		# 编辑器预览（@tool）：按 item.pickup_texture/icon 刷出显示，让摆点时能看见长相。
		# 不注册掉落上限、不连 Area2D、不建按住指示器。
		_refresh_sprite()
		return
	_spawn_msec = Time.get_ticks_msec()
	## 组登记（09-22）：ground_pickup = 全部地面掉落物（落点避让 + NetworkWorld 的
	## 动态掉落物收编扫描都用它，旧实现治疗品不在任何组里 → 动态投放的治疗品
	## Host 收编不到、Client 也看不见）。
	add_to_group(&"ground_pickup")
	add_to_group(&"healing_pickup")
	## 自动判定：编辑器摆进场景的实例 owner 非空 → 豁免（运行时刷出 owner 为空）。
	## 用 or 是为了不覆盖 random_pickup 对预摆实例刷出物的预设豁免。
	cap_exempt = cap_exempt or owner != null
	if not cap_exempt:
		GroundItemCap.register(self)
	if _area:
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)
	_refresh_sprite()

	# 创建按住进度指示器子节点（z_index 高于精灵，确保圆环绘制在精灵上方）
	if hold_indicator_enabled:
		_indicator_node = Node2D.new()
		_indicator_node.name = "HoldIndicator"
		_indicator_node.z_index = 10
		_indicator_node.set_script(INDICATOR_SCRIPT)
		_indicator_node._pickup = self
		add_child(_indicator_node)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# 踏步动画（仅行走图模式下生效）
	if item and item.pickup_texture and item.pickup_animated:
		var frames: Array[int] = item.pickup_step_frames
		if frames.is_empty():
			frames = [1, 0, 1, 2]
		var dur: float = item.pickup_step_duration if item.pickup_step_duration > 0.0 else 0.25
		_step_timer += delta
		if _step_timer >= dur:
			_step_timer -= dur
			_step_idx = (_step_idx + 1) % frames.size()
			_refresh_sprite()

	# 指示器每帧无条件刷新（2026-09-13 残留修复，同 weapon_pickup）
	var holding: bool = false
	## 联机 Client：HEALING/SUPPORT（喷雾/药品）与投掷物一样走请求式拾取。
	## 旧实现只放行 THROWABLE → Client 端治疗品走单机 _do_pickup 本地入包，
	## Host 权威域毫无感知：Client 自己以为捡到了，倒地时 Host 判定没喷雾（2026-09-22 实测）。
	if _is_online_network_pickup() and item \
			and (item.item_type == ItemData.ItemType.THROWABLE
				or item.item_type == ItemData.ItemType.HEALING
				or item.item_type == ItemData.ItemType.SUPPORT):
		holding = _process_network_pickup(delta)
	else:
		holding = _process_pickup(delta)
	_update_hold_indicator(delta, holding)
	_update_keycap_hint()


## ── 拾取方式（2026-10-26）──
## 需要按住功能键(D)才拾取：**物品数据开关 ∨ 本节点开关**。
## 物品级让"药品类一律按 D 捡"跟着物品走（掉落生成点不必逐个配置）；
## 节点级保留给单个预摆实例覆盖。
func _need_function_key() -> bool:
	if item != null and item.needs_function_key_pickup():
		return true
	return require_function_key


## ── 交互输入仲裁（2026-10-27 用户需求）──
## 语义：此刻按「功能键」，本节点会不会真的做事。存档点据此让路（见
## script/interact_priority.gd：存档优先级最低）。
## 只有「需要按 D 拾取」的路径才占用该键：
##   · 触碰即自动拾取的物品不占用 → 不挡存档；
##   · 已持有投掷物时替换走**确定键**（见 `_process_pickup` / `_process_network_hold`）→ 不挡存档。
func can_use_function_key() -> bool:
	if Engine.is_editor_hint():
		return false
	if not _player_in_range or not is_instance_valid(_player_ref) or item == null:
		return false
	if network_presentation_only:
		return false
	if _is_online_network_pickup() and network_pickup_id <= 0:
		return false
	## 与 `_process_pickup` 同口径：刚掉落的短冷却期内按 D 也不生效。
	if Time.get_ticks_msec() - _spawn_msec < PICKUP_DELAY_MSEC:
		return false
	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if state != null and item.item_type == ItemData.ItemType.THROWABLE and state.throwable != null:
		return false
	## 拾取即用的物品（草药/矿泉水）：拾取者数值已满 → `_do_pickup` 会把它留在地上，
	## 按 D 等于白按 → 不挡存档（与下面喷雾满仓同一条口径）。
	if item.uses_on_pickup():
		return _need_function_key() and state != null and _can_use_immediately(state)
	## 喷雾类已满 → `_do_pickup` 会把它留在地上（返回 false），按 D 等于白按 → 不挡存档。
	if item.item_type == ItemData.ItemType.HEALING and _healing_storage_full(state):
		return false
	return _need_function_key()


## 喷雾存量是否已满（与 `_do_pickup` 的收纳判据同源：单机共用池 / 联机按座位）。
func _healing_storage_full(state: PlayerState) -> bool:
	if Players.using_shared_spray_pool():
		return Players.team_spray_count >= Players.spray_capacity_total()
	if state == null:
		return false
	return state.healing_item_count >= Players.spray_per_seat_cap()


## 头顶键帽：只有"进范围 + 需要按 D"才显示（与 weapon_pickup 的键帽同款外观/层级）。
## 联机镜像（presentation_only）与「还没拿到 Host 分配 id」的掉落物不显示 —— 那时按 D 也捡不起来。
func _update_keycap_hint() -> void:
	var show: bool = _player_in_range and is_instance_valid(_player_ref) and _need_function_key()
	if show and (network_presentation_only or (_is_online_network_pickup() and network_pickup_id <= 0)):
		show = false
	if show:
		_ensure_keycap_hint()
		_keycap_hint.visible = true
	elif _keycap_hint != null and is_instance_valid(_keycap_hint):
		_keycap_hint.visible = false


func _ensure_keycap_hint() -> void:
	if _keycap_hint != null and is_instance_valid(_keycap_hint):
		return
	var g: Node = get_node_or_null("/root/Global")
	var cap_text: String = str(g.call("key_hint", &"功能键")) if g and g.has_method("key_hint") else "D"
	var lbl := Label.new()
	lbl.name = "KeycapHint"
	lbl.text = cap_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	## 键帽外观：深底 + 浅描边 + 圆角（与 weapon_pickup 完全一致，避免两种掉落物长得不一样）
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.85)
	sb.border_color = Color(0.95, 0.95, 0.9, 0.95)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_top = 1.0
	sb.content_margin_bottom = 1.0
	lbl.add_theme_stylebox_override("normal", sb)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	if g and g.has_method("apply_hint_font"):
		g.call("apply_hint_font", lbl, HINT_FONT_SIZE)
	else:
		lbl.add_theme_font_size_override("font_size", HINT_FONT_SIZE)
	add_child(lbl)
	_keycap_hint = lbl
	_layout_keycap_hint()


## 键帽宽度随文字自适应（手机端「功能」比「D」宽），水平居中悬在掉落物上方。
## 行走图模式精灵为 48×64（原点在脚部）→ -74；退回整图图标时精灵更矮 → -54。
func _layout_keycap_hint() -> void:
	if _keycap_hint == null or not is_instance_valid(_keycap_hint):
		return
	var g: Node = get_node_or_null("/root/Global")
	var cap_text: String = _keycap_hint.text
	var font: Font = g.call("get_ui_font") if g and g.has_method("get_ui_font") else null
	var text_w: float = font.get_string_size(cap_text, HORIZONTAL_ALIGNMENT_LEFT, -1, HINT_FONT_SIZE).x if font else 12.0
	var cap_w: float = maxf(22.0, text_w + 10.0)
	var cap_h: float = 18.0
	_keycap_hint.size = Vector2(cap_w, cap_h)
	var y: float = -74.0 if (item != null and item.pickup_texture) else -54.0
	var hint_pos := Vector2(-cap_w * 0.5, y)
	_keycap_hint.position = hint_pos
	## 与武器拾取物同层级：盖住 DecorLayer 图块，但低于黑幕(90)/ED(95)/章节总结(100)
	_keycap_hint.z_index = 10
	## ★提示文字层（2026-10-28）：搬到提示层（layer=89）—— 键帽不再被角色/图块遮挡，
	## 也不吃夜图 CanvasModulate 的暗度。按文字宽度重排后要重新同步偏移。
	HINT_LAYER.attach(_keycap_hint, hint_pos)


func _is_online_network_pickup() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net and net.has_method("is_online_session") and bool(net.is_online_session())


func _process_network_pickup(delta: float) -> bool:
## 联机客户端只检测交互、显示长按提示并提交请求；Host 回包后才视为成功。
	if network_pickup_id <= 0 or network_presentation_only:
		_hold_timer = 0.0
		return false
	var local_player := Players.get_local_entity() as CharacterBody2D
	var in_range := is_instance_valid(local_player) and local_player.global_position.distance_to(global_position) <= WEAPON_PICKUP_SCRIPT.PICKUP_REACH
	_player_ref = local_player if in_range else null
	_player_in_range = in_range
	if not in_range or not item:
		_hold_timer = 0.0
		return false
	var state: PlayerState = Players.get_state_for_entity(local_player)
	if not state:
		return false
	var throwable_replacement: bool = item.item_type == ItemData.ItemType.THROWABLE and state.throwable != null
	if not throwable_replacement and not _need_function_key():
		_request_network_pickup()
		return false
	## ★投掷物替换（已持有→换新）与「按 D 拾取」都必须走**网络版按住**（2026-10-13 用户实测）：
	## 旧实现落到 `_process_hold → _do_pickup()` 的单机本地事务 —— 在 Client 本地域直接
	## 改 `state.throwable`、本地掉落旧物、本地 `queue_free`，**Host 完全不知情**，
	## 下一拍 Host 快照（`throwable_id` + `pickup_snapshot`）把状态写回旧值、掉落物重建 →
	## 表现为「按确定键替换没同步 / 换完又变回去 / 地上掉落物复活」。
	## 与 weapon_pickup 的网络版按住同款：满进度只提交请求，事务在 Host。
	## （2026-10-26：药品类默认改成按 D 拾取后，这条分支成了常规路径，必须同样只发请求。）
	return _process_network_hold(delta, throwable_replacement)


func _request_network_pickup() -> void:
	if _network_pickup_request_pending:
		# 超时自愈（同 weapon_pickup）：Host 静默拒绝（全队所持上限满等）时
		# 不再永久卡死，500ms 后允许重新请求。
		if Time.get_ticks_msec() - _network_request_msec < NETWORK_REQUEST_RETRY_MS:
			return
		_network_pickup_request_pending = false
	_network_pickup_request_pending = true
	_network_request_msec = Time.get_ticks_msec()
	_hold_timer = 0.0
	var scene := get_tree().current_scene
	var world := scene.find_child("NetworkWorld", true, false) if scene else null
	if world and world.has_method("request_pickup"):
		# 带本机位置上报（滞后补偿，同 weapon_pickup）。
		var claim: Variant = _player_ref.global_position if is_instance_valid(_player_ref) else null
		world.request_pickup(network_pickup_id, claim)
	else:
		_network_pickup_request_pending = false


## 网络版按住流程（2026-10-13 / 2026-10-26 扩展）：交互条件与单机 `_process_hold` 一致，
## 但满进度**只提交拾取请求**，绝不本地 `_do_pickup()` —— 事务在 Host（与 weapon_pickup 的
## `_process_network_hold` 同款）。
## `throwable_replacement = true` → 已持有投掷物时按**确定键**替换；
## `false` → 按**功能键(D)** 拾取（物品数据 `pickup_requires_function_key` 打开的药品类）。
func _process_network_hold(delta: float, throwable_replacement: bool) -> bool:
	## 玩家正在武器/投掷物举起/瞄准状态时不触发替换（避免与确定键瞄准冲突）。
	if throwable_replacement and _player_ref.get("player_in_weapon_state"):
		_hold_timer = 0.0
		return false
	var action: String = "确定键" if throwable_replacement else "功能键"
	## 点击模式（默认，2026-10-26）：按一下就提交请求，不累积进度。
	if not PickupInteraction.is_hold_mode():
		_hold_timer = 0.0
		if PickupInteraction.tapped_once(action):
			_request_network_pickup()
		return false
	if Input.is_action_pressed(action):
		_hold_timer += delta
		if _hold_timer >= hold_time:
			_request_network_pickup()
			return false
		return true
	_hold_timer = 0.0
	return false


func configure_network_pickup(pickup_id: int, presentation_only: bool = false) -> void:
	network_pickup_id = pickup_id
	network_presentation_only = presentation_only
	_network_pickup_request_pending = false


func reset_network_pickup_request() -> void:
	_network_pickup_request_pending = false


func disable_network_pickup() -> void:
	visible = false
	_player_in_range = false
	_player_ref = null
	_hold_timer = 0.0
	if _area:
		_area.set_deferred("monitoring", false)
		_area.set_deferred("monitorable", false)


func _process_pickup(delta: float) -> bool:
## 单机/Host 拾取逻辑。返回本帧是否处于按住状态（供进度环刷新）。
	if not _player_in_range or not _player_ref:
		_hold_timer = 0.0
		return false
	if not item:
		return false
	# 掉落物短时间不可拾取，防止替换后立即重新拾取循环
	if Time.get_ticks_msec() - _spawn_msec < PICKUP_DELAY_MSEC:
		return false

	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return false

	# 投掷物且已持有 → 按住确定键替换；其余默认自动拾取，
	# 需要按住功能键(D) 时（物品数据开关 / 节点开关）改走按住流程（进度环提示，避免路过误拾）
	var throwable_replacement: bool = item.item_type == ItemData.ItemType.THROWABLE and state.throwable != null
	if not throwable_replacement:
		if not _need_function_key():
			_do_pickup()
			return false
		return _process_hold(delta, false)

	# 玩家正在武器/投掷物举起/瞄准状态，不触发替换（避免与确定键瞄准冲突）
	if _player_ref.get("player_in_weapon_state"):
		_hold_timer = 0.0
		return false
	return _process_hold(delta, true)


func _process_hold(delta: float, throwable_replacement: bool) -> bool:
	## 按住进度：投掷物替换用确定键（旧行为），功能键获取用功能键(D)。
	var action: String = "确定键" if throwable_replacement else "功能键"
	## 点击模式（默认，2026-10-26）：按一下立刻执行，不累积进度、不出进度环。
	if not PickupInteraction.is_hold_mode():
		_hold_timer = 0.0
		if PickupInteraction.tapped_once(action):
			_do_pickup()
		return false
	if Input.is_action_pressed(action):
		_hold_timer += delta
		if _hold_timer >= hold_time:
			_do_pickup()
			return false
		return true
	_hold_timer = 0.0
	return false


func _do_pickup() -> bool:
## 单机/Host 权威拾取事务：按类型增加治疗品或投掷物，并按规则处理已有投掷物。
## 返回是否拾取成功（联机 Host 事务据此决定是否广播快照；失败=留在地上）。
	if not item:
		return false
	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return false

	# ★拾取即用（2026-10-28）：草药/矿泉水这类「不能携带」的物品 → 当场结算效果，不进背包。
	## 放在投掷物替换与治疗品收纳之前：不占槽位、也不触发旧投掷物掉落。
	if item.uses_on_pickup():
		return _do_pickup_use_immediately(state)

	# 投掷物单槽位：已持有则先掉落旧的（同副武器替换逻辑）
	if item.item_type == ItemData.ItemType.THROWABLE and state.throwable:
		_drop_old_throwable(_player_ref, state)
	# 治疗品（急救喷雾）：
	#   单机 → 队伍共用池（上限 10，2026-09-13 用户定稿），满了留在地上；
	#   联机 → **只看自己的槽位**（每人上限 3）。2026-09-24 用户定稿：自己满了就
	#   不再自动拾取（留在地上给队友），取消旧实现「满了转投其他座位」的回退 ——
	#   那会让队友凭空多出一支、且与本作「每人独立槽位（自己捡自己用）」的语义相悖。
	if item.item_type == ItemData.ItemType.HEALING:
		var placed: bool = false
		if Players.using_shared_spray_pool():
			placed = Players.try_add_team_spray(item)
			if not placed:
				print("[拾取] 喷雾共用池已满（10），留在地上")
				return false
		else:
			var cap: int = Players.spray_per_seat_cap()
			placed = state.pickup_consumable(item, cap)
			if not placed:
				print("[拾取] 自己座位喷雾已满（%d），留在地上" % cap)
				return false
	else:
		state.pickup_consumable(item)
	## 拾取音效：物品数据（ItemData.pickup_sound）可配，留空用全局默认（2026-09-15）。
	## 放满留在地上的分支在上面已 return，不会响。
	Global.play_pickup_sfx(item.pickup_sound, item.pickup_sound_pitch)
	## ★地图预摆补给：拾取成功即标记该补给点已消耗（随存档持久化，防重载复活）。
	if not map_source_key.is_empty():
		Global.mark_map_pickup_consumed(map_source_key)
	queue_free()
	return true


## ── 拾取即用事务（2026-10-28）──
## 效果直接结算在拾取者身上，掉落物消失、**不进治疗品/辅助品槽位**。
## 拾取者对应数值已满 → 视为无法使用，物品留在地上（返回 false，联机 Host 不回执）。
## 复用 `player.apply_item_effects()`：与按键使用同一套 HP/TP/強化/全屏闪烁/音效。
## 联机 Host 代远程玩家结算时，它内部只对「本机操控者」播表现 → 不会闪 Host 自己的屏，
## 真实数值写进权威 PlayerState，随后由快照回灌 Client。
## 拾取音效由使用表现（ItemData.use_sound）承担，不再叠一层 pickup_sound。
## 看护被动 / 章节统计 / 成就与按键使用治疗品同口径（见下方实现）。
func _do_pickup_use_immediately(state: PlayerState) -> bool:
	if not _can_use_immediately(state):
		print("[拾取] %s：当前数值已满，留在地上" % item.item_name)
		return false
	if not is_instance_valid(_player_ref) or not _player_ref.has_method("apply_item_effects"):
		return false
	_player_ref.call("apply_item_effects", item)
	## 看护（静香被动）与手动使用同口径：使用治疗品 → 全队同时回复相同 HP。
	if _player_ref.has_method("apply_nursing_passive"):
		_player_ref.call("apply_nursing_passive", item)
	## 章节统计 / 成就：与按键使用治疗品完全同口径（仅 HEALING 类计入）。
	## 联机 Host 代远程玩家结算时写的是该玩家座位，规则同 network_world 的 Host 路径。
	if item.item_type == ItemData.ItemType.HEALING:
		var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
		if chapter_stats and chapter_stats.has_method("record_healing_item"):
			chapter_stats.record_healing_item(state.seat_index)
			ACHIEVEMENTS.on_heal_item(state.seat_index)
	## 收藏馆：拿到即解锁（不进背包，但物品确实被获取过，口径同 2026-10-23 定稿）。
	state.mark_acquired(item)
	## ★地图预摆补给：拾取成功即标记该点已消耗（同常规拾取分支）。
	if not map_source_key.is_empty():
		Global.mark_map_pickup_consumed(map_source_key)
	print("[拾取] %s：拾取即用（不进背包）" % item.item_name)
	queue_free()
	return true


## 拾取即用会不会产生实际效果：只要有一种效果在当前数值下不是空转，就允许消耗。
## · 回复类：对应数值未满才有效（满 HP 吃草药 = 白吃 → 留在地上给需要的人）；
## · 強化类（鎮痛剤 / アドレナリン）：没有满值概念，总能施加。
func _can_use_immediately(state: PlayerState) -> bool:
	if item == null or state == null:
		return false
	if item.hp_restore > 0 and state.current_hp < state.get_max_hp():
		return true
	if item.tp_restore > 0 and state.current_tp < state.get_max_tp():
		return true
	if item.painkiller_seconds > 0.0 or item.adrenaline_seconds > 0.0:
		return true
	return false


func _drop_old_throwable(body: Node2D, state: PlayerState) -> void:
	## 将旧的投掷物生成为地面拾取物，掉落在玩家脚下。
	var old: ThrowableData = state.throwable
	if not old:
		return
	var drop: Node2D = PICKUP_SCENE.instantiate()
	drop.item = old
	## 落点与武器掉落统一（2026-09-23）：沿朝向推远 + 与已有掉落物避让 —— 否则旧投掷物
	## 掉在脚下会被自己的自动拾取立刻捡回（同「丢下的武器又被捡回」问题）。
	## ★同理（2026-10-27 用户定稿）：这类「替换掉落」不避玩家；避玩家只约束敌人掉落/导演投放。
	drop.position = WEAPON_PICKUP_SCRIPT.find_free_drop_position(
		get_tree(), WEAPON_PICKUP_SCRIPT.drop_landing_position(body))
	var parent: Node = get_parent()
	if not parent:
		parent = get_tree().current_scene
	parent.add_child(drop)
	print("[拾取] 投掷物替换: %s → %s" % [old.item_name, item.item_name])


func _refresh_sprite() -> void:
	# @onready 在编辑器预览路径可能未赋值（如手动触发），兜底按节点名取
	var sprite: Sprite2D = _sprite if _sprite else get_node_or_null("Sprite2D") as Sprite2D
	if not sprite or not item:
		return

	# 行走图模式：ItemData 配置了地面精灵表
	if item.pickup_texture:
		var frames: Array[int] = item.pickup_step_frames
		if frames.is_empty():
			frames = [1, 0, 1, 2]
		var frame: int
		if item.pickup_animated and frames.size() > 0:
			# ⚠ 夹紧（与 weapon_pickup 同因，09-23）：item 被换掉时 _step_idx 可能仍
			# 指向旧序列下标，而新序列更短（item setter 会先回调 _refresh_sprite）。
			_step_idx = clampi(_step_idx, 0, frames.size() - 1)
			frame = frames[_step_idx]
		else:
			frame = frames[0] if frames.size() > 0 else 1

		sprite.texture = item.pickup_texture
		sprite.region_enabled = true
		## 文件名带 `$` 前缀时按单角色表取帧（帧尺寸 = 图/3×4），见 vx_walk_sheet.gd
		sprite.region_rect = WALK.region_rect(sprite.texture, item.pickup_char_idx,
			item.pickup_direction, frame)
		return

	# 回退：整图显示 icon
	if item.icon:
		sprite.texture = item.icon
		sprite.region_enabled = false
	## 键帽位置取决于「行走图 / 整图」两种显示（高度不同），换物品时一并重排。
	_layout_keycap_hint()


func _on_body_entered(body: Node2D) -> void:
	var player: CharacterBody2D = body as CharacterBody2D
	if player:
		_player_in_range = true
		_player_ref = player
		_hold_timer = 0.0


func _on_body_exited(body: Node2D) -> void:
	var player: CharacterBody2D = body as CharacterBody2D
	if player and player == _player_ref:
		_player_in_range = false
		_player_ref = null
		_hold_timer = 0.0


func _update_hold_indicator(delta: float, is_holding: bool) -> void:
	## 更新按住进度指示器的淡入/淡出透明度，并触发重绘。
	## 2026-09-13 残留修复：同 weapon_pickup —— 每帧无条件调用 + alpha 归零补清屏。
	if not hold_indicator_enabled or not _indicator_node:
		return
	var target: float = 1.0 if is_holding else 0.0
	var prev: float = _indicator_alpha
	_indicator_alpha = move_toward(_indicator_alpha, target, hold_indicator_fade_speed * delta)
	if prev != _indicator_alpha or _indicator_alpha > 0.0 or _hold_timer > 0.0:
		_indicator_node.queue_redraw()


func _indicator_draw(node: Node2D) -> void:
	## 由 hold_indicator.gd 子节点的 _draw() 回调
	## 绘制背景圆环 + 进度填充弧线
	if _indicator_alpha <= 0.001:
		return

	var progress: float = clampf(_hold_timer / hold_time, 0.0, 1.0)
	var center: Vector2 = hold_indicator_offset
	var radius: float = hold_indicator_radius
	var thickness: float = hold_indicator_thickness
	var pts: int = 64

	var bg: Color = hold_indicator_bg_color
	bg.a *= _indicator_alpha
	node.draw_arc(center, radius, 0, TAU, pts, bg, thickness, true)

	if progress > 0.0:
		var fg: Color = hold_indicator_color
		fg.a *= _indicator_alpha
		var start_angle: float = -PI / 2.0
		var end_angle: float = start_angle + progress * TAU
		node.draw_arc(center, radius, start_angle, end_angle, pts, fg, thickness, true)
