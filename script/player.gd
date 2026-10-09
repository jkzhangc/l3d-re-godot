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
## 【2026-10-08】帧常量的**唯一真源**已随渲染逻辑移到 player_sprite_renderer.gd；
## 这里保留同名转发别名，本文件其余引用（_play_mukiri_anim / _die / 联机死亡）与
## 任何外部引用零改动。
const FRAME_W: int = SpriteRenderer.FRAME_W   ## 576 / 12
const FRAME_H: int = SpriteRenderer.FRAME_H   ## 512 / 8
const CHARS_PER_ROW: int = SpriteRenderer.CHARS_PER_ROW
const DIRECTIONS: int = SpriteRenderer.DIRECTIONS

## VX Ace 帧序列: frame1 → frame0 → frame1 → frame2 → frame1（循环）
const WALK_SEQUENCE: Array[int] = SpriteRenderer.WALK_SEQUENCE
const STAND_FRAME: int = SpriteRenderer.STAND_FRAME

## 方向 → 行偏移（VX Ace: 下/左/右/上）
const DIR_ROWS: Array[int] = SpriteRenderer.DIR_ROWS
const DAMAGE_SOURCE_COOLDOWN_MSEC: int = 1000  ## 同一伤害源重复命中冷却（毫秒）

enum FaceDir { DOWN = 0, LEFT = 1, RIGHT = 2, UP = 3 }

# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════
@onready var sprite: Sprite2D = $Sprite2D
@onready var animation_timer: Timer = $AnimationTimer
@onready var hurt_area: Area2D = _setup_hurt_area()

## 精灵渲染服务（_ready 创建；持有本实体引用，见 script/player_sprite_renderer.gd）。
var _sprite_renderer: SpriteRenderer = null
## 音效服务（_ready 创建；见 script/player_sfx.gd）。
var _sfx: SfxService = null
## 调试可视化服务（_ready 创建；见 script/player_debug_drawer.gd）。
var _debug_drawer: DebugDrawer = null
## 特殊行动服务（_ready 创建；见 script/player_special_action_service.gd）。
var _special_action: SpecialAction = null
## 死亡系统服务（_ready 创建；见 script/player_death_service.gd）。
var _death_service: DeathService = null

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
## 玩家本体的**原始碰撞层**。倒地时临时归零、复活时还原 ——
## 用 @onready 取，才能在场景/预制体改了 layer 之后依然正确。
@onready var _base_collision_layer: int = collision_layer
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

## 精灵渲染服务（2026-10-08 拆分：渲染逻辑抽到 player_sprite_renderer.gd，本文件保留转发门面）。
const SpriteRenderer := preload("res://script/player_sprite_renderer.gd")
## 音效服务（2026-10-08 拆分：SFX/音乐抽到 player_sfx.gd）。
const SfxService := preload("res://script/player_sfx.gd")
## 调试可视化服务（2026-10-08 拆分：调试绘制抽到 player_debug_drawer.gd）。
const DebugDrawer := preload("res://script/player_debug_drawer.gd")
## 特殊行动服务（2026-10-08 拆分：SA/见切/反击/Heat/削り/覚醒/搓招抽到
## player_special_action_service.gd，本文件保留同名转发门面）。
const SpecialAction := preload("res://script/player_special_action_service.gd")
## 死亡系统服务（2026-10-08 拆分：死亡流程/丢弃武器抽到 player_death_service.gd）。
const DeathService := preload("res://script/player_death_service.gd")

## 远端玩家位置插值：快照样本按**自适应**固定延迟渲染，取代旧的指数平滑。
## 2026-10-01（用户："尽量让玩家感觉不到延迟"）：本值是**延迟下限**，取 ≈ 2.2 个 60Hz 快照间隔
## （16.7ms × 2.2 ≈ 37ms，原固定 50ms）；网络抖动时插值器自己临时加缓冲，
## 平稳时不再白等那 13ms。见 `script/network_snapshot_interp.gd` 顶部说明。
const NETWORK_RENDER_DELAY := 0.037
## 生效延迟**硬上限**（用户 2026-10-01："网络有 100ms 也尽量保持 70ms 左右"）：
## 抖动再持续，远端玩家也不会被渲染得比 70ms 更旧。
const NETWORK_MAX_RENDER_DELAY := 0.070

var _remote_interp: Variant = null
var _network_attack_token: int = 0
var _network_reload_was_facing_locked: bool = false

var _tp_regen_timer: float = 0.0

