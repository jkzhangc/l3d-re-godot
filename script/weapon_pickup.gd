@tool
extends Node2D

## ── 架构定位 ──
## 系统：武器掉落物 ｜ 层：玩法（Node2D）
## 联机：Client 请求 / Host 校验提交
## 职责：地面武器掉落物：踏步动画、按住拾取进度环、单机直接替换与联机请求式拾取。
## 依赖：WeaponData、PlayerState、NetworkWorld

## 地面武器掉落物。
##
## 单机：本地节点完成拾取/替换并生成旧武器掉落；联机：Client 只提交请求，Host
## 验证距离、槽位和物品 ID 后修改权威 PlayerState，再广播结果。
## network_presentation_only=true 只表示该镜像不能发起拾取请求，不能误用于仍需交互的掉落物。
## 武器拾取物 — 放在地图上供玩家拾取
##
## VX Ace 精灵渲染（与玩家/子弹相同）：通过 char_idx 选择角色，
## 通过踏步帧序列实现原地踏步动画。


# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
enum FaceDir { DOWN = 0, LEFT = 1, RIGHT = 2, UP = 3 }

## 武器拾取物模板场景（用于掉落生成）
const PICKUP_SCENE := preload("res://object/weapon_pickup.tscn")

# ═══════════════════════════════════════
# 堆叠仲裁与掉落间距（2026-09-16 用户反馈）
# ═══════════════════════════════════════
## 用户反馈①：多把武器堆在一起会被"一起拾取"、玩家无法选择
##   → 只有**离玩家最近**的武器拾取物可以动手；且一次"靠近"只自动捡一件，
##     走开 AUTO_REARM_DISTANCE 或换场景后重新武装（靠站位选想要的武器）。
## 用户反馈②：替换/丢弃的武器掉在玩家脚下会和附近掉落物叠在一起
##   → 落点自动避让，与已有地面掉落物保持 DROP_MIN_GAP 以上。
const PICKUP_GROUP := &"ground_pickup"          ## 全部地面掉落物（武器/治疗/投掷物）→ 落点避让用
const WEAPON_PICKUP_GROUP := &"weapon_pickup"   ## 仅武器拾取物 → 最近者仲裁用
const DROP_MIN_GAP: float = 24.0                ## 掉落物之间的最小间距（像素，用户定稿约 24）
const AUTO_REARM_DISTANCE: float = 64.0         ## 自动拾取后走开多远才重新武装
## 拾取范围（像素）。**必须与 weapon_pickup.tscn / healing_pickup.tscn 的 Area2D
## CircleShape2D.radius 保持一致**（24 → 16，2026-09-23 用户：拾取范围调小一些）。
const PICKUP_RANGE: float = 16.0
## 联机路径的本地距离判定 = PICKUP_RANGE(16) + 玩家碰撞半宽(12)，与单机 Area2D
## 触发半径等价（单机走物理重叠，联机走中心距 —— 两者须同值，否则两端手感不一致）。
const PICKUP_REACH: float = 28.0
## 掉落落点沿玩家朝向推远的距离（像素）。2026-09-23 用户：丢下的武器要离玩家远一些
## —— 落点必须落在 PICKUP_REACH(28) 之外，否则刚脱手就会被自己的自动拾取捡回。
const DROP_PUSH_DISTANCE: float = 40.0

## 自动拾取闩锁（static 跨实例共享；换场景或走远自动解除）
static var _auto_pick_latch: bool = false
static var _auto_pick_pos: Vector2 = Vector2.ZERO
static var _auto_pick_scene: String = ""


## 自动拾取是否已重新武装：未捡过 / 已换场景 / 已走开足够远。
static func auto_pickup_armed(tree: SceneTree, player: Node2D) -> bool:
	if not _auto_pick_latch:
		return true
	var scene_path: String = ""
	if tree and tree.current_scene:
		scene_path = tree.current_scene.scene_file_path
	if scene_path != _auto_pick_scene:
		_auto_pick_latch = false
		return true
	if is_instance_valid(player) \
			and player.global_position.distance_to(_auto_pick_pos) > AUTO_REARM_DISTANCE:
		_auto_pick_latch = false
		return true
	return false


