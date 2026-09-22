extends CharacterBody2D

## ── 架构定位 ──
## 系统：玩家实体 ｜ 层：玩法（CharacterBody2D）
## 联机：Host 权威 / Client 表现
## 职责：玩家实体：精灵表与动画、外观更新、朝向与固定朝向、受伤与死亡演出、拐角平滑移动入口，以及一整套联机表现接口。
## 依赖：CharacterData、PlayerState（经 Players）、StateMachine、NetworkWorld（联机）


## Host 伤害判定完成后由 NetworkWorld 转发给客户端的纯表现事件。
signal network_damage_applied(damage: float, position: Vector2, is_headshot: bool)

## 玩家角色 — CharacterBody2D + 状态机
##
## 状态机负责：移动输入、状态切换、物理速度
## 本脚本负责：精灵表/动画、外观更新、对外接口
##
## 状态列表：
##   Idle  → 站立不动
##   Walk  → 行走（按住 Ctrl）
##   Run   → 跑步（默认）
##   Pistol / Knife → 武器举起状态
##   PistolAttack / KnifeAttack → 攻击状态
##
## VX Ace 角色精灵布局（576×512, 4×2共8角色, 每角色3帧×4方向）
##
## 【三种运行模式】
## - 单机：StateMachine 读取本地输入，Player 自己移动、攻击、受伤并更新 PlayerState；
## - 联机 Host：NetworkWorld 提供已验证输入并驱动该实体，Player 仍负责动画/碰撞等实体表现；
## - 联机 Client：本地实体不执行权威战斗，只根据 NetworkWorld 快照更新位置、朝向、HP 和动画。
##
## 因此修改本脚本时，要先确认代码属于“玩法权威”还是“表现层”。涉及伤害、弹药、拾取、
## 投掷物和复活的联机入口应回到 NetworkWorld，不能让 Client 通过本地 Player 直接结算。
# ═══════════════════════════════════════
# 角色参数（行走图/HP/音效 → 由 CharacterData 驱动）
# ═══════════════════════════════════════
@export var current_character: CharacterData  ## 当前角色参数资源
## 以下变量由 _apply_character_data() 从 CharacterData 读取，不再 @export
var walk_texture: Texture2D = null
var walk_char_index: int = 0
var walk_frame_duration: float = 0.18
var run_texture: Texture2D = null
var run_char_index: int = 1
var run_frame_duration: float = 0.10
var max_hp: float = 200.0
var death_texture: Texture2D = null
var death_char_index: int = 7  ## 兜底默认（与 CharacterData 默认一致）；实际值由 CharacterData.death_char_index 覆盖（Inspector 可配，四角色现配 6）
var hurt_sound: AudioStream = null
var death_sound: AudioStream = null

# ═══════════════════════════════════════
# 移动参数
# ═══════════════════════════════════════
@export var walk_speed: float = 150.0
@export var run_speed: float = 250.0

# ═══════════════════════════════════════
# 移动手感：像素级蹭墙 / 拐角平滑（corner assist）
# ═══════════════════════════════════════
## 像素级自由移动下，24×27 的碰撞矩形与 32×32 图块不成整数倍，贴墙走向门框时只要
## 横向错位一两像素就会被凸角顶住。本组参数控制「蹭过去」的手感：某一轴的位移被挡住时，
## 沿**另一轴**做限速小位移，把角色慢慢蹭到能通过的位置 —— 观感是贴着门框平滑挪进去
## （以撒的结合那种蹭墙），而不是一帧瞬移或者干脆卡死。
## 算法本体在 `script/corner_assist.gd`（与敌人共用）。
@export var corner_assist_enabled: bool = true
## 侧移速度上限（像素/秒）。越小越"轻微"：120 ≈ 每帧 2px，180 ≈ 每帧 3px
@export var corner_assist_speed: float = 180.0
## 侧移试探的最大距离（像素）。**不要随意调大**：上限越大，辅助越容易为了满足一个很小的
## 横向位移而把角色整体挪很远 —— 实测上限 20 时出现过"为了让 1px/帧 的横向位移通过，
## 把角色竖向挪 20px"的荒谬修正。半格（16px）已足够覆盖 24 宽角色进 32 门洞所需的全部对齐量。
@export var corner_assist_max_shift: float = 16.0
## 侧移试探步长（像素）。越小越精细，代价是试探次数增加
@export var corner_assist_step: float = 2.0
## 侧移方向优先跟随玩家入力的一侧（不跟玩家较劲）。关闭后一律优先正向
@export var corner_assist_follow_input: bool = true
## 参与蹭墙探测的碰撞层位掩码。默认仅「图块」层（bit 1）—— 蹭墙只针对静态墙面，
## 不被敌人 / 掉落物 / 其他玩家干扰。本作导演持续在玩家身边刷怪，若沿用完整掩码
## （15，含敌人层）会让探测被路过的丧尸判为阻挡，表现为"时不时没效果"。
@export var corner_assist_world_mask: int = CornerAssist.WORLD_LAYER_BIT

# ═══════════════════════════════════════
# 战斗参数
# ═══════════════════════════════════════
@export_group("受击碰撞体")
@export var hurtbox_size: Vector2 = Vector2(28, 44)  ## 受击碰撞体尺寸
@export var hurtbox_offset: Vector2 = Vector2(0, -8)  ## 受击碰撞体偏移（相对角色原点）

@export_group("受击反馈")
## 受击反馈模式：0=闪（瞬间变色→逐渐恢复），1=渐隐（变色→渐渐消失）
@export var hit_feedback_mode: int = 0
## 受击反馈持续时间（秒）
@export var hit_feedback_duration: float = 0.5

# ═══════════════════════════════════════
# 死亡（黑屏时长参数见 Global 单例：death_fade_duration / death_black_hold）
# ═══════════════════════════════════════

# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48   ## 576 / 12
const FRAME_H: int = 64   ## 512 / 8
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

## VX Ace 帧序列: frame1 → frame0 → frame1 → frame2 → frame1（循环）
const WALK_SEQUENCE: Array[int] = [1, 0, 1, 2]
const STAND_FRAME: int = 1

## 方向 → 行偏移（VX Ace: 下/左/右/上）
const DIR_ROWS: Array[int] = [0, 1, 2, 3]
const DAMAGE_SOURCE_COOLDOWN_MSEC: int = 1000  ## 同一伤害源重复命中冷却（毫秒）

enum FaceDir { DOWN = 0, LEFT = 1, RIGHT = 2, UP = 3 }

# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════
@onready var sprite: Sprite2D = $Sprite2D
@onready var animation_timer: Timer = $AnimationTimer
@onready var hurt_area: Area2D = _setup_hurt_area()

# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var _facing: int = FaceDir.DOWN
var _facing_locked: bool = false
var _locked_facing: int = FaceDir.DOWN
var _anim_step: int = 0
var _moving: bool = false
var _is_walking: bool = false   ## 当前外观是行走(true)还是跑步(false)
var _weapon_mode: bool = false  ## 是否处于武器举起模式
var _weapon_data: WeaponData = null
var _current_weapon_char_idx: int = 0  ## 当前武器模式下使用的角色索引
var player_in_weapon_state: bool = false  ## 供 menu_controller 检查菜单屏蔽
var _throwable_mode: bool = false           ## 是否处于投掷物举起模式（使用投掷物行走图）
var _throwable_texture: Texture2D = null    ## 投掷物举起行走图精灵表
var _throwable_char_idx: int = 0            ## 投掷物举起行走图角色索引
var _network_throw_aim_indicator: Node2D = null
const THROW_AIM_INDICATOR_SCRIPT := preload("res://script/throw_aim_indicator.gd")
## _near_pickup 已废除（2026-09-13）：武器替换改「按住功能键(D)」，拾取物旁点按 Z 照常攻击。
var _switch_on_death_attempted: bool = false  ## 是否已尝试死亡切换
var current_hp: float = 200.0

## 联机阶段 1：NetworkWorld 持有世界权威，Player 仅负责碰撞与表现。
var network_entity_id: int = 0
var network_owner_peer_id: int = 0
var network_controlled: bool = false
## 联机倒地：HP=0 但仍可被队友救援（由 NetworkWorld 权威写入）。
## 表现与死亡同为躺地精灵，区别是保留移动碰撞（缓慢爬行）与红色染色。
var network_downed: bool = false
## true 表示本实体由 NetworkWorld 管理；单机实体才允许走 Players 注册和本地状态机。
## true 表示本实体由 NetworkWorld 管理；单机实体才允许走 Players 注册和本地状态机。
## 本地客户端实体开启预测；Host 仍是最终权威，快照只用于纠偏。
var network_local_prediction: bool = false
var network_local_player: bool = false
var _network_target_position: Vector2 = Vector2.ZERO
var _network_has_target: bool = false
var _network_prediction_initialized: bool = false
## 本地预测纠偏参数（09-22 实测调优）：小偏差走帧率无关的指数收敛，避免恒定速度
## 拖拽造成的「莫名短距离瞬移」；超过 SNAP 距离（丢包/传送）才硬校准；DEAD_ZONE 内
## 视为已对齐并清除目标。
const NETWORK_CORRECTION_SNAP_DISTANCE := 96.0
const NETWORK_CORRECTION_DEAD_ZONE := 0.5
const NETWORK_CORRECTION_MOVE_RATE := 10.0
## 静止时的收敛速率（09-22 实测定案）：动作（挥刀/推击/拾取）都发生在静止瞬间，
## 而 Host 的命中查询/距离校验按权威坐标做 —— 移动中保持平滑预测（消除瞬移感），
## 一旦停下就快速收敛到权威坐标，保证动作时刻两端坐标一致（旧行为靠每拍硬设
## 位置实现了这一点，代价是移动中的抖动；现在两者兼得）。
const NETWORK_CORRECTION_IDLE_RATE := 60.0
## 远端玩家位置插值：快照样本按固定延迟渲染，取代旧的指数平滑
## （旧的每帧 lerp 会让客户端视角下的主机玩家起停带"摩擦力"观感）。
const NETWORK_SNAPSHOT_INTERP := preload("res://script/network_snapshot_interp.gd")

## 武器拾取物脚本（静态工具：drop_weapon_for_player —— E 键全丢武器共用）
const WEAPON_PICKUP_SCRIPT := preload("res://script/weapon_pickup.gd")

## 玩家位置快照以 60Hz+ 到达，50ms 延迟足以覆盖抖动且几乎无感。
const NETWORK_RENDER_DELAY := 0.05
var _remote_interp: Variant = null
var _network_attack_token: int = 0
var _network_reload_was_facing_locked: bool = false

var _tp_regen_timer: float = 0.0

# ── SA（说明书 §6.1 特殊行动）运行时 ──
var _sa_crouch_active: bool = false      ## しゃがみ回避进行中（无敌）
var _sa_crouch_until_msec: int = 0       ## 无敌截止时间
var _sa_crouch_skill: SkillData = null   ## 当前しゃがみ技能（取持续消耗参数）
var _network_sa_crouch_hold: bool = false ## C2：Host 权威实体的しゃがみ按住登记（sa_crouch_hold RPC 写入）
var _sa_auto_mukiri_until_msec: int = 0  ## 感覚向上：完全见切截止时间

# ── 见切/反击（说明书 §4.3）运行时 ──
const MUKIRI_WINDOW_MS: int = 300        ## 见切判定窗口（原作 0.3 秒，"大甘"）
const MUKIRI_INTERVAL_MS: int = 700      ## 两次见切输入的最小间隔（原作 0.7 秒）
const COUNTER_COOLDOWN_MS: int = 1000    ## 反击触发冷却，防一次窗口内重复触发
var _mukiri_window_until_msec: int = 0      ## 见切窗口截止时间
var _mukiri_last_attempt_msec: int = -10000 ## 上次见切输入时间
var _counter_cooldown_until_msec: int = 0   ## 反击冷却截止时间
var _mukiri_anim_busy: bool = false         ## 见切动画播放中（防重入）

# ── Heat / 削り（原作说明书 §4.6）──
const HEAT_DURATION: float = 6.0            ## Heat 持续秒数（原作未公开精确值，按体感）
const ATTRITION_AMMO: int = 2               ## 削り：弹夹每次 -2
const ATTRITION_DURABILITY: float = 8.0     ## 削り：耐久每次 -8
var _heat_time: float = 0.0                 ## Heat 剩余时间（>0=禁止见切/TP停/Guts停）

# ── 覚醒コマンド（原作：構え中 Z+X；のび太=集中射撃）──
const AWAKEN_TP_DRAIN_PER_SEC: float = 5.0  ## 发动中 TP 缓慢消耗（原作「徐々にTPを消費」）
const AWAKEN_DAMAGE_MULT: float = 1.5       ## 射撃威力上升倍率
const AWAKEN_BOSS_DAMAGE_MULT: float = 1.5  ## 即死对 Boss 无效 → 改为伤害 ×1.5（原作必殺对 Boss 同规则）
const AWAKEN_HITSTUN_SEC: float = 0.8       ## 怯み时长（Boss 吃怯み不吃即死）
var _awaken_active: bool = false            ## 覚醒发动中（集中射撃）
var _awaken_tint_applied: bool = false      ## 觉醒金色染色是否已上（还原时区分 Heat 染色）

## 搓招方向输入缓冲
const MOTION_DIRS: Array[String] = ["上", "下", "左", "右"]
const MOTION_BUFFER_MAX: int = 8
var _motion_buffer: Array[String] = []