# ── SA（说明书 §6.1 特殊行动）运行时 ──
var _sa_crouch_active: bool = false      ## しゃがみ回避进行中（无敌）
var _sa_crouch_until_msec: int = 0       ## 无敌截止时间
var _sa_crouch_skill: SkillData = null   ## 当前しゃがみ技能（取持续消耗参数）
## しゃがみ按住消耗的**小数累加器**（见 `_drain_crouch_tp`）：不足 1 点的部分留到下一帧，
## 保证消耗速率与帧率无关（旧实现每帧至少扣 1 → 实际速率 = 帧率，60fps 时是设计值的 4 倍）。
var _sa_crouch_drain_accum: float = 0.0
var _network_sa_crouch_hold: bool = false ## C2：Host 权威实体的しゃがみ按住登记（sa_crouch_hold RPC 写入）
var _sa_auto_mukiri_until_msec: int = 0  ## 感覚向上：完全见切截止时间

# ── 见切/反击（说明书 §4.3）运行时 ──
## 【2026-10-08】下列常量的**唯一真源**已随逻辑移到 player_special_action_service.gd；
## 这里保留同名转发别名，本文件内引用与外部（如 tools 测试）零改动。
const MUKIRI_WINDOW_MS: int = SpecialAction.MUKIRI_WINDOW_MS        ## 见切判定窗口（原作 0.3 秒，"大甘"）
const MUKIRI_INTERVAL_MS: int = SpecialAction.MUKIRI_INTERVAL_MS    ## 两次见切输入的最小间隔（原作 0.7 秒）
const COUNTER_COOLDOWN_MS: int = SpecialAction.COUNTER_COOLDOWN_MS  ## 反击触发冷却，防一次窗口内重复触发
var _mukiri_window_until_msec: int = 0      ## 见切窗口截止时间
var _mukiri_last_attempt_msec: int = -10000 ## 上次见切输入时间
var _counter_cooldown_until_msec: int = 0   ## 反击冷却截止时间
var _mukiri_anim_busy: bool = false         ## 见切动画播放中（防重入）

# ── Heat / 削り（原作说明书 §4.6）──
const HEAT_DURATION: float = SpecialAction.HEAT_DURATION            ## Heat 持续秒数（原作未公开精确值，按体感）
const ATTRITION_AMMO: int = SpecialAction.ATTRITION_AMMO            ## 削り：弹夹每次 -2
const ATTRITION_DURABILITY: float = SpecialAction.ATTRITION_DURABILITY  ## 削り：耐久每次 -8
var _heat_time: float = 0.0                 ## Heat 剩余时间（>0=禁止见切/TP停/Guts停）

# ── 覚醒コマンド（原作：構え中 Z+X；のび太=集中射撃）──
const AWAKEN_TP_DRAIN_PER_SEC: float = SpecialAction.AWAKEN_TP_DRAIN_PER_SEC  ## 发动中 TP 缓慢消耗
const AWAKEN_DAMAGE_MULT: float = SpecialAction.AWAKEN_DAMAGE_MULT            ## 射撃威力上升倍率
const AWAKEN_BOSS_DAMAGE_MULT: float = SpecialAction.AWAKEN_BOSS_DAMAGE_MULT  ## 即死对 Boss 无效 → ×1.5
const AWAKEN_HITSTUN_SEC: float = SpecialAction.AWAKEN_HITSTUN_SEC            ## 怯み时长
var _awaken_active: bool = false            ## 覚醒发动中（集中射撃）
var _awaken_tint_applied: bool = false      ## 觉醒金色染色是否已上（还原时区分 Heat 染色）

## 搓招方向输入缓冲
const MOTION_DIRS: Array[String] = SpecialAction.MOTION_DIRS
const MOTION_BUFFER_MAX: int = SpecialAction.MOTION_BUFFER_MAX
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


func _init() -> void:
	## ⚠ 表现层服务必须在 `_init` 创建，**不能放 `_ready`**：
	## Godot 的 `_ready` 顺序是**子节点先于父节点**，而 StateMachine（player 的子节点）
	## 在自己的 `_ready` 里就会 `PlayerIdleState.enter()` → `update_appearance()`
	## → `_refresh_sprite()`。若服务在 player._ready 才建，这条早期链路会命中 null 服务
	## （实测：`Nonexistent function 'refresh_sprite' in base 'Nil'`）。
	## 服务构造只保存宿主引用、不读任何字段，故此时创建安全。
	_sprite_renderer = SpriteRenderer.new(self)
	_sfx = SfxService.new(self)
	_debug_drawer = DebugDrawer.new(self)
	_special_action = SpecialAction.new(self)
	_death_service = DeathService.new(self)


func _ready() -> void:
## 初始化实体表现并绑定单机座位。network_controlled 实体由 NetworkWorld 接管，不能注册到单机 active_seat。
	add_to_group("player")
	_remote_interp = NETWORK_SNAPSHOT_INTERP.new(NETWORK_RENDER_DELAY, NETWORK_MAX_RENDER_DELAY)
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