## 记一次自动拾取：在玩家当前位置锁上闩锁（走开才解除）。
static func mark_auto_picked(tree: SceneTree, player: Node2D) -> void:
	_auto_pick_latch = true
	_auto_pick_pos = player.global_position if is_instance_valid(player) else Vector2.ZERO
	_auto_pick_scene = tree.current_scene.scene_file_path if tree and tree.current_scene else ""


## 掉落落点的朝向推远向量：优先取玩家的朝向单位向量，取不到则退回「朝下」。
## 单机与联机（Host 权威掉落）共用，保证两端落点规则一致。
static func drop_push_vector(player: Node2D) -> Vector2:
	var facing: Vector2 = Vector2(0, 1)
	if is_instance_valid(player) and player.has_method("get_facing_vector"):
		var raw: Variant = player.call("get_facing_vector")
		if raw is Vector2 and (raw as Vector2) != Vector2.ZERO:
			facing = raw as Vector2
	return facing * DROP_PUSH_DISTANCE


## 掉落落点基准 = 玩家位置沿朝向推远 DROP_PUSH_DISTANCE。
## 单机（drop_weapon_for_player）与联机 Host 权威掉落（network_world._spawn_host_dropped_weapon）
## 共用同一入口，保证两端落点规则一致、且都在拾取范围外（刚丢下不会被自己自动捡回）。
static func drop_landing_position(player: Node2D) -> Vector2:
	if not is_instance_valid(player):
		return Vector2.ZERO
	return player.global_position + drop_push_vector(player)


## 找一个可用落点：**不压进墙里**，且与已有地面掉落物保持 ≥min_gap。
## 先试基准点，再按环形由近及远扩散。`is_free` 可注入（默认走 Director 的可行走判定），
## 便于 harness 用假判定做单测。
##
## ⚠ 2026-09-25 用户实测「换武器时掉落物有时会掉进墙壁里」：
## 旧实现**只**做与其它掉落物的间距避让（`others.is_empty()` 时更是直接返回基准点），
## 完全不看地图碰撞；而基准点 = "玩家位置 + 朝向推远 40px"（drop_push_vector），
## 贴着墙换武器就会把掉落物推进墙里。
static func find_free_drop_position(tree: SceneTree, base: Vector2, min_gap: float = DROP_MIN_GAP,
		is_free: Callable = Callable()) -> Vector2:
	if tree == null:
		return base
	var free_check: Callable = is_free if is_free.is_valid() else _default_free_check(tree)
	var others: Array[Vector2] = []
	for n: Node in tree.get_nodes_in_group(PICKUP_GROUP):
		if n is Node2D and is_instance_valid(n) and not n.is_queued_for_deletion():
			others.append((n as Node2D).global_position)
	var radii: Array[float] = [0.0, min_gap, min_gap * 1.5, min_gap * 2.0]
	## 两轮：
	##  ① 既不在墙里、也满足间距（正常路径）
	##  ② 仅满足间距（放宽）—— 关键：可行走判定可能把**所有**候选都否掉
	##     （地图外/禁刷层/无地图的 harness），此时绝不能退化成"叠在别的掉落物上"，
	##     间距是硬不变量（09-25 实测：只有一轮时间距断言被打到 0px）。
	var require_free: bool = true
	for _round: int in 2:
		for radius: float in radii:
			for i: int in 8:
				var ang: float = TAU * float(i) / 8.0
				var cand: Vector2 = base + Vector2(cos(ang), sin(ang)) * radius
				if require_free and not bool(free_check.call(cand)):
					continue
				var ok: bool = true
				for o: Vector2 in others:
					if cand.distance_to(o) < min_gap - 0.01:
						ok = false
						break
				if ok:
					return cand
		require_free = false
	## 环形全部不可用（例如四面贴墙的角落）：退回基准点，保持旧行为而不是掉进墙里再乱飞。
	return base


## 默认"落点可用"判定：复用 Director 的可行走判定
##（含地图范围闸 / 作者禁刷层 / 图块碰撞多边形；无 Director 时不加限制）。
static func _default_free_check(tree: SceneTree) -> Callable:
	var director: Node = null
	if tree != null and tree.root != null:
		director = tree.root.get_node_or_null("Director")
	if director != null and director.has_method("is_drop_spot_free"):
		return Callable(director, "is_drop_spot_free")
	return func(_pos: Vector2) -> bool: return true