## 推击相关
var _shove_mode: bool = false           ## 是否处于推击模式（使用推击行走图）
var _shove_texture: Texture2D = null    ## 当前推击行走图（角色优先，回退武器）

## 推击疲劳（L4D2 风格：连续推击 N 次→冷却 2 秒）
var _shove_fatigue_count: int = 0       ## 连续推击计数
var _shove_cooldown_timer: float = 0.0  ## 冷却倒计时（>0=冷却中）
var _shove_idle_timer: float = 0.0      ## 自上次推击以来的空闲时间

## 死亡相关
var _is_dying: bool = false
var _recent_damage_sources: Dictionary = {}    ## source_id → hit_time_msec（防同一源头重复判定）
var _death_fade_timer: float = 0.0
var _death_phase: int = 0  ## 0=死亡动画, 1=渐黑, 2=全黑等待, 3=重载
var _death_fade_overlay: ColorRect = null

## 暴露朝向（供攻击状态计算子弹方向和近战偏移）
var facing: int:
	get:
		return _facing


func _ready() -> void:
## 初始化实体表现并绑定单机座位。network_controlled 实体由 NetworkWorld 接管，不能注册到单机 active_seat。
	add_to_group("player")
	_remote_interp = NETWORK_SNAPSHOT_INTERP.new(NETWORK_RENDER_DELAY)
	# NetworkWorld 会在实体加入场景前预先标记动态玩家；此处绝不能把它们
	# 错绑到单人 active_seat。
	if not network_controlled:
		Players.register_entity(self)
		_apply_character_data()
	else:
		_apply_current_character_data(current_character)
		_disable_network_state_machine()

	if walk_texture == null:
		walk_texture = load("res://art/Characters/のび太セット.png") as Texture2D
	if run_texture == null:
		run_texture = load("res://art/Characters/のび太歩行セット.png") as Texture2D

	# 俯视角：浮动模式，所有碰撞都是墙壁
	motion_mode = MOTION_MODE_FLOATING

	animation_timer.wait_time = _mode_anim_duration(true)
	animation_timer.timeout.connect(_on_animation_timer_timeout)
	animation_timer.start()
	_refresh_sprite()

	# 从本实体对应座位恢复 HP（用于存档加载后）。联机实体的状态由
	# NetworkWorld 在 spawn / snapshot 时写入，不能在这里触碰 Players 映射。
	if not network_controlled:
		var state: PlayerState = Players.get_state_for_entity(self)
		if state and state.current_hp > 0.0:
			current_hp = state.current_hp
		else:
			current_hp = max_hp
			if state:
				state.current_hp = current_hp
	else:
		current_hp = max_hp


func _exit_tree() -> void:
	Players.unregister_entity(self)


# ═══════════════════════════════════════
# 移动入口（像素级蹭墙 / 拐角平滑）
# ═══════════════════════════════════════

## 带蹭墙辅助的移动入口 —— 玩家侧移动一律使用本方法替代 `move_and_slide()`。
##
## 所有玩家状态的物理帧移动都应调用本方法（而不是直接 move_and_slide），
## 以保证单机、联机 Host 权威模拟、联机本地预测三种路径下手感完全一致。
## 算法本体与两个关键坑的说明见 `script/corner_assist.gd`。
func move_with_corner_assist() -> void:
	CornerAssist.move_with_assist(self, velocity,
		corner_assist_enabled, corner_assist_speed, corner_assist_max_shift,
		corner_assist_step, corner_assist_follow_input, corner_assist_world_mask)


func _setup_hurt_area() -> Area2D:
	## 创建受击碰撞体（Area2D + RectangleShape2D），位于独立的 hurtbox 层
	var area := Area2D.new()
	area.name = "HurtArea"
	area.collision_layer = 16   ## Layer 5 — hurtbox 层
	area.collision_mask = 0     ## 不需要检测任何东西

	var shape := CollisionShape2D.new()
	shape.name = "HurtShape"
	var rect := RectangleShape2D.new()
	rect.size = hurtbox_size
	shape.shape = rect
	shape.position = hurtbox_offset
	area.add_child(shape)

	add_child(area)
	return area


func _process(delta: float) -> void:
	_update_burn_status(delta)  # 灼烧 DoT（本机/远端实体均结算，死态内部早退）
	if network_controlled:
		_update_shove_fatigue(delta)
		_update_tp_regen(delta)
		# 覚醒（C1）：联机实体（Host 权威实体 / Client 本地预测实体）也持续推进
		# TP 扣费与自动解除——与 _update_tp_regen 同款「数值型每帧更新」模式；
		# 各实体解析各自域的 PlayerState（Host 权威 / Client 本地显示），同速同规则。
		_update_awaken(delta)
		# SA/见切/反击（C2）：联机实体的 Heat 计时、しゃがみ维持（按住延长 + TP
		# 消耗）与超时结束——Host 权威实体读 RPC 登记的按住 flag，Client 本地
		# 实体直读本机键盘，双域同规则（详见 _update_network_sa_state 注释）。
		_update_network_sa_state(delta)
		# 本地预测实体由 NetworkWorld 在物理帧直接移动；权威快照只提供纠偏目标，
		# 绝不直接写位置 —— 否则预测位置被反复拉回权威坐标，表现为拖影/顿挫。
		if network_local_prediction and not _is_dying and _network_has_target:
			var error := _network_target_position - global_position
			var error_length := error.length()
			if error_length > NETWORK_CORRECTION_SNAP_DISTANCE:
				# 大偏差（丢包/传送/切图残留）才硬校准
				global_position = _network_target_position
				_network_has_target = false
			elif error_length <= NETWORK_CORRECTION_DEAD_ZONE:
				_network_has_target = false
			else:
				# 小偏差（LAN 稳态 ≈ 速度×RTT，通常 < 5px）：帧率无关的指数收敛。
				# 旧实现用恒定速度拖拽（移动中 480 / 停止后 720 px/s），误差稍大时
				# 玩家位置会被"拽"过去 → 观感为「莫名短距离瞬移」（09-22 实测）。
				# 指数收敛起步快、尾段柔和，且与帧率解耦。
				var moving_now := not velocity.is_zero_approx()
				var rate := NETWORK_CORRECTION_MOVE_RATE if moving_now else NETWORK_CORRECTION_IDLE_RATE
				global_position += error * (1.0 - exp(-rate * delta))
		elif not network_local_prediction and not _is_dying and _network_has_target:
			# 远端玩家：按固定延迟在两个快照样本间插值，起停干脆、匀速贴合。
			var render_position: Variant = _remote_interp.sample_render_position()
			if render_position != null:
				global_position = render_position
		return
	if _is_dying:
		_process_death(delta)
	_update_shove_fatigue(delta)
	_update_tp_regen(delta)
	_update_motion_input()
	_update_sa_state(delta)


func _on_animation_timer_timeout() -> void:
	if _moving:
		_anim_step = (_anim_step + 1) % WALK_SEQUENCE.size()
	_refresh_sprite()


# ═══════════════════════════════════════
# 联机表现接口（由 NetworkWorld 调用）
# ═══════════════════════════════════════

## 在加入场景前或场景运行时将此 Player 切换为 Host 权威实体。
func configure_network_entity(entity_id: int, owner_peer_id: int) -> void:
	network_entity_id = entity_id
	network_owner_peer_id = owner_peer_id
	network_controlled = true
	network_local_prediction = false
	velocity = Vector2.ZERO
	if is_node_ready():
		_disable_network_state_machine()


## 写入可靠 spawn / world snapshot 的初始表现数据。
func apply_network_spawn_state(character: CharacterData, hp: float, new_position: Vector2, new_facing: int, snap: bool = true) -> void:
	if character:
		current_character = character
		_apply_current_character_data(current_character)
	current_hp = clampf(hp, 0.0, max_hp)
	if network_local_prediction:
		apply_network_local_spawn_position(new_position)
	apply_network_presentation(new_position, new_facing, false, false, snap)


func set_network_local_prediction(enabled: bool) -> void:
	network_local_prediction = enabled
	if enabled:
		_network_has_target = false
		_network_prediction_initialized = false


func reset_network_prediction_sync() -> void:
	if network_local_prediction:
		_network_has_target = false
		_network_prediction_initialized = false


func apply_network_local_spawn_position(new_position: Vector2) -> void:
	if not network_local_prediction or _network_prediction_initialized:
		return
	global_position = new_position
	_network_target_position = new_position
	_network_has_target = false
	_network_prediction_initialized = true


## 仅更新客户端可见状态。Host 传 snap=true，客户端由 _process 平滑插值。
func apply_network_presentation(new_position: Vector2, new_facing: int, moving: bool, walking: bool, snap: bool = false) -> void:
	if not (network_local_player and _facing_locked):
		_facing = clampi(new_facing, FaceDir.DOWN, FaceDir.UP)
	if _is_dying:
		# 对齐 Host 权威死亡坐标，并丢弃死亡前尚未完成的插值目标。
		global_position = new_position
		_network_target_position = new_position
		_network_has_target = false
		_remote_interp.reset(new_position)
		return
	update_appearance(moving, walking)
	if network_local_player and not network_local_prediction:
		# 非预测的本地玩家（历史兼容路径）：直接对齐权威坐标。
		global_position = new_position
		_network_target_position = new_position
		_network_has_target = false
		_remote_interp.reset(new_position)
		return
	# 本地预测玩家的位置由本地输入驱动；快照只提供首次校准和后续平滑纠偏目标。
	# ⚠ 旧实现先命中 `network_local_player` 分支无条件硬写位置（本地预测玩家两个标志
	# 都为 true）→ 与 NetworkWorld._predict_client_local_movement 的本地模拟每拍互相
	# 覆盖，表现为客户端自己看自己的「卡顿/残影/短距离瞬移」（09-22 实测）。
	if snap:
		_remote_interp.reset(new_position)
		global_position = new_position
		_network_target_position = new_position
		_network_has_target = false
	else:
		# 只更新纠偏目标 —— 绝不在本函数里硬写预测位置：旧实现在
		# `_network_has_target == false`（=上一拍纠偏已收敛）时直接贴位置，
		# 于是每拍 60Hz 微跳一次，正是「莫名短距离瞬移」的观感来源。
		_remote_interp.push_sample(new_position)
		_network_target_position = new_position
		_network_has_target = true


## 该实体是否已进入快照驱动的位置跟踪（收到过至少一次移动样本）。
## NetworkWorld 用它区分"首次校准"（硬定位）与"定期可靠重同步"（软并流）。
func has_network_position_tracking() -> bool:
	return _network_has_target


## 本地预测玩家专用：把 Host 权威坐标登记为纠偏目标，绝不直接写位置。
## 位置仍由本地输入驱动（_physics_process 预测），_process 按偏差平滑收敛。
## 朝向在有本地移动输入时由预测立即驱动、不回写；静止或被锁定时以权威值为准 ——
## 脚本化输入（回归测试直接 submit_input）没有本地按键，锁定向/转向都依赖这一路。
func apply_network_authority_target(authority_position: Vector2, authority_facing: int) -> void:
	if not network_local_prediction or _is_dying:
		return
	_network_target_position = authority_position
	_network_has_target = true
	if not _facing_locked and velocity.is_zero_approx():
		_facing = clampi(authority_facing, FaceDir.DOWN, FaceDir.UP)


## 定期可靠重同步（约 2 秒一次）专用的软校准。
## 已在平滑渲染的实体绝不能被可靠包硬切位置/重置行走动画 ——
## 那是客户端每 2 秒"一顿"、动画相位反复重启的根源。位置并入插值样本流；
## 仅当与当前渲染位置偏差超过阈值（传送/漂移兜底）时才硬校准。
const NETWORK_RESYNC_SNAP_DISTANCE := 96.0


func apply_network_resync_state(resync_character: CharacterData, new_position: Vector2, new_facing: int) -> void:
	if resync_character and current_character != resync_character:
		current_character = resync_character
		_apply_current_character_data(current_character)
		_refresh_sprite()
	if not (network_local_player and _facing_locked):
		_facing = clampi(new_facing, FaceDir.DOWN, FaceDir.UP)
	if _is_dying:
		# 尸体没有平滑渲染：直接对齐权威死亡坐标。
		global_position = new_position
		_network_target_position = new_position
		_network_has_target = false
		_remote_interp.reset(new_position)
		return
	if network_local_player and network_local_prediction:
		_network_target_position = new_position
		_network_has_target = true
		return
	if global_position.distance_to(new_position) > NETWORK_RESYNC_SNAP_DISTANCE:
		_remote_interp.reset(new_position)
		global_position = new_position
	else:
		_remote_interp.push_sample(new_position)
	_network_target_position = new_position
	_network_has_target = true


func is_network_dead() -> bool:
	return _is_dying


## 联机倒地：HP=0 但仍可被救援。躺地表现与死亡相同，但保留移动碰撞
## （倒地爬行不能穿墙）；受击区保持关闭 —— 倒地期间免伤，流血是唯一扣血来源。
func is_network_downed() -> bool:
	return network_downed


func set_network_downed(enabled: bool) -> void:
	if network_downed == enabled:
		return
	network_downed = enabled
	if sprite:
		sprite.modulate = Color(1.0, 0.55, 0.55) if enabled else Color.WHITE
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", enabled == false)
	if enabled and hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)
	print("[玩家] 联机倒地状态: %s" % str(enabled))