# ═══════════════════════════════════════
# 卡墙自救（2026-10-02 用户反馈）
# ═══════════════════════════════════════
## 用户实测复现：「很多敌人追逐玩家时，玩家后面有墙 → 敌人会一直挤玩家，会把玩家挤进墙，
## 有几率玩家就会在屋顶或者墙里出不来了」。
## 【为什么会卡死】Godot 的 CharacterBody2D 去重叠修正会把深重叠的玩家往外推，墙在身后时
## 就被推进墙格；而图块碰撞是**整格**的 —— 一旦整格陷进墙里，普通移动再也出不来。
## 【判据只认地图】图块挡住 / 不在任何图块上（被挤到地图外或"屋顶"）；**不看敌人 body** ——
## 否则被敌人贴脸（body 重叠）就会被误判成卡墙、把人瞬移出去，观感很怪。
## 【谁执行】只在本端对位置有权威时：单机全体 / 联机仅 Host。Client 不自救 ——
## 它的位置由 Host 权威，Host 修好后经 `_network_target_position` 硬校准自动跟随。
const STUCK_CHECK_INTERVAL := 0.5      ## 检查间隔（秒）
const STUCK_CONFIRM_HITS := 2          ## 连续命中几次才判定（≈1 秒，滤掉瞬时假阳性）
const STUCK_PROBE_RADIUS := 14.0       ## 与 SpawnSpotResolver.PROBE_RADIUS 同口径（玩家盒 24×27）
const SPOT_RESOLVER := preload("res://script/director/spawn_spot_resolver.gd")
const GAME_LOG := preload("res://script/game_log.gd")

var _stuck_timer: float = 0.0
var _stuck_hits: int = 0


func _rescue_if_stuck(delta: float) -> void:
	_stuck_timer += delta
	if _stuck_timer < STUCK_CHECK_INTERVAL:
		return
	_stuck_timer = 0.0
	if _is_dying or is_network_dead():
		_stuck_hits = 0                ## 死亡/倒地不阻挡，位置无意义，别去动
		return
	var net: Node = get_node_or_null("/root/Net")
	if net != null and bool(net.get("handshake_ok")) and not bool(net.get("is_host")):
		_stuck_hits = 0                ## 联机 Client：等 Host 权威修正
		return
	if not is_inside_tree():
		return
	var here: Vector2 = global_position
	var in_wall: bool = SPOT_RESOLVER.is_tile_blocked(self, here)
	var off_map: bool = not SPOT_RESOLVER.has_tile(self, here)
	if not (in_wall or off_map):
		_stuck_hits = 0
		return
	_stuck_hits += 1
	if _stuck_hits < STUCK_CONFIRM_HITS:
		return
	## 找最近可站点：`require_tile` 保证既不落墙里、也不落地图外的虚空。
	var fixed: Variant = SPOT_RESOLVER.find_near(self, here, STUCK_PROBE_RADIUS, Callable(), true, true)
	if fixed is Vector2:
		var target: Vector2 = fixed
		GAME_LOG.log_event("卡墙自救", "%s 卡在 %s（%s）→ 纠正到 %s" % [
			name, here.round(), "墙里" if in_wall else "地图外/虚空", target.round()])
		global_position = target
		velocity = Vector2.ZERO
		_stuck_hits = 0
	else:
		GAME_LOG.log_error("卡墙自救", "%s 在 %s 四周找不到可站点（严重卡死，下次继续尝试）"
			% [name, here.round()])


func _process(delta: float) -> void:
	_update_burn_status(delta)  # 灼烧 DoT（本机/远端实体均结算，死态内部早退）
	## 卡墙自救：放在联机分支**之前** —— 联机实体在下面会提前 return，放后面就只管单机了。
	_rescue_if_stuck(delta)
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
	_sanitize_facing_lock()
	_try_shove_interrupt()