## 静态入口：把一把武器作为掉落物放到 player 附近（替换掉落 / 玩家主动丢弃共用）。
## 远程武器的弹夹与备弹一并转移到掉落物上（与替换掉落同规则）。
static func drop_weapon_for_player(player: Node2D, wd: WeaponData) -> Node2D:
	if wd == null or not is_instance_valid(player):
		return null
	var tree: SceneTree = player.get_tree()
	if tree == null:
		return null
	## 静态函数里不用 autoload 标识符（热重载/时序差异），走节点路径取 Players。
	var players: Node = player.get_node_or_null("/root/Players")
	var state: PlayerState = null
	if players and players.has_method("get_state_for_entity"):
		state = players.get_state_for_entity(player) as PlayerState
	var pickup: Node2D = PICKUP_SCENE.instantiate()
	apply_weapon_ground_display(pickup, wd)
	if state and wd.is_ranged and wd.magazine_capacity > 0:
		pickup.pickup_magazine_ammo = state.get_magazine_ammo(wd.item_id)
		state.weapon_magazines.erase(wd.item_id)
		var reserve: int = state.count_ammo_item(wd.ammo_item_id)
		if reserve > 0:
			pickup.pickup_reserve_ammo = reserve
			state.consume_ammo_item(wd.ammo_item_id, reserve)
	## 落点：沿玩家朝向推远 DROP_PUSH_DISTANCE（2026-09-23 用户：丢下的武器要离玩家
	## 远一些，避免刚脱手就被自己的自动拾取捡回），再做与已有掉落物的间距避让。
	var base: Vector2 = drop_landing_position(player)
	pickup.position = find_free_drop_position(tree, base)
	var parent: Node = null
	if tree.current_scene:
		parent = tree.current_scene.find_child("GroundLayer", true, false)
	if parent == null:
		parent = tree.current_scene if tree.current_scene else player.get_parent()
	if parent:
		parent.add_child(pickup)
	print("[拾取] %s 掉落在地上 (%s) | 弹夹=%d 备弹=%d" % [
		wd.item_name, pickup.position, pickup.pickup_magazine_ammo, pickup.pickup_reserve_ammo])
	return pickup


## 统一入口：地面显示参数从 WeaponData 读取（2026-09-13 用户反馈：
## 掉落物要完全按武器数据里的来——texture/char/direction/踏步节奏一致走武器配置）。
## texture 优先 pickup_texture，未配回退武器行走图；char_idx/direction/踏步参数
## 一律取武器数据当前值（未配置即脚本默认 char0/dir0，不再用举枪序列顶替）。
## random_pickup / item_manager / _drop_weapon 三条掉落路径共用。
static func apply_weapon_ground_display(pickup: Node2D, wd: WeaponData) -> void:
	pickup.weapon_data = wd
	pickup.pickup_texture = wd.pickup_texture if wd.pickup_texture else wd.weapon_walk_texture
	pickup.pickup_char_idx = wd.pickup_char_idx
	pickup.pickup_direction = wd.pickup_direction
	pickup.pickup_animated = wd.pickup_animated
	if wd.pickup_step_frames.size() > 0:
		pickup.pickup_step_frames = wd.pickup_step_frames
	if wd.pickup_step_duration > 0.0:
		pickup.pickup_step_duration = wd.pickup_step_duration


# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
## 以下四个导出带 setter：Inspector 里改贴图/索引/朝向即时刷编辑器预览，
## 无需重开场景（同 GradientLabel font_path_override 的 2026-09-14 修法）。
## 注意 weapon_data 只触发重绘、不自动套用地面显示参数 —— 自动套用会按
## 场景加载顺序覆盖手工调过的 pickup_texture（资源默认值陷阱）。
@export var weapon_data: WeaponData:           ## 要给予的武器资源
	set(v):
		weapon_data = v
		_refresh_sprite()
@export var pickup_texture: Texture2D:         ## 地上显示的精灵表
	set(v):
		pickup_texture = v
		_refresh_sprite()
@export var pickup_char_idx: int = 0:          ## 精灵表中的角色索引
	set(v):
		pickup_char_idx = v
		_refresh_sprite()