func apply_network_health_state(new_hp: float, is_dead: bool, play_feedback: bool = true) -> void:
	var previous_hp := current_hp
	current_hp = clampf(new_hp, 0.0, max_hp)
	var state: PlayerState = Players.get_state_for_entity(self)
	if state:
		state.current_hp = current_hp
	if is_dead or current_hp <= 0.0:
		current_hp = 0.0
		if not _is_dying:
			_apply_network_death_state()
		return
	if _is_dying:
		apply_network_revive_state(current_hp)
	if play_feedback and current_hp < previous_hp:
		var damage := previous_hp - current_hp
		_play_hit_feedback(Color.RED)
		var tree := get_tree()
		if tree and tree.current_scene:
			DamageNumber.spawn(global_position, damage, tree.current_scene, 0, Color(1.0, 0.25, 0.2))
		_play_sound(hurt_sound)


func apply_network_revive_state(hp: float) -> void:
	if not network_controlled:
		return
	current_hp = clampf(hp, 1.0, max_hp)
	var state: PlayerState = Players.get_state_for_entity(self)
	if state:
		state.current_hp = current_hp
	_is_dying = false
	_death_phase = 0
	_death_fade_timer = 0.0
	_moving = false
	player_in_weapon_state = false
	velocity = Vector2.ZERO
	# 不继承死亡前的网络移动插值；下一个快照会重新建立有效目标。
	_network_target_position = global_position
	_network_has_target = false
	_remote_interp.reset(global_position)
	exit_shove_mode()
	exit_throwable_mode()
	# 复活即脱离倒地：先清倒地标记（恢复普通染色）。
	# set_network_downed(false) 会排队一次"关闭碰撞"的 deferred 写入，
	# 紧随其后的碰撞/受击区重新启用也是 deferred —— Godot 按先进先出执行，
	# 因此最终状态一定是"碰撞开启、受击区开启"，顺序不能颠倒。
	set_network_downed(false)
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", false)
	if hurt_area:
		hurt_area.set_deferred("monitoring", true)
		hurt_area.set_deferred("monitorable", true)
	if animation_timer:
		animation_timer.start()
	_refresh_sprite()
	print("[玩家] 联机救援复活 HP=%.1f" % current_hp)


func _disable_network_state_machine() -> void:
	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)

# ═══════════════════════════════════════
# 供 State 调用的公开方法
# ═══════════════════════════════════════

## 当前移动档的动画帧时长（秒）：CharacterData 值 >0 = 手动固定；0 = 按全局基准
## （150px/s↔0.18s）与当前档速度自动换算——速度越快帧间隔越短（2026-09-15 统一公式）。
func _mode_anim_duration(is_walking: bool) -> float:
	var manual: float = walk_frame_duration if is_walking else run_frame_duration
	if manual > 0.0:
		return manual
	var speed: float = walk_speed if is_walking else run_speed
	return clampf(Global.ANIM_BASE_FRAME_DURATION * Global.ANIM_BASE_SPEED / maxf(speed, 1.0), 0.05, 0.5)


## 更新外观：移动状态 + 行走/跑步模式
func update_appearance(moving: bool, is_walking: bool) -> void:
	var changed: bool = (_moving != moving) or (_is_walking != is_walking)
	_moving = moving
	_is_walking = is_walking

	if changed:
		_anim_step = 0
		if animation_timer:
			animation_timer.wait_time = _mode_anim_duration(is_walking)
			animation_timer.start()   ## 重启 timer，新间隔立即生效

	_refresh_sprite()


## 根据移动方向更新朝向
func update_facing(move_dir: Vector2) -> void:
	if _facing_locked:
		if _facing != _locked_facing:
			_facing = _locked_facing
			_refresh_sprite()
		return
	var new_facing: int
	if abs(move_dir.x) > abs(move_dir.y):
		new_facing = FaceDir.RIGHT if move_dir.x > 0 else FaceDir.LEFT
	else:
		new_facing = FaceDir.DOWN if move_dir.y > 0 else FaceDir.UP
	if new_facing != _facing:
		_facing = new_facing
		_refresh_sprite()


# ═══════════════════════════════════════
# 武器模式
# ═══════════════════════════════════════

func enter_weapon_mode(wd: WeaponData) -> void:
	_weapon_mode = true
	_weapon_data = wd
	_current_weapon_char_idx = wd.get_raise_char_sequence()[0]
	if animation_timer:
		animation_timer.wait_time = _mode_anim_duration(true)
		animation_timer.start()
	_refresh_sprite()


func exit_weapon_mode() -> void:
	_weapon_mode = false
	_weapon_data = null
	_current_weapon_char_idx = 0
	# 放下武器 → 覚醒解除（原作觉醒是构势系状态，武器收起即失效）
	_deactivate_awaken()
	_refresh_sprite()


## 设置举起/放下动画帧（使用 weapon_raise_char_sequence 中的索引）
func set_weapon_frame(idx: int) -> void:
	if _weapon_data:
		_current_weapon_char_idx = _weapon_data.get_raise_char_sequence()[idx]
	_refresh_sprite()


## 设置武器就绪帧（举起序列的最后一帧）
func set_weapon_ready_frame() -> void:
	if _weapon_data:
		var seq: Array[int] = _weapon_data.get_raise_char_sequence()
		_current_weapon_char_idx = seq[seq.size() - 1]
	_refresh_sprite()


## 设置攻击动画的角色索引（直接使用 char_idx 值）
func set_attack_char_index(char_idx: int) -> void:
	_current_weapon_char_idx = char_idx
	_refresh_sprite()


## 联机举起/放下必须由 Host 确认后播放，过渡期间 NetworkWorld 会锁住其他战斗输入。
func play_network_weapon_transition(wd: WeaponData, raising: bool) -> void:
	if not wd:
		return
	_network_attack_token += 1
	var token := _network_attack_token
	enter_weapon_mode(wd)
	player_in_weapon_state = true
	# 网络举放只改变武器动画，不修改玩家原本的朝向锁定状态。
	call_deferred("_run_network_weapon_transition", token, wd, raising)


func _run_network_weapon_transition(token: int, wd: WeaponData, raising: bool) -> void:
	var sequence: Array[int] = wd.get_raise_char_sequence()
	if not raising:
		unlock_facing()
		set_weapon_ready_frame()
	var start_index := 1 if raising else sequence.size() - 2
	var end_index := sequence.size() if raising else -1
	var step := 1 if raising else -1
	var index := start_index
	while index != end_index:
		if token != _network_attack_token or not is_inside_tree():
			return
		set_attack_char_index(sequence[index])
		await get_tree().create_timer(wd.get_raise_frame_duration(index)).timeout
		index += step
	if token != _network_attack_token or not is_inside_tree():
		return
	if raising:
		set_weapon_ready_frame()
	else:
		exit_weapon_mode()
	player_in_weapon_state = false


## 联机攻击只负责本地表现；子弹、弹药和伤害均由 NetworkWorld 的 Host 权威处理。
## 远程和近战共用此入口，命中时机则按对应 WeaponData 的配置播放效果。
func play_network_attack_presentation(wd: WeaponData) -> void:
	if not wd:
		return
	_network_attack_token += 1
	var token := _network_attack_token
	enter_weapon_mode(wd)
	player_in_weapon_state = true
	call_deferred("_run_network_attack_presentation", token, wd)


## 保留旧名称，避免外部调用点在逐步迁移期间失效。
func play_network_fire_presentation(wd: WeaponData) -> void:
	play_network_attack_presentation(wd)


## 联机装填表现只由 Host 的确认事件触发；弹药真实值仍由 NetworkWorld 快照收敛。
func play_network_reload_presentation(wd: WeaponData, loaded_count: int) -> void:
	if not wd:
		return
	_network_attack_token += 1
	var token := _network_attack_token
	_network_reload_was_facing_locked = is_facing_locked()
	enter_weapon_mode(wd)
	player_in_weapon_state = true
	if _network_reload_was_facing_locked:
		lock_facing()
	call_deferred("_run_network_reload_presentation", token, wd, maxi(1, loaded_count))


## 推击同样只由 Host 确认后播放；真实击退判定不在此节点执行。
func play_network_shove_presentation(wd: WeaponData) -> void:
	if not wd:
		return
	_network_attack_token += 1
	var token := _network_attack_token
	enter_weapon_mode(wd)
	player_in_weapon_state = true
	enter_shove_mode()
	lock_facing()
	call_deferred("_run_network_shove_presentation", token, wd)


func _run_network_shove_presentation(token: int, wd: WeaponData) -> void:
	for index: int in range(wd.get_shove_char_sequence().size()):
		if token != _network_attack_token or not is_inside_tree():
			return
		set_attack_char_index(wd.get_shove_char_sequence()[index])
		await get_tree().create_timer(wd.shove_frame_duration).timeout
	if token == _network_attack_token and is_inside_tree():
		exit_shove_mode()
		set_weapon_ready_frame()
		player_in_weapon_state = false


func _run_network_reload_presentation(token: int, wd: WeaponData, loaded_count: int) -> void:
	if wd.reload_mode == WeaponData.ReloadMode.SHOTGUN:
		for _shell: int in range(loaded_count):
			for index: int in range(wd.get_shotgun_loop_char_sequence().size()):
				if token != _network_attack_token or not is_inside_tree():
					return
				set_attack_char_index(wd.get_shotgun_loop_char_sequence()[index])
				await get_tree().create_timer(wd.get_shotgun_loop_frame_duration(index)).timeout
		for index: int in range(wd.get_shotgun_end_char_sequence().size()):
			if token != _network_attack_token or not is_inside_tree():
				return
			set_attack_char_index(wd.get_shotgun_end_char_sequence()[index])
			await get_tree().create_timer(wd.get_shotgun_end_frame_duration(index)).timeout
	else:
		for index: int in range(wd.get_reload_char_sequence().size()):
			if token != _network_attack_token or not is_inside_tree():
				return
			set_attack_char_index(wd.get_reload_char_sequence()[index])
			await get_tree().create_timer(wd.get_reload_frame_duration(index)).timeout
	if token != _network_attack_token or not is_inside_tree():
		return
	await get_tree().create_timer(wd.reload_wait_duration).timeout
	if token == _network_attack_token and is_inside_tree():
		set_weapon_ready_frame()
		if not _network_reload_was_facing_locked:
			unlock_facing()
		player_in_weapon_state = false


func _run_network_attack_presentation(token: int, wd: WeaponData) -> void:
	# 这个协程可能在 await 的下一帧遇到场景切换。不能缓存 SceneTree：节点离树后，
	# 缓存的 tree 虽非 null，却不能再安全地用于 current_scene / create_timer。
	var sequence: Array[int] = wd.attack_char_sequence if wd.is_ranged else wd.get_melee_attack_char_sequence()
	var impact_index := wd.fire_at_sequence_idx if wd.is_ranged else wd.melee_hit_at_sequence_idx
	for index: int in range(sequence.size()):
		if token != _network_attack_token or not is_instance_valid(self) or not is_inside_tree():
			return
		set_attack_char_index(sequence[index])
		if index == impact_index:
			var scene_tree := get_tree()
			if not scene_tree:
				return
			var scene := scene_tree.current_scene
			if wd.attack_sound and scene:
				Global.play_sfx_managed(wd.attack_sound, scene)
			var effect_scene := wd.get_attack_effect_anim(facing)
			if effect_scene and scene:
				var offset := current_character.get_attack_effect_offset(wd.weapon_state_name, facing, wd.attack_effect_offset_override) if current_character else wd.attack_effect_offset_override
				var follow: Node2D = self if wd.attack_effect_follow else null
				VXAnimSprite.play_scene(effect_scene, global_position, scene, 10.0, follow, offset)
		var duration := wd.get_attack_frame_duration(index) if wd.is_ranged else wd.get_melee_attack_frame_duration(index)
		if not is_inside_tree():
			return
		var wait_tree := get_tree()
		if not wait_tree:
			return
		await wait_tree.create_timer(duration).timeout
	if token == _network_attack_token and is_instance_valid(self) and is_inside_tree():
		set_weapon_ready_frame()
		player_in_weapon_state = false


func get_weapon_data() -> WeaponData:
	return _weapon_data


## NetworkWorld 的只读接口：不要让联机层访问玩家私有武器状态。
func is_weapon_mode_active() -> bool:
	return _weapon_mode


func get_network_weapon_id() -> String:
	return _weapon_data.item_id if _weapon_data else ""


## 进入推击模式：切换推击行走图。
## 优先级：角色按武器查找 > 角色通用推击图 > 武器推击图 > 回退普通武器纹理
func enter_shove_mode() -> void:
	_shove_mode = true
	_shove_texture = null
	if current_character and _weapon_data:
		_shove_texture = current_character.get_shove_walk_texture(_weapon_data.weapon_state_name)
	if not _shove_texture and _weapon_data and _weapon_data.shove_walk_texture:
		_shove_texture = _weapon_data.shove_walk_texture
	_refresh_sprite()


## 退出推击模式：恢复武器行走图
func exit_shove_mode() -> void:
	_shove_mode = false
	_shove_texture = null
	_refresh_sprite()