## ── 推击中断（2026-10-03 用户需求：对齐 L4D2 手感）──
## 「推击」在 L4D2 里是**万能打断动作** —— 攻击中、换弹中都能推出去把贴脸丧尸顶开。
## 旧实现只在 `PlayerPistolState` / `PlayerKnifeState` 的 **READY 阶段**读推击键，
## 于是「正在开枪 / 正在换弹」时按推击键毫无反应，玩家必须先停手再推（用户反馈手感不好）。
##
## 【为什么收敛到 Player 层而不是各状态各加一处】
##   用户要的是「能中断**任何**状态」。若逐状态加，将来新增状态（霰弹枪专用、双持…）
##   必然漏加 → 又变成"有时候推不出来"。这里做**唯一入口**，覆盖举枪/攻击/装弹全部武器状态。
##
## 【拦截判据】
##   · **不要求举着武器**（2026-10-03 用户需求：「玩家没举起武器的时候也能用推击」）——
##     L4D2 里推击是任何时候都能做的保命动作，不必先举枪；武器数据取 `active_weapon_slot`
##     的当前值（空手状态也拿得到），推击结束后按"进入前是否举武器"回到对应状态。
##   · 排除**投掷物模式**（`_throwable_mode`）：正在瞄投掷物时不推，避免与投掷/取消键冲突；
##   · 当前状态已是 `Shove` → 不打断自己（否则会重入、动画被重置）；
##   · `can_shove()` → 尊重既有的推击疲劳冷却（冷却中静默忽略，不消耗次数）。
##
## 【为什么用 `_process` 轮询而不是 `_unhandled_input`】
##   与 `HoldoutMachine` 的互动键同款理由（见该处注释）：事件派发路径会被别的节点
##   consume / 抢焦点而静默失效。轮询只依赖输入状态。且游戏暂停时 `_process` 不跑，
##   「菜单里按推击键」不会误触发，安全性由引擎保证。
##
## 【联机】本函数**只管单机**：联机实体的状态机已被 `_disable_network_state_machine()`
##   关掉，推击由 `NetworkWorld._capture_shove_input()` 独立处理（Host 权威结算），
##   两条路径互斥，不会双触发。
func _try_shove_interrupt() -> void:
	if network_controlled or _is_dying:
		return
	if not Input.is_action_just_pressed("推击键"):
		return
	## 投掷物瞄准中不推（要与投掷/取消键区分开）；空手状态**允许**推击。
	if _throwable_mode:
		return
	var sm: Node = get_node_or_null("StateMachine")
	if sm == null or not sm.has_method("request_state"):
		return
	if String(sm.call("current_state_name")) == "Shove":
		return
	if not can_shove():
		return
	## 记下进入前的姿态（举枪 / 空手），推击结束时照此返回。
	remember_return_pose_state()
	sm.call("request_state", "Shove")


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


## 调试瞬移（仅调试热键 Ctrl+R 用）：硬切位置 + 清空插值目标，不播任何过渡。
## 常规表现路径（apply_network_presentation / authority_target）都是**平滑插值**，
## 跨半张地图的调试瞬移会变成"一路滑过去"；调试键要的就是"立刻到"，所以单独开这个口子。
func debug_hard_teleport(new_position: Vector2) -> void:
	global_position = new_position
	_network_target_position = new_position
	_network_has_target = false
	_remote_interp.reset(new_position)
	velocity = Vector2.ZERO
	_moving = false


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
	## ★倒地时**别人应该能穿过我**（队友走位、敌人不被躺地的玩家卡住），
	##   但**我自己仍要与地形碰撞**（倒地爬行不能穿墙）。
	##   做法 = 只把 `collision_layer` 归零（"我不再被别人检测到"），
	##   `collision_mask` 保持不动（"我照样撞墙"）。
	##   2026-09-28 实测反馈：此前倒地保留完整碰撞 → 敌人被倒地的玩家卡住。
	_set_body_collision_layer(0 if enabled else _base_collision_layer)
	if enabled and hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)
	print("[玩家] 联机倒地状态: %s" % str(enabled))


## 改本体碰撞层（延迟写，避免在物理回调里直接改）。
func _set_body_collision_layer(layer_value: int) -> void:
	if collision_layer == layer_value:
		return
	set_deferred("collision_layer", layer_value)


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
	return _sprite_renderer.mode_anim_duration(is_walking)


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
	## ★★ 这里**不再**解除覚醒、也**不再**解除固定朝向（2026-10-03 用户实测两条）。
	## 【根因】本函数**职责过载**：它同时被「真的放下武器」（`_begin_lower()`）和
	##   「状态切换」（攻击 / 装弹 / 推击的 `exit()` 都会先退再进武器模式）调用。
	##   10-02 与更早为修「锁残留 / 覚醒残留」，把两个收敛动作塞了进来 ——
	##   覆盖面够大，但**误伤了每一次状态切换**：玩家一开枪，辛苦锁好的朝向被解掉、
	##   刚开的覚醒也掉了。
	## 【现在的规则】本函数只负责"武器模式开关"本身。两个收敛动作各有明确归属：
	##   · 固定朝向 → `_sanitize_facing_lock()`（单机每帧幂等）；
	##                联机由 `NetworkWorld._try_host_toggle_weapon` 的**放下武器**动作触发。
	##   · 覚醒     → `deactivate_awaken()`：单机由 `_begin_lower()` 触发，
	##                联机同上（放下武器动作）。★都是**动作驱动**，不是每帧推断 ——
	##                每帧推断会误伤"没举武器也能测覚醒"的既有语义。
	_refresh_sprite()


## ★推击 / 投掷物这类**临时姿态**结束后要回到的状态名（`""` = 空手 Idle）。
##
## 【为什么需要 Player 层记这个】状态切换必经 `前状态.exit()` → `exit_weapon_mode()`，
## 它会把 `_weapon_mode` / `_weapon_data` 一并清空 —— 于是新状态的 `enter()` **根本读不到**
## "玩家进来之前举没举枪"。若让临时状态自己判断，结论永远是"空手"，
## 表现为「举着枪推一下就变成空手」/「掏完手雷枪没了」。
## 所以由 Player 层在**发起切换之前**记下，临时状态结束时取用（取用即清空，避免陈旧值）。
var _return_pose_state: String = ""