@export var pickup_direction: int = 0:         ## 朝向（0=下, 1=左, 2=右, 3=上）
	set(v):
		pickup_direction = v
		_refresh_sprite()

@export_group("拾取弹药")
## 拾取时给予的备弹数量（对应 weapon_data.ammo_item_id 的弹药物品）。
## 0 = 沿用武器数据里的 initial_reserve_ammo（掉落转移的旧备弹仍优先）。
@export var pickup_reserve_ammo: int = 0
## 拾取时弹夹内的子弹数（-1=自动填满弹夹容量，0=空弹夹）
@export var pickup_magazine_ammo: int = -1

## 2026-09-13 用户需求：开启后即使槽位为空也必须按住功能键(D)才拾取（进度环提示），
## 关闭（默认）保持「空槽触碰自动拾取」。随机掉落物可透传本选项。
@export var require_function_key: bool = false

## 在线联机中由 NetworkWorld 分配；0 表示离线旧逻辑。
var network_pickup_id: int = 0
## 地面放置物上限豁免：地图预摆的拾取物（含 random_pickup 预摆实例刷出的）不参与
## GroundItemCap(8) 计数与淘汰 —— 它们是关卡设计的一部分，不是掉落杂物。
## _ready 里按 owner 判定（编辑器摆进场景的实例 owner 非空）；动态刷出保持 false。
var cap_exempt: bool = false
var network_presentation_only: bool = false
var _network_pickup_request_pending: bool = false
var _network_request_msec: int = 0          ## 请求发出时刻（超时自愈用）
const NETWORK_REQUEST_RETRY_MS: int = 500


# ═══════════════════════════════════════
# 踏步动画
# ═══════════════════════════════════════
@export_group("Step Animation")
## 踏步帧序列（与玩家行走帧序列一致：frame1 → frame0 → frame1 → frame2）
@export var pickup_step_frames: Array[int] = [1, 0, 1, 2]
## 每帧持续时间（秒）
@export var pickup_step_duration: float = 0.25
## 是否启用踏步动画（关闭则始终显示序列第一帧）
@export var pickup_animated: bool = true


# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════
@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D


# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var _player_in_range: bool = false
var _player_ref: CharacterBody2D = null
var _hold_timer: float = 0.0
var _step_idx: int = 0           ## 当前踏步帧在 pickup_step_frames 中的索引
var _step_timer: float = 0.0     ## 踏步帧计时器
var _indicator_alpha: float = 0.0       ## 指示器当前透明度（用于淡入淡出）
var _indicator_node: Node2D = null      ## 指示器绘制子节点

const INDICATOR_SCRIPT := preload("res://script/hold_indicator.gd")
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


func _ready() -> void:
	add_to_group(WEAPON_PICKUP_GROUP)
	add_to_group(PICKUP_GROUP)
	if Engine.is_editor_hint():
		# 编辑器预览（@tool）：只按 pickup_texture/pickup_char_idx/pickup_direction 刷出
		# 48x64 裁帧，让摆点时能看见掉落物长相。不注册掉落上限、不连 Area2D、不建指示器。
		_refresh_sprite()
		return
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
		# 编辑器也跑踏步动画（2026-09-13 用户反馈：编辑器里不显示踏步动画）
		_process_step_animation(delta)
		return
	# 指示器每帧无条件刷新（2026-09-13 残留修复）：进度环淡入淡出不再依赖各分支
	# 自觉调用 —— 旧实现个别提前 return 路径会冻结 alpha，圆环以低透明度残留。
	var holding: bool = false
	if _is_online_network_pickup():
		holding = _process_network_pickup(delta)
		_process_step_animation(delta)
	else:
		_process_step_animation(delta)
		holding = _process_local_pickup(delta)
	_update_hold_indicator(delta, holding)
	_update_keycap_hint()


## ── D 键帽图标（2026-09-17 用户需求）──
## 玩家站在可使用（可拾取/可替换）的武器掉落物附近时，掉落物上方显示「D」键帽，
## 提示按住 D 拾取/替换。角色不可用的武器（can_use false）不显示。
const KEYCAP_KEY_TEXT := "D"

var _keycap_hint: Label = null