## 进入投掷物举起模式：切换投掷物行走图（完整持物外观，跟随朝向+踏步）
## affect_facing_lock=false 时跳过内部的 lock/unlock_facing：用于"每帧状态回放"路径
## （_ensure_client_player），此时朝向锁由 facing_lock_presentation 这条 Host 权威通道单独管理，
## 不能因为投掷物状态回放（held=false）就把固定朝向锁一并解掉。
func apply_network_throwable_presentation(td: ThrowableData, held: bool, aiming: bool, range_tiles: int, affect_facing_lock: bool = true) -> void:
	if not held or not td:
		exit_throwable_mode()
		if _network_throw_aim_indicator and is_instance_valid(_network_throw_aim_indicator):
			_network_throw_aim_indicator.queue_free()
		_network_throw_aim_indicator = null
		if affect_facing_lock:
			unlock_facing()
		return
	exit_weapon_mode()
	enter_throwable_mode(td)
	if aiming:
		if affect_facing_lock:
			lock_facing()
		if not _network_throw_aim_indicator or not is_instance_valid(_network_throw_aim_indicator):
			_network_throw_aim_indicator = Node2D.new()
			_network_throw_aim_indicator.name = "NetworkThrowAimIndicator"
			_network_throw_aim_indicator.z_index = 5
			_network_throw_aim_indicator.set_script(THROW_AIM_INDICATOR_SCRIPT)
			add_child(_network_throw_aim_indicator)
		_network_throw_aim_indicator.direction = get_facing_vector()
		_network_throw_aim_indicator.range_tiles = clampi(range_tiles, 0, td.throw_range_max)
	else:
		if affect_facing_lock:
			unlock_facing()
		if _network_throw_aim_indicator and is_instance_valid(_network_throw_aim_indicator):
			_network_throw_aim_indicator.queue_free()
		_network_throw_aim_indicator = null


func enter_throwable_mode(td: ThrowableData) -> void:
	_throwable_mode = true
	_throwable_texture = td.held_walk_texture if td else null
	_throwable_char_idx = current_character.throwable_walk_char_idx if current_character else 0
	_refresh_sprite()


## 退出投掷物举起模式：恢复普通行走图
func exit_throwable_mode() -> void:
	_throwable_mode = false
	_throwable_texture = null
	_throwable_char_idx = 0
	_refresh_sprite()


# ═══════════════════════════════════════
# 方向向量工具
# ═══════════════════════════════════════

## 根据当前朝向返回方向向量
func get_facing_vector() -> Vector2:
	match _facing:
		FaceDir.DOWN:  return Vector2(0, 1)
		FaceDir.UP:    return Vector2(0, -1)
		FaceDir.LEFT:  return Vector2(-1, 0)
		FaceDir.RIGHT: return Vector2(1, 0)
	return Vector2(0, 1)


# ═══════════════════════════════════════
# 固定朝向
# ═══════════════════════════════════════

## 锁定朝向到当前方向
func lock_facing() -> void:
	if _facing_locked:
		return
	_locked_facing = _facing
	_facing_locked = true
	print("[玩家] 朝向已锁定: %d" % _facing)


## 解锁朝向
func unlock_facing() -> void:
	if not _facing_locked:
		return
	_facing_locked = false
	print("[玩家] 朝向已解锁")


## 切换朝向锁定状态
func toggle_facing_lock() -> void:
	if _facing_locked:
		unlock_facing()
	else:
		lock_facing()


## 以网络权威值原子应用朝向锁定状态。
## locked_facing 只在锁定时生效，避免客户端预测方向与 Host 状态不一致。
func apply_facing_lock_state(locked: bool, locked_facing: int = -1) -> void:
	if locked:
		var authoritative_facing := clampi(locked_facing if locked_facing >= 0 else _facing, FaceDir.DOWN, FaceDir.UP)
		_locked_facing = authoritative_facing
		_facing_locked = true
		_facing = authoritative_facing
	else:
		_facing_locked = false
		_locked_facing = _facing
	_refresh_sprite()


## 返回当前朝向是否锁定
func is_facing_locked() -> bool:
	return _facing_locked


## 返回锁定时使用的朝向枚举。
func get_locked_facing() -> int:
	return _locked_facing


# ═══════════════════════════════════════
# 推击疲劳系统（L4D2 风格）
# ═══════════════════════════════════════

## 每帧更新推击疲劳计时器
func _update_shove_fatigue(delta: float) -> void:
	var cd: CharacterData = current_character
	if not cd:
		return
	# 疲劳系统禁用（limit=0）
	if cd.shove_fatigue_limit <= 0:
		_shove_fatigue_count = 0
		_shove_cooldown_timer = 0.0
		_shove_idle_timer = 0.0
		return

	# 冷却倒计时
	if _shove_cooldown_timer > 0.0:
		_shove_cooldown_timer -= delta
		if _shove_cooldown_timer <= 0.0:
			_shove_cooldown_timer = 0.0
			print("[推击疲劳] 冷却结束，可以推击了")

	# 空闲计时器（不在推击状态时累加，用于重置疲劳计数）
	if not player_in_weapon_state or not _shove_mode:
		_shove_idle_timer += delta
		if _shove_idle_timer >= cd.shove_fatigue_reset_time and _shove_fatigue_count > 0:
			_shove_fatigue_count = 0
			print("[推击疲劳] 空闲 %.1fs，疲劳计数已重置" % cd.shove_fatigue_reset_time)


## 检查是否可以推击（疲劳冷却检查）
## 返回 true 表示可以推击
func can_shove() -> bool:
	var cd: CharacterData = current_character
	if not cd:
		return true
	# 禁用疲劳系统
	if cd.shove_fatigue_limit <= 0:
		return true
	# 冷却中
	if _shove_cooldown_timer > 0.0:
		print("[推击疲劳] 冷却中！剩余 %.1fs" % _shove_cooldown_timer)
		return false
	return true


## 推击执行后调用：增加疲劳计数，必要时启动冷却
func on_shove_performed() -> void:
	var cd: CharacterData = current_character
	if not cd or cd.shove_fatigue_limit <= 0:
		return

	_shove_idle_timer = 0.0
	_shove_fatigue_count += 1
	print("[推击疲劳] 推击次数: %d / %d" % [_shove_fatigue_count, cd.shove_fatigue_limit])

	if _shove_fatigue_count >= cd.shove_fatigue_limit:
		_shove_cooldown_timer = cd.shove_cooldown_duration
		_shove_fatigue_count = 0
		print("[推击疲劳] 达到上限！冷却 %.1fs" % cd.shove_cooldown_duration)


# ═══════════════════════════════════════
# HP 系统
# ═══════════════════════════════════════

func _init_hp() -> void:
	current_hp = max_hp


## 从 CharacterData 资源读取外观/动画/HP 参数
func _apply_character_data() -> void:
	# 始终从本实体对应座位同步角色数据（切换角色时必须更新 current_character）
	var state: PlayerState = Players.get_state_for_entity(self)
	if state and state.character:
		current_character = state.character
	_apply_current_character_data(current_character)


func _apply_current_character_data(cd: CharacterData) -> void:
	if not cd:
		return
	if cd.walk_texture:   walk_texture = cd.walk_texture
	walk_char_index = cd.walk_char_index
	walk_frame_duration = cd.walk_frame_duration
	if cd.run_texture:    run_texture = cd.run_texture
	run_char_index = cd.run_char_index
	run_frame_duration = cd.run_frame_duration
	if cd.death_texture:  death_texture = cd.death_texture
	death_char_index = cd.death_char_index
	max_hp = float(cd.get_effective_max_hp())
	if cd.hurt_sound:     hurt_sound = cd.hurt_sound
	if cd.death_sound:    death_sound = cd.death_sound


## 角色切换后刷新外观/HP/装备/状态（由 CharacterSwitchManager 调用）
func refresh_after_switch() -> void:
	# 觉醒是角色专属能力：切人即解除（新角色可能没有觉醒）
	_deactivate_awaken()
	_apply_character_data()
	if not animation_timer:
		return
	animation_timer.wait_time = _mode_anim_duration(true)
	animation_timer.start()
	# 保持 Idle 外观（非武器模式），仅记录武器数据引用
	var state: PlayerState = Players.get_state_for_entity(self)
	var wd: WeaponData = state.get_active_weapon() if state else null
	_weapon_data = wd if wd and not wd.weapon_state_name.is_empty() else null
	_weapon_mode = false
	current_hp = state.current_hp if state else max_hp
	_moving = false
	_anim_step = 0
	velocity = Vector2.ZERO
	_refresh_sprite()
	print("[玩家] 切换后刷新完成: %s HP=%.0f" % [
		current_character.character_name if current_character else "?",
		current_hp,
	])


# ── 灼烧状态（火属性 DoT）──
# 状态挂在玩家实体上：切人后延续剩余时间继续烧新角色（2026-09-15 用户定稿选项三）。
# 每秒伤害按难度缩放（复用 Global.difficulty_multipliers.enemy_damage）：
# 简单 4 / 普通 8 / 困难 12 / 专家 16。
const BURN_TIME: float = 4.0              ## 燃烧持续时间（秒），重复点燃重置
const BURN_BASE_DPS: float = 8.0          ## 普通难度下每秒掉血
const BURN_TICK_INTERVAL: float = 0.5     ## 掉血结算间隔（与 enemy.gd 同款 0.5s）
var _burning_time: float = 0.0
var _burn_tick: float = 0.0


func _get_burn_dps() -> float:
	var cfg: Variant = Global.difficulty_multipliers.get(Global.selected_difficulty, null)
	if cfg is Dictionary and cfg.has("enemy_damage"):
		return BURN_BASE_DPS * float(cfg["enemy_damage"])
	return BURN_BASE_DPS


## 受到火属性伤害时点燃（重复点燃=持续时间重置，旧状态覆盖）。
## tick 只在首燃时清零：火海 0.2s 连续点燃若每次都清 tick，DoT 的 0.5s 结算永远凑不满（被饿死）。
func _ignite_burn() -> void:
	if _burning_time <= 0.0:
		_burn_tick = 0.0
	_burning_time = BURN_TIME
	BurnEffect.attach(self)


## 每帧更新：灼烧 DoT 掉血 + 计时与火焰视觉摘除。
func _update_burn_status(delta: float) -> void:
	if _is_dying or _burning_time <= 0.0:
		return
	_burning_time -= delta
	_burn_tick -= delta
	if _burn_tick <= 0.0:
		_burn_tick = BURN_TICK_INTERVAL
		var burn_damage: float = _get_burn_dps() * BURN_TICK_INTERVAL
		current_hp = maxf(0.0, current_hp - burn_damage)
		# 橙色伤害数字：灼烧掉血无红闪/音效，靠数字让"持续掉血"可见
		var burn_tree := get_tree()
		if burn_tree and burn_tree.current_scene:
			DamageNumber.spawn(global_position, burn_damage, burn_tree.current_scene, 0, Color(1.0, 0.55, 0.2))
		# 与 take_damage 同款座位 HP 同步；烧死走正常死亡流程（喷雾救人→切人/真死）
		var burn_state: PlayerState = Players.get_state_for_entity(self)
		if burn_state:
			burn_state.current_hp = current_hp
		if current_hp <= 0.0:
			_die()
			return
	if _burning_time <= 0.0:
		BurnEffect.detach(self)


func take_damage(damage: float, _knockback_force: float, direction: Vector2, _is_headshot: bool = false, _knockback_stun: float = 0.0, _hitstun_duration: float = 0.0, source_id: int = 0, element: int = 0, causes_heat: bool = false) -> void:
	if _is_dying:
		return

	# 源头去重：同一伤害源 1 秒内不会对玩家重复判定。
	# 必须先于见切/SA 无效化记录 —— 否则同一攻击的第二次判定（body+hurtbox 双路径）
	# 会在第一次被见切无效化后绕过去重，仍然打中玩家。
	if source_id != 0:
		var now: int = Time.get_ticks_msec()
		_clean_expired_damage_sources(now)
		if source_id in _recent_damage_sources:
			if now - _recent_damage_sources[source_id] < DAMAGE_SOURCE_COOLDOWN_MSEC:
				print("[玩家] 源头去重：source_id=%d 在冷却期内，跳过伤害" % source_id)
				return
		_recent_damage_sources[source_id] = now

	# ── SA/见切无效化（说明书 §4.3/§6.2）──
	# しゃがみ回避=无敌；感覚向上=完全见切（自动反击）；见切窗口=无伤+触发反击
	if _should_negate_hit(damage):
		return

	var hp_before: float = current_hp
	# ── ガッツ（原作 system.html ◆ガッツ）：HP≥2 时任何攻击保底 1 HP 不死（Heat 中停止）──
	if damage > 0.0 and not is_heat_active() and current_hp >= 2.0 and damage >= current_hp:
		current_hp = 1.0
		print("[玩家] ガッツ：以 1 HP 踏足不倒！")
	else:
		current_hp = maxf(0.0, current_hp - damage)
	var actual_damage: float = maxf(0.0, hp_before - current_hp)

	# ── 削り / Heat（原作 §4.6）：酸或 Heat 攻击命中 → 削减武器弹药/耐久；Heat 攻击附加 Heat ──
	if damage > 0.0 and (element == WeaponData.Element.ACID or causes_heat):
		_apply_attrition()
	if causes_heat:
		_apply_heat()

	# ── 灼烧（火属性伤害点燃；被见切/SA 无效化的攻击已在上方 return，不点燃）──
	if element == WeaponData.Element.FIRE:
		_ignite_burn()

	print("[玩家] 受到伤害: %d | HP: %.0f/%.0f | source=%d" % [int(damage), current_hp, max_hp, source_id])
	if actual_damage > 0.0:
		network_damage_applied.emit(actual_damage, global_position, _is_headshot)
	_play_hit_feedback(Color.RED)

	# 弹出伤害数字（红色调，表示玩家受伤）
	var tree := get_tree()
	if tree and tree.current_scene:
		DamageNumber.spawn(global_position, damage, tree.current_scene, 0, Color(1.0, 0.25, 0.2))

	# 播放受伤音效
	_play_sound(hurt_sound)

	# 同步 HP 到本实体对应座位。
	var state: PlayerState = Players.get_state_for_entity(self)
	if state:
		state.current_hp = current_hp
		var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
		if chapter_stats and chapter_stats.has_method("record_damage_taken"):
			chapter_stats.record_damage_taken(state.seat_index, actual_damage)

	if current_hp <= 0.0:
		_die()