## 当前姿态对应的**状态节点名**：举着武器 → 该武器的路由状态名（"Ranged"/"Melee"）；空手 → `""`。
## ⚠ 用 `get_state_node_name()` 而非 `weapon_state_name`（"Pistol"/"Knife"…）——后者只是外观/被动
##   查询键，不是节点名；本返回值最终会被 `request_state()` 当节点名用（推击/投掷物结束后回归）。
func _current_weapon_state_name() -> String:
	if not _weapon_mode or _weapon_data == null:
		return ""
	return _weapon_data.get_state_node_name()


## 取出并清空"临时姿态结束后要回到的状态名"（供 PlayerShoveState / PlayerThrowableState 调用）。
func take_return_pose_state() -> String:
	var back: String = _return_pose_state
	_return_pose_state = ""
	return back


## 由**发起方**在切到"临时姿态"（推击 / 投掷物）之前调用：记下当前姿态供其返回。
## 统一入口，避免各处直接写私有字段。
func remember_return_pose_state() -> void:
	_return_pose_state = _current_weapon_state_name()


## ★固定朝向只在「举着武器」时才有意义（玩家用取消键锁定的姿势能力）。
## 一旦离开武器 / 投掷物模式，玩家再也没有途径去解锁 —— 锁残留会让
## `update_facing()` 一直走锁定分支，表现为**不举武器却无法转身**。
## 这里做**收敛兜底**：与"谁调用了 exit_weapon_mode"解耦，任何路径漏了解锁都能自愈。
## （单机路径每帧调用；联机由 `NetworkWorld._capture_facing_lock_input` 走 RPC 处理。）
func _sanitize_facing_lock() -> void:
	if not _facing_locked:
		return
	if _weapon_mode or _throwable_mode:
		return
	unlock_facing()


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
	# 举起/放下音效（2026-09-24 音效审计）：单机在各自序列的起始帧播放
	# （PlayerPistolState / PlayerKnifeState 的 raise_sound / lower_sound），
	# 联机表现此前完全不播 —— 换枪全程静音。
	_play_network_sfx(wd.raise_sound if raising else wd.lower_sound)
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
		# 推击音效（2026-09-24 音效审计）：单机在 shove_hit_at_sequence_idx 帧触发，
		# 联机表现此前完全不播声音。
		if index == wd.shove_hit_at_sequence_idx:
			_play_network_sfx(wd.shove_sound)
		set_attack_char_index(wd.get_shove_char_sequence()[index])
		await get_tree().create_timer(wd.shove_frame_duration).timeout
	if token == _network_attack_token and is_inside_tree():
		exit_shove_mode()
		set_weapon_ready_frame()
		player_in_weapon_state = false


func _run_network_reload_presentation(token: int, wd: WeaponData, loaded_count: int) -> void:
	# 装填音效（2026-09-24 用户实测「联机装填没有声音」）：单机由 PlayerReloadState 在
	# 三个时点播放（NORMAL=装填音 / SHOTGUN=每发循环音 + 结束上膛音），联机表现此前只播
	# 动画不播声音 → 联机全程静音装填。这里与单机逐时点对齐。
	if wd.reload_mode == WeaponData.ReloadMode.SHOTGUN:
		for _shell: int in range(loaded_count):
			if token != _network_attack_token or not is_inside_tree():
				return
			_play_network_sfx(wd.shotgun_reload_loop_sound)
			for index: int in range(wd.get_shotgun_loop_char_sequence().size()):
				if token != _network_attack_token or not is_inside_tree():
					return
				set_attack_char_index(wd.get_shotgun_loop_char_sequence()[index])
				await get_tree().create_timer(wd.get_shotgun_loop_frame_duration(index)).timeout
		if token != _network_attack_token or not is_inside_tree():
			return
		_play_network_sfx(wd.shotgun_reload_end_sound)
		for index: int in range(wd.get_shotgun_end_char_sequence().size()):
			if token != _network_attack_token or not is_inside_tree():
				return
			set_attack_char_index(wd.get_shotgun_end_char_sequence()[index])
			await get_tree().create_timer(wd.get_shotgun_end_frame_duration(index)).timeout
	else:
		if token != _network_attack_token or not is_inside_tree():
			return
		_play_network_sfx(wd.reload_sound)
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
				## 特效偏移（2026-09-23 迁移）：改由武器数据按角色提供，与子弹偏移同构。
				## 未配置条目的角色 → 回退武器级 attack_effect_offset_override。
				var offset := wd.get_attack_effect_offset(current_character, facing, wd.attack_effect_offset_override)
				var follow: Node2D = self if wd.attack_effect_follow else null
				VXAnimSprite.play_scene(effect_scene, global_position, scene, 10.0, follow, offset)
		var duration := wd.get_attack_frame_duration(index) if wd.is_ranged else wd.get_melee_attack_frame_duration(index)
		if not is_inside_tree():
			return
		var wait_tree := get_tree()
		if not wait_tree:
			return
		await wait_tree.create_timer(duration).timeout
	# 攻击后动画 + 其音效（2026-09-24 音效审计）：单机在攻击序列结束后由
	# PlayerPistolAttackState 播放（散弹枪配了 post_attack_char_sequence=[5,3,2] 与
	# post_attack_sound），联机表现此前整段缺失（既无动画也无声音）。
	# コマンドー 被动（Smg/Shotgun/Magnum 无硬直）同规则跳过。
	if token != _network_attack_token or not is_instance_valid(self) or not is_inside_tree():
		return
	var post_sequence: Array[int] = wd.get_post_attack_char_sequence()
	if not post_sequence.is_empty() and not skip_post_attack(wd.weapon_state_name):
		_play_network_sfx(wd.post_attack_sound)
		for index: int in range(post_sequence.size()):
			if token != _network_attack_token or not is_instance_valid(self) or not is_inside_tree():
				return
			set_attack_char_index(post_sequence[index])
			var post_duration := wd.get_post_attack_frame_duration(index)
			if not is_inside_tree():
				return
			var post_tree := get_tree()
			if not post_tree:
				return
			await post_tree.create_timer(post_duration).timeout
	if token == _network_attack_token and is_instance_valid(self) and is_inside_tree():
		set_weapon_ready_frame()
		player_in_weapon_state = false