func _ensure_keycap_hint() -> void:
	if _keycap_hint != null and is_instance_valid(_keycap_hint):
		return
	var lbl := Label.new()
	lbl.name = "KeycapHint"
	lbl.text = KEYCAP_KEY_TEXT
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	## 键帽外观：深底 + 浅描边 + 圆角（fusion 12px 基底，键帽 16×14）
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
	var g: Node = get_node_or_null("/root/Global")
	if g and g.has_method("apply_hint_font"):
		g.apply_hint_font(lbl, 12)
	add_child(lbl)
	# 掉落物精灵约 48×64、原点在脚部 → 键帽悬在头顶上方
	lbl.position = Vector2(-11, -78)
	lbl.size = Vector2(22, 16)
	## 抬 z：键帽在 DecorLayer（画序上被 UpperLayer 图块覆盖）→ 提到单位层之上、
	## 黑幕(90)/ED(95)/章节总结(100) 之下（2026-09-17 用户反馈：被上层图块盖住）
	lbl.z_index = 10
	_keycap_hint = lbl


func _update_keycap_hint() -> void:
	if _player_in_range and _player_can_use():
		_ensure_keycap_hint()
		_keycap_hint.visible = true
	elif _keycap_hint != null and is_instance_valid(_keycap_hint):
		_keycap_hint.visible = false


func _process_local_pickup(delta: float) -> bool:
	## 单机拾取逻辑。返回本帧是否处于按住状态（供进度环刷新）。
	if not _player_in_range or not _player_ref:
		_hold_timer = 0.0
		return false
	if not weapon_data:
		return false

	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return false
	var slot: String = weapon_data.get_slot_key()
	var current: WeaponData = state.get_equipped_weapon(slot)

	# 该槽位为空 → 默认自动拾取；require_function_key 时同样走按住流程
	if current == null:
		if not require_function_key:
			if not _can_auto_take():
				return false
			mark_auto_picked(get_tree(), _player_ref)
			_do_pickup()
			return false
		return _process_hold(delta)

	return _process_hold(delta)


## 自动拾取闸门：① 本节点必须是离玩家最近的武器拾取物；
## ② 本次"靠近"还没自动捡过（走开再回来即可换下一件）—— 修"堆一起被全捡"；
## ③ 本角色能使用该武器（2026-09-16 用户：不能拿的武器路过也不自动捡）。
func _can_auto_take() -> bool:
	if not _is_nearest_weapon_pickup():
		return false
	if not _player_can_use():
		return false
	return auto_pickup_armed(get_tree(), _player_ref)


## 本角色是否可使用本拾取物武器（角色 allowed 列表）。玩家无效时放行（保持旧行为）。
func _player_can_use() -> bool:
	if not weapon_data:
		return true
	var pc: CharacterData = _player_ref.get("current_character") if is_instance_valid(_player_ref) else null
	if pc == null:
		return true
	return pc.can_use_weapon(weapon_data)


## 同点堆叠仲裁：只有离玩家最近的武器拾取物能动手（距离相同按实例 id 定序，保证唯一）。
func _is_nearest_weapon_pickup() -> bool:
	var player: Node2D = _player_ref
	if not is_instance_valid(player):
		return true   ## 拿不到玩家 → 不做仲裁，保持旧行为
	var my_d: float = global_position.distance_squared_to(player.global_position)
	for other: Node in get_tree().get_nodes_in_group(WEAPON_PICKUP_GROUP):
		if other == self or not is_instance_valid(other):
			continue
		if other.get("_player_in_range") != true:
			continue
		var other_node: Node2D = other as Node2D
		if other_node == null:
			continue
		var d: float = other_node.global_position.distance_squared_to(player.global_position)
		if d < my_d - 0.01:
			return false
		if absf(d - my_d) <= 0.01 and other.get_instance_id() < get_instance_id():
			return false
	return true