func play_network_hurt_presentation(damage: float, impact_position: Vector2 = global_position) -> void:
	if damage <= 0.0:
		return
	_play_hit_feedback(Color.RED)
	var tree := get_tree()
	if tree and tree.current_scene:
		DamageNumber.spawn(impact_position, damage, tree.current_scene, 0, Color(1.0, 0.25, 0.2))
	_play_sound(hurt_sound)


## 播放受击反馈（闪红/渐隐）
func _play_hit_feedback(hit_color: Color = Color.RED, duration: float = -1.0) -> void:
	if duration < 0.0:
		duration = hit_feedback_duration
	if not sprite:
		return
	if has_meta("_hf_tween"):
		var old: Tween = get_meta("_hf_tween")
		if old and old.is_valid():
			old.kill()
	if hit_feedback_mode == 0:
		var tween := create_tween()
		set_meta("_hf_tween", tween)
		tween.tween_property(sprite, "modulate", hit_color, 0.0)
		tween.tween_property(sprite, "modulate", Color.WHITE, duration)
	else:
		sprite.modulate = hit_color
		var tween := create_tween()
		set_meta("_hf_tween", tween)
		tween.tween_property(sprite, "modulate", Color.WHITE, duration)


func heal(amount: float) -> void:
	current_hp = minf(max_hp, current_hp + amount)
	var state: PlayerState = Players.get_state_for_entity(self)
	if state:
		state.current_hp = current_hp
	print("[玩家] 回复 HP: %d | HP: %.0f/%.0f" % [int(amount), current_hp, max_hp])


## 使用治疗品。单机=队伍共用池（2026-09-13）；联机=自己座位优先，没有 → 其他座位。
func use_healing_item() -> bool:
	var state: PlayerState = Players.get_state_for_entity(self)
	var used: ItemData = null
	if Players.using_shared_spray_pool():
		used = Players.consume_team_spray()
	else:
		used = state.use_healing_item() if state else null
		if not used:
			for s: PlayerState in Players.seats:
				if s and s != state:
					used = s.use_healing_item()
					if used:
						break
	if not used:
		return false
	apply_item_effects(used)
	# 看护（说明书 §6.2，静香被动）：手动使用治疗品 → 全队同时回复相同 HP
	if current_character and current_character.nursing and used.hp_restore > 0:
		for p: Node2D in Players.all_entities():
			if is_instance_valid(p) and p != self and not p.get("_is_dying"):
				p.heal(used.hp_restore)
		print("[被动] 看护：全队各回复 %d HP" % used.hp_restore)
	var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
	if chapter_stats and chapter_stats.has_method("record_healing_item"):
		chapter_stats.record_healing_item(state.seat_index)
	return true


## 使用当前座位的辅助品。
func use_support_item() -> bool:
	var state: PlayerState = Players.get_state_for_entity(self)
	var used: ItemData = state.use_support_item() if state else null
	if not used:
		return false
	apply_item_effects(used)
	return true


## 将物品效果施加到本玩家实体，避免 Global 持有“本地玩家”假设。
func apply_item_effects(item: ItemData) -> void:
	if not item:
		return
	if item.hp_restore > 0:
		heal(item.hp_restore)
	if item.tp_restore > 0:
		restore_tp(item.tp_restore)


## 回复 TP（技能点）。供物品使用效果与自动回复共用。
func restore_tp(amount: int) -> void:
	if amount <= 0:
		return
	var state: PlayerState = Players.get_state_for_entity(self)
	if not state:
		return
	var max_tp: int = _get_max_tp()
	var before: int = state.current_tp
	state.current_tp = mini(max_tp, before + amount)
	if state.current_tp > before:
		print("[玩家] 回复 TP: +%d | TP: %d/%d" % [state.current_tp - before, state.current_tp, max_tp])


## 当前角色的 TP 上限
func _get_max_tp() -> int:
	if current_character:
		return current_character.get_effective_max_tp()
	var state: PlayerState = Players.get_state_for_entity(self)
	return state.get_max_tp() if state else 100


## 每帧更新 TP 自动回复（恢复量/间隔由 CharacterData 决定；Heat 中停止）
func _update_tp_regen(delta: float) -> void:
	if _is_dying or not current_character:
		return
	if is_heat_active():
		_tp_regen_timer = 0.0
		return
	var interval: float = current_character.tp_regen_interval
	if interval <= 0.0:
		return
	var state: PlayerState = Players.get_state_for_entity(self)
	if not state:
		return
	if state.current_tp >= _get_max_tp():
		_tp_regen_timer = 0.0
		return
	_tp_regen_timer += delta
	if _tp_regen_timer >= interval:
		_tp_regen_timer -= interval
		restore_tp(current_character.tp_regen_amount)


## 按搓招触发键释放技能（单机 / Host 本机玩家的输入入口）。
## trigger: 触发键的输入动作名（如 "确定键"/"取消键"），匹配 SkillData.command_trigger
func use_skill(trigger: String = "") -> void:
	if not current_character:
		return
	var skills: Array[SkillData] = current_character.skills
	if skills.is_empty():
		print("[技能] 当前角色没有技能")
		return
	var skill: SkillData = _find_skill_by_trigger(skills, trigger)
	if not skill:
		print("[技能] 没有绑定触发键 %s 的技能" % trigger)
		return
	_use_skill_core(trigger, _match_motion(skill.command_motion))


## 释放技能核心（C2 拆分：无 Input / 搓招缓冲读取，联机下 Host 替 Client 玩家
## 结算经此入口）。motion_ok 由调用方预校验——搓招缓冲只存在于输入方本机，
## Host 无法重放输入序列，请求协议信任 Client 的本地预校验（与射击瞄准同类
## 的意图信任）；单机入口传 _match_motion 实测结果，行为不变。
## TP 走 PlayerState 权威值（Host 上 get_state_for_entity 对权威实体返回权威域）。
## 返回是否成功释放（校验失败逐项早退）。
func _use_skill_core(trigger: String, motion_ok: bool) -> bool:
	if not current_character:
		return false
	var skill: SkillData = _find_skill_by_trigger(current_character.skills, trigger)
	if not skill:
		print("[技能] 没有绑定触发键 %s 的技能" % trigger)
		return false
	if not motion_ok:
		print("[技能] 搓招失败：%s 需要方向指令 [%s]" % [skill.skill_name, skill.command_motion])
		return false
	var state: PlayerState = Players.get_state_for_entity(self)
	if not state:
		return false
	if skill.tp_cost > 0 and state.current_tp < skill.tp_cost:
		print("[技能] TP 不足: 需要 %d, 当前 %d" % [skill.tp_cost, state.current_tp])
		return false
	state.current_tp -= skill.tp_cost
	print("[技能] 释放 %s | 消耗 TP %d | 剩余 %d" % [skill.skill_name, skill.tp_cost, state.current_tp])
	_execute_skill_effect(skill, trigger)
	return true


# ═══════════════════════════════════════
# SA 技能效果（说明书 §6.2：SA = 每角色一个专属主动技）
# ═══════════════════════════════════════

## 按 skill_type 分派实际效果。
func _execute_skill_effect(skill: SkillData, trigger: String = "") -> void:
	if skill.sa_sound:
		var scene: Node = get_tree().current_scene if get_tree() else null
		Global.play_sfx_managed(skill.sa_sound, scene)
	match skill.skill_type:
		SkillData.SkillType.SA_SEEKER:
			# のび太「感覚向上」：持续时间内敌方攻击完全见切（无伤）
			_sa_auto_mukiri_until_msec = Time.get_ticks_msec() + int(skill.duration * 1000.0)
			print("[SA] 感覚向上：%.0f 秒内完全见切（敌方攻击无效化）" % skill.duration)
		SkillData.SkillType.SA_RECITAL:
			# ジャイアン「ジャイアンリサイタル」：半径内全体敌人踉跄（0 伤害 + 硬直）
			var staggered: int = _sa_recital_stagger(skill.radius, skill.stagger_duration)
			print("[SA] ジャイアンリサイタル：%.0fpx 内 %d 个敌人踉跄 %.1fs" % [skill.radius, staggered, skill.stagger_duration])
		SkillData.SkillType.SA_CROUCH:
			# 静香「しゃがみ回避」：基础无敌 duration 秒；按住 SA 键持续蹲（急速耗 TP）
			_start_crouch_dodge(skill)
		SkillData.SkillType.SA_BACKPACK:
			# スネ夫「バックパック」：背包系统未实装，占位
			print("[SA] バックパック：背包系统未实装（占位）")
		_:
			print("[技能] %s：无绑定效果（GENERIC 占位）" % skill.skill_name)
	# 联机（C2）：Host 侧结算完成后广播表现（Client 解析本地同名技能：
	# 播 sa_sound / 蹲下染色与计时 / 感覚向上计时；RECITAL 的敌人踉跄由 Host
	# 结算经快照体现，不在此复现）。单机 / Client 端为 no-op。
	_announce_network_sa_event("sa:" + (trigger if not trigger.is_empty() else skill.command_trigger))


## リサイタル：半径内所有存活敌人进入踉跄（0 伤害 → 不弹数字；hitstun → 原地冻结）
func _sa_recital_stagger(radius: float, stagger: float) -> int:
	var count: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or e.get("_is_dead") == true or e.get("_is_dying") == true:
			continue
		if e.global_position.distance_to(global_position) > radius:
			continue
		if e.has_method("take_damage"):
			e.take_damage(0.0, 0.0, (e.global_position - global_position).normalized(), false, 0.0, stagger)
			count += 1
	return count


## しゃがみ回避：进入蹲下无敌；每帧由 _update_sa_state 维持/结束。
func _start_crouch_dodge(skill: SkillData) -> void:
	_sa_crouch_skill = skill
	_sa_crouch_until_msec = Time.get_ticks_msec() + int(skill.duration * 1000.0)
	_sa_crouch_active = true
	if sprite:
		sprite.modulate = Color(0.75, 0.85, 1.0)  # 蹲下（无敌）的视觉提示
	print("[SA] しゃがみ回避：无敌 %.1f 秒（按住 SA 键持续蹲，每秒耗 %.0f TP）" % [skill.duration, skill.crouch_tp_drain])


func _end_crouch_dodge() -> void:
	_sa_crouch_active = false
	_sa_crouch_skill = null
	_network_sa_crouch_hold = false  # Host 权威实体的按住登记随蹲下结束一并清除
	if sprite:
		sprite.modulate = Color.WHITE
	print("[SA] しゃがみ回避结束")
	# 联机（C2）：Host 侧结束（超时/TP 尽/死亡）广播对齐表现；Client 本地结束
	# 与 crouch_end_presentation 幂等（LAN 漂移 <1s）；单机 no-op。
	_announce_network_sa_event("crouch_end")


## SA 状态每帧维护：发动输入、しゃがみ持续（按住延长 + TP 消耗）、超时结束。
## 仅本地权威实体调用（network_controlled 分支在 _process 里提前 return）。
# ═══════════════════════════════════════
# Heat / 削り（原作说明书 §4.6）
# ═══════════════════════════════════════

## Heat 状态：禁止切人、禁止见切（反击无效）、TP 停止回复、Guts 停止。
func _apply_heat() -> void:
	var was_active: bool = _heat_time > 0.0
	_heat_time = HEAT_DURATION  # 刷新与首次置位统一（联机表现同语义）
	if not was_active and sprite:
		sprite.modulate = Color(1.8, 0.6, 0.6)
	# 联机（C2）：Heat 染色 + 本地计时广播（否则 Client 不知道自己处于 Heat，
	# 会误解见切失效的反馈）；单机 / Client 端 no-op。
	_announce_network_sa_event("heat")
	if not was_active:
		print("[状态] Heat！%.0f 秒内禁止见切/反击、TP 停止回复、Guts 停止" % HEAT_DURATION)


func is_heat_active() -> bool:
	return _heat_time > 0.0


# ═══════════════════════════════════════
# 覚醒コマンド（原作：構え中 Z+X；のび太=「集中射撃」）
# ═══════════════════════════════════════

## 尝试发动觉醒。成功返回 true。
## 原作（player.html のび太）：「構え中Z+Xで発動。発動中は徐々にTPを消費するが、
## 射撃攻撃の威力が上昇し、ハンドガン・マグナムの攻撃に即死・怯み効果が付与される。」
## 本工程触发 = 构势（举枪 READY）中按**空格（覚醒键）**（2026-09-13 用户改版：
## 组合键按住Z+按X 容易被攻击状态转移吞输入 → 改专用键，空格已从确定键摘除）。
## 覚醒键按下是本函数内的硬条件（单一判据，调用点不用各自判输入）。
func try_activate_awaken() -> bool:
	if _awaken_active or _is_dying:
		return false
	if not Input.is_action_pressed("覚醒键"):
		return false
	return _activate_awaken_core()