func get_weapon_data() -> WeaponData:
	return _weapon_data


## ★装备槽武器被外部替换后重绑表现（2026-10-03 用户实测「举着武器时换枪，行走图对不上」）。
##
## 【根因】`_weapon_data` / `_current_weapon_char_idx` 是**举起瞬间的快照**，而槽位里
##   的武器可以被 `weapon_pickup._do_pickup()`（拾取替换）、`equip_weapon_in_slot()` 直接换掉，
##   旧实现**不通知实体**。于是举着 A 枪时拾起 B 枪替换同一槽位：
##   · 实体仍持 `_weapon_data = A` + A 的 `_current_weapon_char_idx`（贴图与帧索引都属 A）；
##   · 状态机下次攻击走 `_get_weapon()` → `get_active_weapon()` 拿到 **B**。
##   两者错位 → 行走图显示 A 的帧、攻击/枪口效果用 B 的数据，视觉上就是「枪换了但图没对上」。
##
## 【修法】换装完成后由调用方转到这里：仍在武器模式就**按新武器重举一次**（跳过举起动画），
##   不在武器模式则只清快照，让下一次 `enter_weapon_mode()` 正常读新武器。
## ⚠ 必须整体重置 `_current_weapon_char_idx`（不能只换 `_weapon_data`）：
##   索引是按旧武器的 raise 序列取的，沿用会取到新贴图上的越界/错位帧。
func rebind_weapon_after_equip(wd: WeaponData) -> void:
	if _is_dying:
		return
	if _weapon_mode and wd and not wd.weapon_state_name.is_empty():
		_weapon_data = wd
		_current_weapon_char_idx = wd.get_raise_char_sequence()[0]
		# 跳过举起动画直接落到就绪帧（等价联机侧的 weapon_skip_raise 语义）
		set_weapon_ready_frame()
		print("[玩家] 换装后重绑武器表现: %s" % wd.item_name)
		return
	## 不在武器模式：清掉旧快照即可（下次举起会从新武器读起）
	_weapon_data = null
	_current_weapon_char_idx = 0
	_refresh_sprite()


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
	## ★2026-10-03 补齐复位（切人时角色的「举枪/投掷物/推击/固定朝向」必须全部清干净）。
	## 旧实现只把 `_weapon_mode` 置 false 就收工，于是残留两类问题：
	## ① `_current_weapon_char_idx` 仍是**旧角色/旧武器**举起序列的帧索引
	##    → 新角色首次举枪时贴图与帧索引可能错位（用户报「行走图对不上」的同类现象）；
	## ② 若切人前锁了固定朝向，`update_facing()` 的锁定分支继续生效
	##    → 新角色无法转向（用户 10-03 实测「举着武器定向移动时切人就一直保持固定朝向」，
	##      当次没复现但代码上确有窗口：`exit_weapon_mode()` 的解锁在
	##      `CharacterSwitchManager._reset_player_state_machine()` 里才走到，
	##      而投掷物/推击等状态的 exit 路径不覆盖全部组合）。
	## 这里走与 `exit_weapon_mode()` 相同的收敛逻辑（幂等），不依赖状态机 exit 链。
	_current_weapon_char_idx = 0
	_shove_mode = false
	_shove_texture = null
	exit_throwable_mode()
	if _facing_locked:
		_facing_locked = false
		_locked_facing = _facing
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
		## 成就「アンタッチャブル」：本局受过伤即失去无伤资格
		if actual_damage > 0.0:
			ACHIEVEMENTS.on_player_damaged()

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