func _process_hold(delta: float) -> bool:
	## 按住功能键(D)的替换/拾取进度。返回是否按住中。
	if not _can_hold_pickup():
		_hold_timer = 0.0
		return false
	## 堆叠仲裁：长按进度也只给最近的一个（否则两把武器会同时读满进度、一起替换）。
	if not _is_nearest_weapon_pickup():
		_hold_timer = 0.0
		return false
	# 角色限制（2026-09-16 用户）：不能拿的武器按 D 无反应——不出进度环、不计进度
	if not _player_can_use():
		_hold_timer = 0.0
		return false
	# 救人优先（用户 2026-09-11）：附近有倒地队友时，功能键归救援用，不进入换武器长按
	if _downed_player_near():
		_hold_timer = 0.0
		return false

	if Input.is_action_pressed("功能键"):
		_hold_timer += delta
		if _hold_timer >= hold_time:
			_do_pickup()
			return false
		return true
	_hold_timer = 0.0
	return false



func _process_step_animation(delta: float) -> void:
	if pickup_animated and pickup_step_frames.size() > 0:
		_step_timer += delta
		if _step_timer >= pickup_step_duration:
			_step_timer -= pickup_step_duration
			_step_idx = (_step_idx + 1) % pickup_step_frames.size()
			_refresh_sprite()


func _is_online_network_pickup() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net and net.has_method("is_online_session") and bool(net.is_online_session())


func _process_network_pickup(delta: float) -> bool:
## 联机交互入口：本地只显示提示和发送意图，成功与否由 Host 的拾取事务决定。
	# 尚未收到 Host 的可靠 pickup_snapshot 前只能展示，不能执行本地拾取。
	if network_pickup_id <= 0:
		_hold_timer = 0.0
		return false
	var local_player := Players.get_local_entity() as CharacterBody2D
	var in_range := is_instance_valid(local_player) and local_player.global_position.distance_to(global_position) <= PICKUP_REACH
	_player_ref = local_player if in_range else null
	_player_in_range = in_range
	if not in_range or not weapon_data:
		_hold_timer = 0.0
		return false
	var state: PlayerState = Players.get_state_for_entity(local_player)
	var current: WeaponData = state.get_equipped_weapon(weapon_data.get_slot_key()) if state else null
	# 空槽 + 未要求功能键 → 直接请求；其余按住流程
	if current == null and not require_function_key:
		## 堆叠仲裁同样作用于联机请求：只让最近的一个发请求，且一次靠近只自动要一件。
		if not _can_auto_take():
			return false
		mark_auto_picked(get_tree(), local_player)
		_request_network_pickup()
		return false
	## ⚠ 联机下绝不能走单机 _process_hold → _do_pickup()：那会把武器塞进 Client
	## 本地域 PlayerState 并本地 queue_free —— Host 完全不知情，下一拍快照把
	## Host 域装备写回，表现为「拾到又消失 / 扔下后永远捡不上」（2026-09-22 实测）。
	## 这里用网络版按住：满进度只提交请求，事务在 Host。
	return _process_network_hold(delta)


## 附近（72px）是否有倒地队友：有则功能键优先用于救援（network_world 的 revive 流程）。
func _downed_player_near() -> bool:
	if not _player_ref:
		return false
	for p: Node2D in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p) or p == _player_ref:
			continue
		if p.get("network_downed") != true:
			continue
		if p.global_position.distance_to(_player_ref.global_position) <= 72.0:
			return true
	return false


func _request_network_pickup() -> void:
	if _network_pickup_request_pending:
		# 超时自愈（D2 实测）：Host 静默拒绝（距离不足/状态不符等无回执路径）时
		# 旧实现 pending 永久卡死 → 此后同物再也不发请求，表现为「不能再获取」。
		# 500ms 无回执即复位允许重发；Host 成功时该 pickup 会随快照消失，无副作用。
		if Time.get_ticks_msec() - _network_request_msec < NETWORK_REQUEST_RETRY_MS:
			return
		_network_pickup_request_pending = false
	_network_pickup_request_pending = true
	_network_request_msec = Time.get_ticks_msec()
	_hold_timer = 0.0
	var scene := get_tree().current_scene
	var world := scene.find_child("NetworkWorld", true, false) if scene else null
	if world and world.has_method("request_pickup"):
		# 带本机位置上报（滞后补偿）：Host 的拾取距离校验在权威坐标上做，
		# 客户端预测位置领先时会把「贴住掉落物」判成距离不足（实测高频失败）。
		var claim: Variant = _player_ref.global_position if is_instance_valid(_player_ref) else null
		world.request_pickup(network_pickup_id, claim)
	else:
		_network_pickup_request_pending = false