## 覚醒发动核心（无 Input 读取）：联机下 Host 替 Client 玩家结算时经此入口
## （Host 上读不到 Client 键盘，输入判定由 Client 的 awaken_request 上报替代）。
## 校验 awaken_type + TP（PlayerState 权威值），成功后置 _awaken_active + 金色染色。
func _activate_awaken_core() -> bool:
	if _awaken_active or _is_dying:
		return false
	if current_character == null or current_character.awaken_type == "none":
		return false
	var state: PlayerState = Players.get_state_for_entity(self)
	if state == null or state.current_tp <= 0:
		print("[覚醒] TP 不足，无法发动")
		return false
	_awaken_active = true
	if sprite:
		sprite.modulate = Color(1.9, 1.7, 0.9)
		_awaken_tint_applied = true
	print("[覚醒] 集中射撃発動！TP 每秒 -%d、射撃威力 ×%.1f、即死・怯み（Boss 免疫即死）" % [
		int(AWAKEN_TP_DRAIN_PER_SEC), AWAKEN_DAMAGE_MULT])
	return true


func is_awaken_active() -> bool:
	return _awaken_active


## 每帧：发动中 TP 缓慢消耗；TP 耗尽 / 死亡 / 切人 → 解除。
func _update_awaken(delta: float) -> void:
	if not _awaken_active:
		return
	var state: PlayerState = Players.get_state_for_entity(self)
	var tp_left: int = state.current_tp if state else 0
	if state:
		state.current_tp = maxi(0, state.current_tp - int(round(AWAKEN_TP_DRAIN_PER_SEC * delta)))
		tp_left = state.current_tp
	if tp_left <= 0 or _is_dying:
		_deactivate_awaken()
		if tp_left <= 0:
			print("[覚醒] TP 耗尽，集中射撃解除")


func _deactivate_awaken() -> void:
	if not _awaken_active:
		return
	_awaken_active = false
	# 还原染色：Heat 的红色染色优先（两者可能并存）
	if sprite and _awaken_tint_applied:
		sprite.modulate = Color(1.8, 0.6, 0.6) if is_heat_active() else Color.WHITE
		_awaken_tint_applied = false
	# 联机（C1）：Host 权威实体上任何解除路径（TP 耗尽/死亡/放下武器）统一出口广播；
	# 单机/Client 端 find_child 找不到 NetworkWorld → no-op。
	var tree := get_tree()
	if tree:
		var scene := tree.current_scene
		if scene:
			var world: Node = scene.find_child("NetworkWorld", true, false)
			if world and world.has_method("announce_player_awaken"):
				world.call("announce_player_awaken", self, false)


## 联机表现接口（C1，由 NetworkWorld 的 awaken_presentation 调用）：
## 置 _awaken_active + 染色还原——发起者本人的 Client 也经此获得即时染色，
## 其余 Client 的远端玩家同款；后续 TP 扣费由本实体 _process 的
## network_controlled 分支内 _update_awaken 各自域独立推进（同速同规则）。
func apply_network_awaken_state(active: bool) -> void:
	if active:
		if _awaken_active:
			return
		if current_character == null or current_character.awaken_type == "none":
			return
		_awaken_active = true
		if sprite:
			sprite.modulate = Color(1.9, 1.7, 0.9)
			_awaken_tint_applied = true
		print("[覚醒] 联机染色 ON（peer 表现）")
	else:
		if not _awaken_active:
			return
		_awaken_active = false
		if sprite and _awaken_tint_applied:
			sprite.modulate = Color(1.8, 0.6, 0.6) if is_heat_active() else Color.WHITE
			_awaken_tint_applied = false
		print("[覚醒] 联机染色 OFF（peer 表现）")


## 削り：削减装备中武器的弹药/耐久。
## 远程=弹夹 -ATTRITION_AMMO；近战=耐久 -ATTRITION_DURABILITY（max_durability>0 才有耐久，
## 原作"无限耐久武器免疫削り"）。耐久归零 → 武器损坏（卸下）。
func _apply_attrition() -> void:
	var state: PlayerState = Players.get_state_for_entity(self)
	if not state:
		return
	var wd: WeaponData = state.get_active_weapon()
	if not wd:
		return
	if wd.is_ranged and wd.magazine_capacity > 0:
		var before: int = state.get_magazine_ammo(wd.item_id)
		if before <= 0:
			return
		var after: int = maxi(0, before - ATTRITION_AMMO)
		state.set_magazine_ammo(wd.item_id, after)
		print("[削り] %s 弹夹 %d → %d" % [wd.item_name, before, after])
	elif wd.max_durability > 0.0:
		var before_d: float = state.get_weapon_durability(wd.item_id, wd.max_durability)
		var after_d: float = maxf(0.0, before_d - ATTRITION_DURABILITY)
		state.set_weapon_durability(wd.item_id, after_d)
		print("[削り] %s 耐久 %.0f → %.0f" % [wd.item_name, before_d, after_d])
		if after_d <= 0.0:
			state.unequip_slot(state.active_weapon_slot)
			_weapon_mode = false
			player_in_weapon_state = false
			_refresh_sprite()
			print("[削り] %s 耐久耗尽，武器损坏！" % wd.item_name)


func _update_sa_state(delta: float) -> void:
	if _is_dying:
		if _sa_crouch_active:
			_end_crouch_dodge()
		return
	# 覚醒（集中射撃）：发动中 TP 缓慢消耗，耗尽/死亡自动解除
	_update_awaken(delta)
	# Heat 状态计时与褪色（Heat 中禁止见切/反击、TP 停、Guts 停）
	if _heat_time > 0.0:
		_heat_time -= delta
		if _heat_time <= 0.0 and sprite and not _sa_crouch_active:
			sprite.modulate = Color.WHITE
			print("[状态] Heat 解除")
	# SA 发动键（原作 X 键；本工程菜单在 P/Esc，X 无冲突，绑在 project.godot 的「SA键」）
	if Input.is_action_just_pressed("SA键"):
		use_skill("SA键")
	# 见切输入（原作 Z=攻击兼见切；「确定键」按下即登记 0.3s 判定窗口）
	if Input.is_action_just_pressed("确定键"):
		_try_mukiri_input()
	# しゃがみ持续：超时结束；按住 SA 键且 TP 未耗尽 → 延长并扣 TP
	var now: int = Time.get_ticks_msec()
	if _sa_crouch_active:
		if now >= _sa_crouch_until_msec:
			_end_crouch_dodge()
		elif Input.is_action_pressed("SA键") and _sa_crouch_skill:
			var state: PlayerState = Players.get_state_for_entity(self)
			if state and state.current_tp > 0:
				_sa_crouch_until_msec = now + int(_sa_crouch_skill.duration * 1000.0)
				var drain: int = maxi(1, int(round(_sa_crouch_skill.crouch_tp_drain * delta)))
				state.current_tp = maxi(0, state.current_tp - drain)


## 敌方攻击是否被无效化（しゃがみ无敌 / 感覚向上完全见切 / 见切输入窗口）。
## 见切成功时对实际伤害（>0）触发反击。
func _should_negate_hit(damage: float) -> bool:
	var now: int = Time.get_ticks_msec()
	# しゃがみ回避（无敌）
	if _sa_crouch_active or now < _sa_crouch_until_msec:
		_play_hit_feedback(Color(2.0, 2.0, 2.0, 1.0), 0.08)
		print("[SA] しゃがみ回避：攻击无效化")
		return true
	# 感覚向上（完全见切 → 自动反击，即原作"见切是反击的触发器"）；Heat 中禁止见切
	if now < _sa_auto_mukiri_until_msec and not is_heat_active():
		_play_hit_feedback(Color(2.0, 2.0, 2.0, 1.0), 0.08)
		print("[SA] 感覚向上：见切成功（无伤）")
		if damage > 0.0:
			_try_counter()
		return true
	# 见切输入窗口（0.3s；原作 Z 键攻击兼见切）；Heat 中禁止见切
	if now < _mukiri_window_until_msec and not is_heat_active():
		_mukiri_window_until_msec = 0
		_play_hit_feedback(Color(2.0, 2.0, 2.0, 1.0), 0.08)
		print("[见切] 成功（无伤）")
		_play_mukiri_anim()
		# 联机（C2）：见切成功动画广播（Client 远端玩家播同款见切行走图序列）。
		_announce_network_sa_event("mukiri")
		if damage > 0.0:
			_try_counter()
		return true
	return false


## 见切成功动画：切换到见切行走图并按角色索引序列播放（配置方式同举枪动画）。
## 素材 = CharacterData.mukiri_walk_texture（空则回退推击图/反撃套）。
func _play_mukiri_anim() -> void:
	if _mukiri_anim_busy or _is_dying or sprite == null:
		return
	var tex: Texture2D = null
	var seq: Array[int] = []
	var durations: Array[float] = []
	if current_character:
		tex = current_character.mukiri_walk_texture
		if not tex:
			tex = current_character.shove_walk_texture
		seq = current_character.mukiri_char_sequence
		durations = current_character.mukiri_frame_durations
	if not tex or seq.is_empty():
		return
	_mukiri_anim_busy = true
	for i: int in seq.size():
		var char_idx: int = seq[i]
		var char_col: int = char_idx % CHARS_PER_ROW
		var char_row: int = char_idx / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_facing]
		sprite.texture = tex
		sprite.region_enabled = true
		sprite.region_rect = Rect2(
			char_col * (FRAME_W * 3) + STAND_FRAME * FRAME_W,
			char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H,
			FRAME_W, FRAME_H)
		var fd: float = durations[i] if i < durations.size() else 0.08
		var tree := get_tree()
		if not tree:
			return
		await tree.create_timer(fd).timeout
		if not is_inside_tree():
			return
	_mukiri_anim_busy = false
	_refresh_sprite()


## 见切输入：按「确定键」即登记 0.3s 判定窗口（与攻击共用一键，同原作）。
## Heat 中见切使用不可（原作 system.html ◆ヒート：「見切り使用不可(カウンター不可)」）——
## 输入直接吞掉并给反馈，不再登记无效窗口（无效化判定侧本就有 is_heat_active 门）。
func _try_mukiri_input() -> void:
	var now: int = Time.get_ticks_msec()
	if is_heat_active():
		if now - _mukiri_last_attempt_msec >= MUKIRI_INTERVAL_MS:
			_mukiri_last_attempt_msec = now
			print("[状态] Heat 中见切使用不可！")
		return
	if now - _mukiri_last_attempt_msec < MUKIRI_INTERVAL_MS:
		return
	_mukiri_last_attempt_msec = now
	_mukiri_window_until_msec = now + MUKIRI_WINDOW_MS


# ═══════════════════════════════════════
# 反击（说明书 §4.3/§6.2：见切成功后触发，类型=角色专属）
# ═══════════════════════════════════════

## 见切成功 → 前方 ±60°、88px 扇形内敌人吃反击：
##   punch（拳打）= 2×攻击 + 推开；heavy（强打）= 3×攻击 + 大推；
##   issen（一闪）= 4×攻击 + 超Push + 即死（Boss 抗性系统未实装，当前对全部敌人生效）。
func _try_counter() -> void:
	var now: int = Time.get_ticks_msec()
	if now < _counter_cooldown_until_msec:
		return
	var ctype: String = current_character.counter_type if current_character else "none"
	if ctype == "none":
		return
	# 原作（system.html ◆カウンター）：反击只在**非架势**（未举枪）时触发；构势中见切只免伤
	if player_in_weapon_state:
		print("[反击] 构势中不触发反击（原作：カウンター=構えていない時のみ）")
		return
	_counter_cooldown_until_msec = now + COUNTER_COOLDOWN_MS
	if current_character.counter_sound:
		var scene: Node = get_tree().current_scene if get_tree() else null
		Global.play_sfx_managed(current_character.counter_sound, scene)
	# 联机（C2）：反击音效广播（反击伤害/击退结算本就在 Host，Client 只需听声）。
	_announce_network_sa_event("counter")
	var facing: Vector2 = get_facing_vector()
	var dmg_mult: float = 2.0
	var push_force: float = 320.0
	var push_stun: float = 0.4
	var instant_kill: bool = false
	match ctype:
		"punch":
			dmg_mult = 2.0; push_force = 320.0; push_stun = 0.4
		"heavy":
			dmg_mult = 3.0; push_force = 520.0; push_stun = 0.8
		"issen":
			dmg_mult = 4.0; push_force = 640.0; push_stun = 1.0; instant_kill = true
	var base: float = float(current_character.get_effective_attack()) if current_character else 10.0
	var hit_count: int = 0
	for e: Node2D in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or e.get("_is_dead") == true or e.get("_is_dying") == true:
			continue
		var to_e: Vector2 = e.global_position - global_position
		if to_e.length() > 88.0 or to_e.length() < 1.0:
			continue
		if to_e.normalized().dot(facing) < 0.5:
			continue
		if not e.has_method("take_damage"):
			continue
		var dmg: float = base * dmg_mult
		if instant_kill and e.get("current_hp") != null:
			dmg = maxf(dmg, float(e.get("current_hp")) + 1.0)
		e.take_damage(dmg, push_force, facing, false, push_stun, 0.0)
		hit_count += 1
	print("[反击] %s：命中 %d 个敌人（威力 x%.0f，推力 %.0f%s）" % [ctype, hit_count, dmg_mult, push_force, "，即死" if instant_kill else ""])


# ═══════════════════════════════════════
# 联机 SA / 见切 / 反击接线（C2，由 NetworkWorld 调用 / network_controlled 分支驱动）
# ═══════════════════════════════════════