## 使用治疗品。单机=队伍共用池（2026-09-13）；联机=**只用自己那一格**（每人独立槽位，
## 自己没有就用不了；2026-09-24 用户定稿，取消「自己→其他座位」的借用）。
## 联机 Client **不本地预测**：只提交请求，真实扣减/加血由 Host 权威域结算后经快照回灌
## （2026-09-24 实测：「客户端用喷雾却扣了主机那边的账」根因就是两端各记一本账）。
func use_healing_item() -> bool:
	## ★满血时既不能用、也不扣数量（2026-09-30 用户实测：满血还能用，且数量会减少）。
	## 放在最前面 = 单机 / 联机 Host / 联机 Client 提交前 都被拦下；
	## Host 结算远程请求时在 network_world 里另有同样一道闸门。
	if current_hp >= max_hp:
		return false
	if _submit_network_healing_use():
		return true
	var state: PlayerState = Players.get_state_for_entity(self)
	var used: ItemData = Players.consume_spray_for(state)
	if not used:
		return false
	apply_item_effects(used)
	apply_nursing_passive(used)
	var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
	if chapter_stats and chapter_stats.has_method("record_healing_item") and state:
		chapter_stats.record_healing_item(state.seat_index)
		## 成就「ダメ。ゼッタイ。」：使用治疗品次数
		ACHIEVEMENTS.on_heal_item(state.seat_index)
	return true


## 联机 Client 的喷雾使用提交。返回 true = 已转交 Host（本机不结算）。
## Host 本地与单机一律返回 false，走下面的本地权威结算。
func _submit_network_healing_use() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	if not net or not net.has_method("is_online_session") or not bool(net.is_online_session()):
		return false
	if bool(net.get("is_host")):
		return false
	var tree: SceneTree = get_tree()
	var scene: Node = tree.current_scene if tree else null
	var world: Node = scene.find_child("NetworkWorld", true, false) if scene else null
	if world and world.has_method("request_healing_use"):
		world.call("request_healing_use")
		return true
	return false


## 看护（说明书 §6.2，静香被动）：手动使用治疗品 → 全队同时回复相同 HP。
## 提为独立方法是为了让联机 Host 权威侧（network_world._try_host_use_healing）复用同一规则。
func apply_nursing_passive(used: ItemData) -> void:
	if not used or used.hp_restore <= 0:
		return
	if not (current_character and current_character.nursing):
		return
	for p: Node2D in Players.all_entities():
		if is_instance_valid(p) and p != self and not p.get("_is_dying"):
			p.heal(used.hp_restore)
	print("[被动] 看护：全队各回复 %d HP" % used.hp_restore)


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
	## ★唯一写入口（2026-10-03）：内部钳到 [0, 上限]，避免任何越界污染 HUD。
	state.change_tp(amount)
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


# ═══════════════════════════════════════
# SA / 见切 / 反击 / Heat / 削り / 覚醒 / 搓招
# （2026-10-08 拆分：实现已抽到 script/player_special_action_service.gd；
#  本节只保留同名转发门面，外部调用点零改动）
# ═══════════════════════════════════════

## 被吞锁定标志：true 期间 NetworkWorld 冻结本实体的移动（Host 模拟与 Client
## 本地预测两处闸门都读它），Host 侧由 EnemySwallowState 置位，Client 侧由表现置位。
## 【留在 player】该字段被 NetworkWorld / EnemySwallowState 直接读，不能迁入服务。
var network_swallow_locked: bool = false


## 按搓招触发键释放技能（单机 / Host 本机玩家的输入入口）。
## trigger: 触发键的输入动作名（如 "确定键"/"取消键"），匹配 SkillData.command_trigger
func use_skill(trigger: String = "") -> void:
	_special_action.use_skill(trigger)


## 释放技能核心（联机下 Host 替 Client 玩家结算经此入口）。
func _use_skill_core(trigger: String, motion_ok: bool) -> bool:
	return _special_action._use_skill_core(trigger, motion_ok)


func is_heat_active() -> bool:
	return _special_action.is_heat_active()


func _apply_heat() -> void:
	_special_action._apply_heat()


func try_activate_awaken() -> bool:
	return _special_action.try_activate_awaken()


func is_awaken_active() -> bool:
	return _special_action.is_awaken_active()


func get_awaken_damage_mult() -> float:
	return _special_action.get_awaken_damage_mult()


func deactivate_awaken() -> void:
	_special_action.deactivate_awaken()


func _deactivate_awaken() -> void:
	_special_action.deactivate_awaken()


func _update_awaken(delta: float) -> void:
	_special_action._update_awaken(delta)


func apply_network_awaken_state(active: bool) -> void:
	_special_action.apply_network_awaken_state(active)


func _apply_attrition() -> void:
	_special_action._apply_attrition()


func _update_sa_state(delta: float) -> void:
	_special_action._update_sa_state(delta)