## 网络版按住流程：交互条件与单机 _process_hold 一致（仲裁/角色限制/救人优先），
## 但满进度只提交拾取请求，绝不本地入包。
func _process_network_hold(delta: float) -> bool:
	if not _can_hold_pickup():
		_hold_timer = 0.0
		return false
	if not _is_nearest_weapon_pickup():
		_hold_timer = 0.0
		return false
	if not _player_can_use():
		_hold_timer = 0.0
		return false
	if _downed_player_near():
		_hold_timer = 0.0
		return false
	if Input.is_action_pressed("功能键"):
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


## 与 healing_pickup 同款：Client 侧镜像被 NetworkWorld 判定为「Host 已不存在」时的
## 停用入口。修复前 weapon_pickup **缺此方法** → _apply_client_pickup_snapshot 的
## 清理分支只能退回 hide()，网络态（network_pickup_id / 请求闩锁 / 交互引用）
## 未被清掉；若该节点因复用路径未立即销毁，残留的 network_pickup_id 仍会向 Host
## 提交对已消失 id 的拾取请求。
func disable_network_pickup() -> void:
	visible = false
	network_pickup_id = 0
	network_presentation_only = false
	_network_pickup_request_pending = false
	_player_in_range = false
	_player_ref = null
	_hold_timer = 0.0
	if _area:
		_area.set_deferred("monitoring", false)
		_area.set_deferred("monitorable", false)

func _can_hold_pickup() -> bool:
	## 玩家在范围内即可拾取（不再限制武器举起/攻击状态）
	return _player_ref != null


func _update_hold_indicator(delta: float, is_holding: bool) -> void:
	## 更新按住进度指示器的淡入/淡出透明度，并触发重绘。
	## 2026-09-13 残留修复：只要 alpha 有变化或仍大于 0 就重绘；归零那帧的重绘
	## 会以 alpha<=0.001 早退 → 清空画布内容。旧实现重绘条件过窄，
	## 圆环可能停在最后一帧的低透明度画面上不再消失。
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

	# 背景圆环（完整一圈）
	var bg: Color = hold_indicator_bg_color
	bg.a *= _indicator_alpha
	node.draw_arc(center, radius, 0, TAU, pts, bg, thickness, true)

	# 进度弧线（顺时针从顶部 12 点钟方向开始填充）
	if progress > 0.0:
		var fg: Color = hold_indicator_color
		fg.a *= _indicator_alpha
		var start_angle: float = -PI / 2.0
		var end_angle: float = start_angle + progress * TAU
		node.draw_arc(center, radius, start_angle, end_angle, pts, fg, thickness, true)


func _do_pickup() -> void:
## 单机或 Host 已授权后的实际换装事务：处理空槽/替换、弹药补充和旧物掉落。
	if not weapon_data:
		return

	var state: PlayerState = Players.get_state_for_entity(_player_ref)
	if not state:
		return

	# 检查当前角色是否可以使用此武器
	var player_character: CharacterData = state.character
	if player_character and not player_character.can_use_weapon(weapon_data):
		print("[拾取] 角色 %s 无法使用 %s，拾取拒绝" % [player_character.character_name, weapon_data.item_name])
		_hold_timer = 0.0
		return

	var slot: String = weapon_data.get_slot_key()
	var old: WeaponData = state.get_equipped_weapon(slot)

	if old:
		_drop_weapon(old, slot)
		print("[拾取] 替换 %s 槽: %s → %s" % [slot, old.item_name, weapon_data.item_name])
	else:
		print("[拾取] 装备到 %s 槽: %s" % [slot, weapon_data.item_name])

	state.equip_weapon_in_slot(weapon_data, slot)

	# —— 弹药处理 ——
	# 弹夹子弹
	if weapon_data.is_ranged and weapon_data.magazine_capacity > 0:
		if pickup_magazine_ammo >= 0:
			# 使用指定的弹夹子弹数
			state.set_magazine_ammo(weapon_data.item_id, clampi(pickup_magazine_ammo, 0, weapon_data.magazine_capacity))
		else:
			# -1 = 自动填满弹夹
			state.set_magazine_ammo(weapon_data.item_id, weapon_data.magazine_capacity)

	# 备弹（库存弹药物品）：掉落转移的旧备弹优先，否则用武器数据的初始备弹
	var reserve: int = pickup_reserve_ammo if pickup_reserve_ammo > 0 else weapon_data.initial_reserve_ammo
	if reserve > 0 and not weapon_data.ammo_item_id.is_empty():
		var ammo_res: ItemData = _find_ammo_resource(state, weapon_data.ammo_item_id)
		if ammo_res:
			for _i: int in range(reserve):
				state.add_item(ammo_res.duplicate())
			print("[拾取] 给予备弹: %s ×%d" % [weapon_data.ammo_item_id, reserve])
		else:
			push_warning("[拾取] 找不到弹药资源: %s" % weapon_data.ammo_item_id)

	# 不自动进入武器举起状态，玩家按 Shift 自行举起
	## 拾取音效：武器数据（ItemData.pickup_sound）可配，留空用全局默认（2026-09-15）
	Global.play_pickup_sfx(weapon_data.pickup_sound, weapon_data.pickup_sound_pitch)
	queue_free()