## network_controlled 实体的 SA 状态每帧维护（与单机 _update_sa_state 同规则同速度）：
##   - Host 权威实体：Heat 计时（take_damage→_apply_heat 真实置位，原实现无人推进
##     会让联机玩家 Heat 永不褪色）；しゃがみ按住延长读 sa_crouch_hold RPC 登记的
##     _network_sa_crouch_hold，扣权威 TP；
##   - Client 本地预测实体：Heat 计时（heat_presentation 本地置位）；しゃがみ按住
##     直读本机键盘，扣显示 TP（双域独立推进，同 C1 覚醒 TP 精度）；
##   - Client 远端玩家：仅 Heat 计时与蹲下超时（按住延长由 Host 权威侧结算，
##     结束经 crouch_end_presentation 对齐）。
## 超时/TP 尽各自结束：Host 侧结束经 _end_crouch_dodge 广播表现；Client 本地结束
## 与表现幂等；感覚向上/见切窗口是 msec 时间戳比较，无需每帧推进。
func _update_network_sa_state(delta: float) -> void:
	if _is_dying:
		if _sa_crouch_active:
			_end_crouch_dodge()
		return
	# Heat 状态计时与褪色（与单机 _update_sa_state 同条件：蹲下中不覆盖染色）
	if _heat_time > 0.0:
		_heat_time -= delta
		if _heat_time <= 0.0 and sprite and not _sa_crouch_active:
			sprite.modulate = Color.WHITE
			print("[状态] Heat 解除")
	var now: int = Time.get_ticks_msec()
	if _sa_crouch_active:
		if now >= _sa_crouch_until_msec:
			_end_crouch_dodge()
			return
		var hold: bool = _network_sa_crouch_hold
		if network_local_prediction:
			hold = Input.is_action_pressed("SA键")  # Client 本地实体直读本机键盘
		if hold and _sa_crouch_skill:
			var state: PlayerState = Players.get_state_for_entity(self)
			if state and state.current_tp > 0:
				_sa_crouch_until_msec = now + int(_sa_crouch_skill.duration * 1000.0)
				var drain: int = maxi(1, int(round(_sa_crouch_skill.crouch_tp_drain * delta)))
				state.current_tp = maxi(0, state.current_tp - drain)


## 联机表现接口（C2，由 NetworkWorld 的 sa_presentation 调用）：
## Client 按本地同名技能解析表现——sa_sound、しゃがみ染色/计时、感覚向上计时。
## RECITAL 的敌人踉跄 / BACKPACK 占位不在此复现（前者由 Host 结算经快照体现）。
## 技能解析走 _find_skill_by_trigger 同款回退（两端同一 CharacterData 资源，
## 结果一致），零资源传输。
func apply_network_sa_skill(trigger: String) -> void:
	if not current_character:
		return
	var skill: SkillData = _find_skill_by_trigger(current_character.skills, trigger)
	if not skill:
		return
	if skill.sa_sound:
		var scene: Node = get_tree().current_scene if get_tree() else null
		Global.play_sfx_managed(skill.sa_sound, scene)
	match skill.skill_type:
		SkillData.SkillType.SA_SEEKER:
			_sa_auto_mukiri_until_msec = Time.get_ticks_msec() + int(skill.duration * 1000.0)
		SkillData.SkillType.SA_CROUCH:
			_start_crouch_dodge(skill)
	print("[SA] 联机表现：%s（peer 表现）" % skill.skill_name)


## 联机表现接口（C2，crouch_end_presentation）：Host 权威侧蹲下结束的对齐信号，幂等
## （Client 本地同规则超时大概率已自行结束）。
func apply_network_crouch_end() -> void:
	if _sa_crouch_active:
		_end_crouch_dodge()


## 联机表现接口（C2，counter_presentation）：反击音效（伤害/击退结算在 Host，快照体现）。
func play_network_counter_presentation() -> void:
	if current_character and current_character.counter_sound:
		var scene: Node = get_tree().current_scene if get_tree() else null
		Global.play_sfx_managed(current_character.counter_sound, scene)


## 联机表现接口（C2，heat_presentation）：Heat 染色 + 本地计时置位——
## _update_network_sa_state 推进计时并在到期褪色，与单机同规则。
func apply_network_heat_state() -> void:
	_heat_time = HEAT_DURATION
	if sprite:
		sprite.modulate = Color(1.8, 0.6, 0.6)


## 联机（C2）：Host 权威实体的しゃがみ按住登记（sa_crouch_hold RPC 写入）。
func set_network_crouch_hold(active: bool) -> void:
	_network_sa_crouch_hold = active


# ── 联机丸呑み表现（C3，由 NetworkWorld 的 swallow_presentation / Host 侧
#    EnemySwallowState._hide_victim/_restore_victim 调用）──

## 被吞锁定标志：true 期间 NetworkWorld 冻结本实体的移动（Host 模拟与 Client
## 本地预测两处闸门都读它），Host 侧由 EnemySwallowState 置位，Client 侧由表现置位。
var network_swallow_locked: bool = false


## 吞入/吐出表现：隐藏/恢复 + 碰撞闸（与 EnemySwallowState._hide_victim 同款）
## 并置 network_swallow_locked 锁。Host 权威实体被 _hide_victim 调用时同样生效
## （重复隐藏无害），关键是为 _simulate_host_players 提供冻结判据。
func apply_network_swallow_state(active: bool) -> void:
	if network_swallow_locked == active:
		return
	network_swallow_locked = active
	visible = not active
	if active:
		velocity = Vector2.ZERO
	for c: Node in get_children():
		if c is CollisionShape2D or c is CollisionPolygon2D:
			(c as Node2D).set_deferred("disabled", active)
	print("[敵人] 联机丸呑み表现：%s（peer 表现）" % ("吞入隐藏" if active else "吐出恢复"))


## 联机（C2）：Client 本地实体按帧记录搓招缓冲——_update_motion_input 挂在
## _process 非联机分支，network_controlled 实体不会自行记录，由 NetworkWorld
## 的 _capture_sa_input 每帧代为驱动。
func poll_network_motion_input() -> void:
	_update_motion_input()


## 联机（C2）：SA 请求的搓招预校验（缓冲在本机，Host 无法重放输入序列——
## 请求协议信任 Client 预校验，Host 侧 motion_ok 恒 true）。
func validate_skill_motion(trigger: String) -> bool:
	if not current_character:
		return false
	var skill: SkillData = _find_skill_by_trigger(current_character.skills, trigger)
	if not skill:
		return false
	return _match_motion(skill.command_motion)


## 联机事件统一出口（C2）：Host 结算侧（技能释放/蹲下结束/见切成功/反击/Heat）
## 挂 call；单机（无 NetworkWorld 节点）与 Client 端（world 内 host 闸）均 no-op。
func _announce_network_sa_event(event: String) -> void:
	var tree := get_tree()
	if not tree:
		return
	var scene := tree.current_scene
	if not scene:
		return
	var world: Node = scene.find_child("NetworkWorld", true, false)
	if world and world.has_method("announce_player_sa_event"):
		world.call("announce_player_sa_event", self, event)


## 攻击后硬直是否跳过（说明书被动：コマンドー=机枪/散弹/马格南；かいりき=近战）。
func skip_post_attack(weapon_state_name: String) -> bool:
	if not current_character:
		return false
	if current_character.kairiki and weapon_state_name == "Knife":
		return true
	if current_character.commando and weapon_state_name in ["Smg", "Shotgun", "Magnum"]:
		return true
	return false


## 按触发键查找技能（command_trigger 匹配；无匹配时回退到第一个未绑定触发键的技能）
func _find_skill_by_trigger(skills: Array[SkillData], trigger: String) -> SkillData:
	for s: SkillData in skills:
		if s.command_trigger == trigger:
			return s
	for s: SkillData in skills:
		if s.command_trigger.is_empty():
			return s
	return null


## 每帧记录方向键输入到搓招缓冲
func _update_motion_input() -> void:
	for d: String in MOTION_DIRS:
		if Input.is_action_just_pressed(d):
			_record_motion(d)


func _record_motion(direction: String) -> void:
	_motion_buffer.append(direction)
	if _motion_buffer.size() > MOTION_BUFFER_MAX:
		_motion_buffer.pop_front()


## 检查最近方向输入是否以指定指令序列结尾（如 "下右"）
func _match_motion(motion: String) -> bool:
	if motion.is_empty():
		return true
	var n: int = motion.length()
	if n > _motion_buffer.size():
		return false
	var start: int = _motion_buffer.size() - n
	for i: int in range(n):
		if _motion_buffer[start + i] != motion[i]:
			return false
	return true


# ═══════════════════════════════════════
# 死亡系统
# ═══════════════════════════════════════


## 尝试在死亡时切换到其他存活队员
func _try_switch_on_death() -> bool:
	if _switch_on_death_attempted:
		return false
	_switch_on_death_attempted = true
	var mgr: Node = null
	var tree := get_tree()
	if tree:
		var nodes: Array[Node] = tree.get_nodes_in_group("character_switch_manager")
		if nodes.size() > 0:
			mgr = nodes[0]
	if not mgr:
		return false
	# 把本实体对应座位标记为死亡（否则 next_living_seat 还会把它算作存活）
	var state: PlayerState = Players.get_state_for_entity(self)
	if state:
		state.current_hp = 0.0
	# 尝试切换
	var switched: bool = mgr.switch_after_death()
	if switched:
		print("[玩家] 死亡→切换到下一队员")
	return switched


func _clean_expired_damage_sources(now: int) -> void:
	## 清理超过冷却时间的伤害源记录，防止字典无限增长
	var to_erase: Array[int] = []
	for sid: int in _recent_damage_sources:
		if now - _recent_damage_sources[sid] >= DAMAGE_SOURCE_COOLDOWN_MSEC:
			to_erase.append(sid)
	for sid: int in to_erase:
		_recent_damage_sources.erase(sid)


func _apply_network_death_state() -> void:
	print("[玩家] 联机死亡表现")
	# 【倒地与死亡共用同一套躺地表现】
	# HP=0 后本节点一律先进入这个状态：停动画、切躺地精灵、关碰撞与受击区。
	# 之后它究竟是"倒地（可救援、可爬行）"还是"真死亡"，由 NetworkWorld 的
	# Host 权威状态决定 —— 倒地时 NetworkWorld 会在下一帧通过
	# set_network_downed(true) 重新打开移动碰撞并染红；真死亡则维持本状态。
	# 本函数自己不做任何生死裁决，也不能在 deferred 关闭之外再碰碰撞体。
	_is_dying = true
	_death_phase = 3
	_moving = false
	# 冻结远端实体，避免延迟快照把死亡表现继续向旧目标位置拖动。
	_network_target_position = global_position
	_network_has_target = false
	player_in_weapon_state = false
	velocity = Vector2.ZERO
	_weapon_mode = false
	_weapon_data = null
	apply_network_throwable_presentation(null, false, false, 0)
	_shove_mode = false
	_shove_texture = null
	if animation_timer:
		animation_timer.stop()
	var tex: Texture2D = death_texture if death_texture else walk_texture
	if tex:
		sprite.texture = tex
		var char_col: int = death_char_index % CHARS_PER_ROW
		var char_row: int = death_char_index / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_facing]
		sprite.region_rect = Rect2(char_col * (FRAME_W * 3) + STAND_FRAME * FRAME_W, char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H, FRAME_W, FRAME_H)
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", true)
	if hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)


## 强制致死（无视 ガッツ / 见切 / 无敌帧）。
##
## 用途：丸呑み（ハンターγ）这类原作明确定为「伤害是致死」的必杀技。
## 常规 take_damage 路径会被 ガッツ（HP≥2 保底 1 HP）拦下，无法表达"必死"语义，
## 因此单独开一个入口，直接归零 HP 并走 _die()（保留切人 / オートスプレー 的判定链）。
##
## source_id 仅用于日志与去重记录，不参与判定。
func force_lethal_death(source_id: int = 0) -> void:
	if _is_dying:
		return
	print("[玩家] 强制致死（source_id=%d）" % source_id)
	var state: PlayerState = Players.get_state_for_entity(self)
	if state:
		state.current_hp = 0.0
	current_hp = 0.0
	_die()


## 施加额外的武器削り（弹药/耐久）。供外部必杀技（丸呑み「多段削りで武器も駄目に」）调用。
## extra 为额外削减量：远程扣弹夹，近战扣耐久（0 或负值 = 无动作）。
func apply_weapon_attrition(extra: float = 0.0) -> void:
	if extra <= 0.0:
		return
	# 复用内置削り（每次固定量），再按 extra 追加一轮
	var rounds: int = maxi(1, int(ceilf(extra / maxf(1.0, ATTRITION_DURABILITY))))
	for i: int in rounds:
		_apply_attrition()
	print("[玩家] 丸呑み多段削り：武器削减 %d 轮" % rounds)