func _should_negate_hit(damage: float) -> bool:
	return _special_action._should_negate_hit(damage)


func _try_mukiri_input() -> void:
	_special_action._try_mukiri_input()


func _try_counter() -> void:
	_special_action._try_counter()


func _update_network_sa_state(delta: float) -> void:
	_special_action._update_network_sa_state(delta)


func apply_network_sa_skill(trigger: String) -> void:
	_special_action.apply_network_sa_skill(trigger)


func apply_network_crouch_end() -> void:
	_special_action.apply_network_crouch_end()


func play_network_counter_presentation() -> void:
	_special_action.play_network_counter_presentation()


func apply_network_heat_state() -> void:
	_special_action.apply_network_heat_state()


func set_network_crouch_hold(active: bool) -> void:
	_special_action.set_network_crouch_hold(active)


func apply_network_swallow_state(active: bool) -> void:
	_special_action.apply_network_swallow_state(active)


func poll_network_motion_input() -> void:
	_special_action.poll_network_motion_input()


func validate_skill_motion(trigger: String) -> bool:
	return _special_action.validate_skill_motion(trigger)


func skip_post_attack(weapon_state_name: String) -> bool:
	return _special_action.skip_post_attack(weapon_state_name)


func _update_motion_input() -> void:
	_special_action._update_motion_input()


func local_skill_tp_cost(trigger: String) -> int:
	return _special_action.local_skill_tp_cost(trigger)


func pay_local_sa_tp(trigger: String) -> void:
	_special_action.pay_local_sa_tp(trigger)


# ═══════════════════════════════════════
# 死亡系统 + 丢弃全部武器
# （2026-10-08 拆分：实现已抽到 script/player_death_service.gd；本节只保留同名转发门面）
# ═══════════════════════════════════════

func _try_switch_on_death() -> bool:
	return _death_service._try_switch_on_death()


func _clean_expired_damage_sources(now: int) -> void:
	_death_service._clean_expired_damage_sources(now)


func _apply_network_death_state() -> void:
	_death_service._apply_network_death_state()


func force_lethal_death(source_id: int = 0) -> void:
	_death_service.force_lethal_death(source_id)


func apply_weapon_attrition(extra: float = 0.0) -> void:
	_death_service.apply_weapon_attrition(extra)


func _die() -> void:
	_death_service._die()


func _create_fade_overlay() -> void:
	_death_service._create_fade_overlay()


func _try_auto_spray_revive() -> bool:
	return _death_service._try_auto_spray_revive()


func _team_spray_total() -> int:
	return _death_service._team_spray_total()


func _process_death(delta: float) -> void:
	_death_service._process_death(delta)


func _reload_from_save() -> void:
	_death_service._reload_from_save()


func _log_team_state(tag: String) -> void:
	_death_service._log_team_state(tag)


## E 键入口：单机本地丢弃；联机交给 Host 权威事务（Client 只提交意图，等快照回包）。
func request_drop_all_weapons() -> void:
	_death_service.request_drop_all_weapons()


## 单机：两个武器槽全部丢到地上（落点自动避让 24px，见 weapon_pickup.find_free_drop_position）。
func _drop_all_weapons_locally() -> void:
	_death_service._drop_all_weapons_locally()


## E 键丢弃武器（保留在节点：_unhandled_input 是引擎回调）。
## 用 _unhandled_input 而不是 _process 轮询：UI（菜单/安全门/拾取提示）会先消费按键，
## 否则开着菜单按 E 也会把武器丢一地。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("丢弃武器键"):
		get_viewport().set_input_as_handled()
		request_drop_all_weapons()


# ═══════════════════════════════════════
# 音效工具
# ═══════════════════════════════════════

func _play_sound(stream: AudioStream) -> void:
	_sfx.play_sound(stream)


## 联机表现专用音效入口（装填/攻击后/推击等）。与单机同一套 SFX 管理器与并发上限，
## 用**调用当刻**的节点自身作宿主：协程里 await 之后缓存的 SceneTree 可能已失效，
## 而本节点只要仍在树内就是合法宿主（2026-09-24 联机装填静音修复一并收口）。
func _play_network_sfx(stream: AudioStream) -> void:
	_sfx.play_network_sfx(stream)


func _play_music(stream: AudioStream) -> void:
	_sfx.play_music(stream)


# ═══════════════════════════════════════
# Debug 可视化（TAB 切换）
# ═══════════════════════════════════════

func _draw() -> void:
	_debug_drawer.draw()


# ═══════════════════════════════════════
# 内部
# ═══════════════════════════════════════

func _refresh_sprite() -> void:
	_sprite_renderer.refresh_sprite()

## 成就系统入口（**preload 常量而不是 class_name**：本项目 class_name 不进全局类缓存，
## 跨文件按名字引用会在 headless / 导出时报 Parse Error —— 见 MEMORY「class_name 不跨文件」）。
const ACHIEVEMENTS := preload("res://script/achievements.gd")