func _drop_weapon(wd: WeaponData, _slot: String) -> void:
	## 替换掉落：交给静态入口统一处理（含落点避让，2026-09-16 用户反馈②）。
	## 远程武器的弹夹子弹和备弹一并转移到拾取物上（逻辑在 drop_weapon_for_player 里）。
	drop_weapon_for_player(_player_ref, wd)


func _find_ground_layer() -> Node:
	## 在当前场景中查找 GroundLayer 节点
	var tree: SceneTree = get_tree()
	if not tree or not tree.current_scene:
		return null
	return tree.current_scene.find_child("GroundLayer", true, false)


func _find_ammo_resource(state: PlayerState, ammo_item_id: String) -> ItemData:
	## 根据 ammo_item_id 找到对应的 ItemData 资源。
	## 先在 object/ 目录搜索 .tres 文件，回退到遍历该玩家背包。

	# 方案1：按命名规则推导路径
	var derived := "res://object/item_%s_ammo.tres" % ammo_item_id.trim_prefix("ammo_")
	if ResourceLoader.exists(derived):
		var res: Resource = load(derived)
		if res is ItemData and res.item_id == ammo_item_id:
			return res as ItemData

	# 方案2：也尝试直接用 item_id 拼接
	var direct := "res://object/item_%s.tres" % ammo_item_id
	if direct != derived and ResourceLoader.exists(direct):
		var res: Resource = load(direct)
		if res is ItemData and res.item_id == ammo_item_id:
			return res as ItemData

	# 方案3：从该玩家背包中找已有的弹药实例
	for it: Resource in state.inventory:
		if it is ItemData and it.item_id == ammo_item_id:
			return it as ItemData

	return null


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


func _refresh_sprite() -> void:
	# @onready 在编辑器预览路径可能未赋值（如手动触发），兜底按节点名取
	var sprite: Sprite2D = _sprite if _sprite else get_node_or_null("Sprite2D") as Sprite2D
	if not sprite or not pickup_texture:
		return

	sprite.texture = pickup_texture
	sprite.region_enabled = true

	# 当前踏步帧（动画关闭时用第一帧，即站立帧）
	# ⚠ 下标必须夹紧（09-23 实测崩溃 Out of bounds get index '3'）：同一节点会被
	# 快照复用给不同武器（apply_weapon_ground_display 先设 weapon_data → setter 立刻
	# 回调本函数，而 pickup_step_frames 要等函数末尾才换掉），期间 _step_idx 仍指向
	# 旧序列的下标 —— 旧序列 [1,0,1,2] 已走到 3，新序列（如平底锅 [0]）长度 1 → 越界。
	var frame: int
	if pickup_animated and pickup_step_frames.size() > 0:
		_step_idx = clampi(_step_idx, 0, pickup_step_frames.size() - 1)
		frame = pickup_step_frames[_step_idx]
	else:
		frame = pickup_step_frames[0] if pickup_step_frames.size() > 0 else 1

	var char_col: int = pickup_char_idx % CHARS_PER_ROW
	var char_row: int = pickup_char_idx / CHARS_PER_ROW

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + pickup_direction * FRAME_H
	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