func _die() -> void:
	BurnEffect.detach(self)  ## 死亡不留火焰（_update_burn_status 死态早退不摘，在此统一摘）
	if network_controlled:
		# D2 实测修复：联机此前直接进躺地/死亡流程，オートスプレー（HP=0 自动喷雾
		# 满血复活）永远不会触发——表现为「空血条后急救喷雾没起作用」。原作语义
		# 喷雾在 HP=0 拦截，成功则满血继续（HP 经快照 40Hz 同步到 Client 表现）；
		# 无喷雾才落进倒地/真死亡裁决。
		if _try_auto_spray_revive():
			# 伤害信号已在本帧把 entry["downed"] 置 true（先于 _die），必须清除。
			var world: Node = get_tree().current_scene.find_child("NetworkWorld", true, false) \
					if get_tree() and get_tree().current_scene else null
			if world and world.has_method("notify_player_revived"):
				world.call("notify_player_revived", self)
			return
		_apply_network_death_state()
		return
	# ── オートスプレー（原作 system.html）：HP=0 时自动使用急救喷雾 → 满血复活 ──
	# （2026-09-13 用户定稿：**当前角色**直接用喷雾复活，不再"有队友先切人"——
	#   旧顺序先切人，导致只有最后一个角色才轮得到喷雾）
	if _try_auto_spray_revive():
		return
	# 没有喷雾 → 有其他存活队员才切换，否则真死
	if _try_switch_on_death():
		return
	print("[玩家] 死亡！")
	_is_dying = true
	_death_phase = 0

	# 播放死亡音效
	_play_sound(death_sound)

	# 更新本实体对应座位的 HP。
	var state: PlayerState = Players.get_state_for_entity(self)
	if state:
		state.current_hp = 0.0
		# 真死亡计入战役累计（终章 ED「谁死了最多」排名用）
		var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
		if chapter_stats and chapter_stats.has_method("record_death"):
			chapter_stats.record_death(state.seat_index)

	# 停止状态机
	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)

	# 停止移动 & 动画（防止 timer 回调 _refresh_sprite 覆盖死亡帧）
	_moving = false
	player_in_weapon_state = false
	velocity = Vector2.ZERO
	_weapon_mode = false
	_shove_mode = false
	_shove_texture = null
	if animation_timer:
		animation_timer.stop()

	# 显示死亡精灵
	var tex: Texture2D = death_texture if death_texture else walk_texture
	if tex:
		sprite.texture = tex
		var char_col: int = death_char_index % CHARS_PER_ROW
		var char_row: int = death_char_index / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_facing]
		var x: int = char_col * (FRAME_W * 3) + STAND_FRAME * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)

	# 禁用碰撞
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", true)
	# 禁用受击碰撞体
	if hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)

	# 播放死亡音乐
	if not Global.death_music_path.is_empty():
		var music: AudioStream = load(Global.death_music_path) as AudioStream
		if music:
			_play_music(music)

	# 创建黑屏遮罩
	_create_fade_overlay()


func _create_fade_overlay() -> void:
	# CanvasLayer 确保 Control 节点能在 2D 场景之上渲染
	var cl := CanvasLayer.new()
	cl.name = "DeathFadeCanvas"
	cl.layer = 128  # 最顶层

	_death_fade_overlay = ColorRect.new()
	_death_fade_overlay.name = "DeathFadeOverlay"
	_death_fade_overlay.color = Color(0, 0, 0, 0)  # 初始透明
	_death_fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_fade_overlay.size = get_viewport().get_visible_rect().size

	cl.add_child(_death_fade_overlay)

	var tree: SceneTree = get_tree()
	if tree and tree.current_scene:
		tree.current_scene.add_child(cl)
		_death_fade_timer = 0.0
		_death_phase = 1


## オートスプレー（原作 §4）：HP=0 时自动消耗急救喷雾（单机=共用池；联机=自己→其他座位），
## 满血复活。返回 true = 已复活，跳过死亡流程。
func _try_auto_spray_revive() -> bool:
	var own: PlayerState = Players.get_state_for_entity(self)
	if Players.using_shared_spray_pool():
		# 单机共用池：当前角色直接用（2026-09-13 用户定稿）
		if Players.team_spray_count <= 0:
			return false
		Players.consume_team_spray()
	else:
		# 联机：自己座位优先 → 其他座位
		var donor: PlayerState = null
		if own and own.healing_item_count > 0:
			donor = own
		else:
			for s: PlayerState in Players.seats:
				if s and s.healing_item_count > 0:
					donor = s
					break
		if donor == null:
			return false
		donor.healing_item_count -= 1
		if donor.healing_item_count <= 0:
			donor.healing_item = null
			donor.healing_item_count = 0
	current_hp = max_hp
	if own:
		own.current_hp = current_hp
	_play_hit_feedback(Color(1.6, 2.0, 1.6, 1.0), 0.4)
	print("[自动喷雾] HP=0 → 自动使用急救喷雾，满血复活（队伍剩余 %d）" % Players.spray_total())
	return true


## 全队共用喷雾总数（HUD 显示与日志用）。
func _team_spray_total() -> int:
	return Players.spray_total()


func _process_death(delta: float) -> void:
	match _death_phase:
		1:  # 渐黑
			_death_fade_timer += delta
			var progress: float = clampf(_death_fade_timer / Global.death_fade_duration, 0.0, 1.0)
			if _death_fade_overlay:
				_death_fade_overlay.color = Color(0, 0, 0, progress)
			if progress >= 1.0:
				_death_fade_timer = 0.0
				_death_phase = 2
				print("[玩家] 黑屏完成，等待重载...")

		2:  # 全黑等待
			_death_fade_timer += delta
			if _death_fade_timer >= Global.death_black_hold:
				_death_phase = 3
				_reload_from_save()

		3:  # 已触发重载，等待
			pass


func _reload_from_save() -> void:
	# 死亡后从 checkpoint 恢复所有状态（HP/装备/弹药/队伍），再回到安全屋。
	## ⚠ 2026-09-16 修复「复活多次后队伍从 3 人缩到 1 人」：
	## 旧实现在恢复后立刻 Global.checkpoint.clear()。若玩家在「再次抵达安全屋捕获新快照」之前
	## 又死一次，restore_checkpoint() 就只剩「无 checkpoint，保持当前状态」分支 —— 把上次死亡
	## 留下的「某角色 HP=0」原样保留，于是每死一次就永久少一个可操控角色（测试者实测）。
	## checkpoint 只在「新游戏 / 选角确认」时清除（init_new_game / _confirm_team），
	## 安全屋每次到位都会重新 capture 覆盖 —— 因此这里必须保留它作为复活锚点。
	print("[玩家] 死亡，从 checkpoint 恢复...")
	var safehouse: String = Global.get_checkpoint_scene()
	Global.restore_checkpoint()
	_log_team_state("死亡复活后")
	var tree: SceneTree = get_tree()
	if not tree:
		return
	if not safehouse.is_empty() and safehouse != tree.current_scene.scene_file_path:
		# 不在安全屋 → 切回安全屋场景
		var err := tree.change_scene_to_file(safehouse)
		if err != OK:
			printerr("[玩家] 无法切回安全屋: %s (err=%d)" % [safehouse, err])
			tree.reload_current_scene()
	else:
		# 已在安全屋死亡 → 直接重载
		tree.reload_current_scene()


## 复活/队伍诊断（2026-09-16）：逐席位打印「角色 + HP」，
## 用于定位「选了 N 人却只剩 1 人可操控」这类队伍缩水问题（配合 [Checkpoint] 日志一起看）。
func _log_team_state(tag: String) -> void:
	var parts: Array[String] = []
	for i: int in range(Players.seat_count()):
		var st: PlayerState = Players.get_seat(i)
		if st and st.character:
			parts.append("席位%d=%s HP=%.0f" % [i, st.character.resource_path.get_file(), st.current_hp])
		elif st:
			parts.append("席位%d=<无角色> HP=%.0f" % [i, st.current_hp])
		else:
			parts.append("席位%d=<空>" % i)
	print("[玩家] %s 队伍=%d 人 | %s" % [tag, Players.seat_count(), " ".join(parts)])


# ═══════════════════════════════════════
# 丢弃全部武器（E 键，2026-09-16 用户需求）
# ═══════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	## 用 _unhandled_input 而不是 _process 轮询：UI（菜单/安全门/拾取提示）会先消费按键，
	## 否则开着菜单按 E 也会把武器丢一地。
	if event.is_action_pressed("丢弃武器键"):
		get_viewport().set_input_as_handled()
		request_drop_all_weapons()


## E 键入口：单机本地丢弃；联机交给 Host 权威事务（Client 只提交意图，等快照回包）。
func request_drop_all_weapons() -> void:
	if _is_dying or network_downed:
		return
	var scene: Node = get_tree().current_scene
	var world: Node = scene.find_child("NetworkWorld", true, false) if scene else null
	var net: Node = get_node_or_null("/root/Net")
	var online: bool = net != null and net.has_method("is_online_session") and bool(net.is_online_session())
	if online and world and world.has_method("request_drop_all"):
		world.call("request_drop_all")
		return
	_drop_all_weapons_locally()


## 单机：两个武器槽全部丢到地上（落点自动避让 24px，见 weapon_pickup.find_free_drop_position）。
func _drop_all_weapons_locally() -> void:
	var state: PlayerState = Players.get_state_for_entity(self)
	if not state:
		return
	var dropped: int = 0
	for slot: String in ["primary", "secondary"]:
		var wd: WeaponData = state.get_equipped_weapon(slot)
		if wd == null:
			continue
		WEAPON_PICKUP_SCRIPT.drop_weapon_for_player(self, wd)
		state.unequip_slot(slot)
		dropped += 1
	if dropped == 0:
		return
	## 手里空了 → 收起武器模式（状态机在 _wd == null 时会自愈回 Idle）
	if is_weapon_mode_active():
		exit_weapon_mode()
	print("[玩家] 丢弃全部武器：%d 件" % dropped)


# ═══════════════════════════════════════
# 音效工具
# ═══════════════════════════════════════

func _play_sound(stream: AudioStream) -> void:
	if not stream:
		return
	Global.play_sfx_managed(stream, self)


func _play_music(stream: AudioStream) -> void:
	## 播放全局音乐（替换当前音乐）
	if not stream:
		return
	# 停止已有的音乐
	for child: Node in get_children():
		if child is AudioStreamPlayer and child.name == "DeathMusicPlayer":
			child.stop()
			child.queue_free()

	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.name = "DeathMusicPlayer"
	player.stream = stream
	player.bus = "Music"
	player.volume_db = Global.death_music_volume_db
	player.autoplay = true
	add_child(player)


# ═══════════════════════════════════════
# Debug 可视化（TAB 切换）
# ═══════════════════════════════════════

func _draw() -> void:
	if not Global.debug_visuals:
		return
	# 绘制玩家碰撞体
	var cs: CollisionShape2D = $CollisionShape2D
	var shape: Shape2D = cs.shape
	if shape is RectangleShape2D:
		var rect: RectangleShape2D = shape as RectangleShape2D
		var color: Color = Color.GRAY if _is_dying else Color.GREEN
		var pos: Vector2 = cs.position
		draw_rect(Rect2(pos - rect.size / 2, rect.size), color, false, 1.0)
	# 绘制 HP 条
	var bar_w: float = 48.0
	var bar_h: float = 4.0
	var bar_y: float = -40.0
	var ratio: float = current_hp / max_hp
	draw_rect(Rect2(-bar_w/2, bar_y, bar_w, bar_h), Color.RED, false, 1.0)
	draw_rect(Rect2(-bar_w/2, bar_y, bar_w * ratio, bar_h), Color.GREEN if not _is_dying else Color.GRAY, true)

	# 绘制受击碰撞体（黄色虚线）
	if hurt_area:
		var hshape_node: CollisionShape2D = hurt_area.get_node_or_null("HurtShape")
		if hshape_node and hshape_node.shape is RectangleShape2D:
			var hs: Vector2 = (hshape_node.shape as RectangleShape2D).size
			var ho: Vector2 = hshape_node.position
			draw_rect(Rect2(ho - hs / 2, hs), Color.YELLOW, false, 1.0)


# ═══════════════════════════════════════
# 内部
# ═══════════════════════════════════════

func _refresh_sprite() -> void:
	if not sprite:
		return
	if _is_dying:   ## 死亡后拒绝一切刷新，防止覆盖 _die() 设置的死亡帧
		return

	# 投掷物举起模式：使用投掷物行走图（跟随朝向+踏步）
	if _throwable_mode and _throwable_texture:
		sprite.texture = _throwable_texture
		var char_idx: int = _throwable_char_idx
		var frame: int = STAND_FRAME if not _moving else WALK_SEQUENCE[_anim_step]
		var char_col: int = char_idx % CHARS_PER_ROW
		var char_row: int = char_idx / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_facing]
		var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
		return

	# 武器模式下使用武器纹理和角色索引
	if _weapon_mode and _weapon_data:
		# 推击模式：优先推击行走图（运行时设置 > 武器字段 > 角色字段 > 回退普通武器纹理）
		if _shove_mode and _shove_texture:
			sprite.texture = _shove_texture
		else:
			var tex: Texture2D = null
			# 角色专属武器行走图
			if current_character:
				tex = current_character.get_weapon_walk_texture(_weapon_data.weapon_state_name)
			# 回退到武器默认行走图
			if not tex:
				tex = _weapon_data.weapon_walk_texture
			if not tex:
				return
			sprite.texture = tex
		var char_idx: int = _current_weapon_char_idx
		var frame: int = STAND_FRAME if not _moving else WALK_SEQUENCE[_anim_step]

		var char_col: int = char_idx % CHARS_PER_ROW
		var char_row: int = char_idx / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_facing]

		var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
		return

	# 普通模式
	if not walk_texture or not run_texture:
		return
	var use_run_tex: bool = _moving and not _is_walking
	sprite.texture = run_texture if use_run_tex else walk_texture

	var char_idx: int = run_char_index if use_run_tex else walk_char_index
	var frame: int = STAND_FRAME if not _moving else WALK_SEQUENCE[_anim_step]

	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var dir_row: int = DIR_ROWS[_facing]

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H

	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
