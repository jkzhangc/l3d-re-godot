extends CharacterBody2D

## ── 架构定位 ──
## 系统：敌人实体 ｜ 层：玩法（CharacterBody2D）
## 联机：Host 权威 / Client 表现
## 职责：敌人实体：属性与外观配置、视野判定、受击/击退/死亡表现、尸体管理与联机表现接口；AI 规则交由 Enemy/*State。
## 依赖：StateMachine、EnemyChaseState、NetworkWorld（联机）


## Host 伤害判定完成后由 NetworkWorld 转发给客户端的纯表现事件。
signal network_damage_applied(damage: float, position: Vector2, is_headshot: bool)

## 死亡信号（2026-09-15）：_die() 是全部死亡路径的唯一入口，在这里发一次。
## 挂点用途：HoldoutMachine 杀怪式（KILL_COUNT）击杀计数等。
signal died(enemy: Node)

## 敵人 — CharacterBody2D + AI 状态机
##
## VX Ace 精灵渲染（与玩家相同逻辑）
##
## 单机或联机 Host 执行目标搜索、寻路、攻击判定、受伤、击退和死亡；Client 只应用
## NetworkWorld 快照并播放受击表现。敌人参数来自场景/白名单，不能由客户端 RPC 提供。
## enemy.gd 管实体生命周期与表现，Enemy/*State.gd 管状态机规则。
# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
const WALK_SEQUENCE: Array[int] = [1, 0, 1, 2]
const STAND_FRAME: int = 1
const DIR_ROWS: Array[int] = [0, 1, 2, 3]
const DAMAGE_SOURCE_COOLDOWN_MSEC: int = 1000  ## 同一伤害源对当前敌人的重复命中冷却（毫秒）

## 帧尺寸覆盖（0 = 用默认 48×64）。
##
## 背景：项目常量帧尺寸是 RM VX Ace 标准 48×64。但部分素材（如 T-002 暴君，
## 单帧 128×144）是放大版精灵表，直接按 48×64 切会错位。VX 规格本身不限定像素
## 尺寸，只要求「每角色格 = 3 帧 × 4 方向」，因此帧宽高由素材反算：
##     frame_w = texture_width  / (CHARS_PER_ROW * 3)
##     frame_h = texture_height / (DIRECTIONS * 2)
## 新增放大版素材时填 0，让 _sync_frame_size_to_texture() 自动推断即可。
@export_group("外观 — 帧尺寸（放大版素材）")
## 单帧宽（px）。0 = 自动按 48。
@export var sprite_frame_w: int = 0
## 单帧高（px）。0 = 自动按 64。
@export var sprite_frame_h: int = 0

@export_group("外观 — 附加动作表（特感）")
## 攻击动作表（独立贴图）。非空时攻击状态自动切到这张表。
## 配合 attack_char_sequence 指定该表内的角色格索引。
@export var attack_texture: Texture2D = null
## 死亡动作表（独立贴图）。非空时死亡状态自动切到这张表。
@export var death_texture: Texture2D = null
## 死亡动画使用的角色格索引（death_texture 内）。-1 = 用 death_char_index 默认值。
@export var death_texture_char_index: int = -1

enum FaceDir { DOWN = 0, LEFT = 1, RIGHT = 2, UP = 3 }

# ═══════════════════════════════════════
# 导出参数
# ═══════════════════════════════════════
@export_group("属性")
@export var max_hp: float = 100.0
@export var move_speed: float = 120.0
@export var attack_damage: float = 10.0
## 攻击属性（WeaponData.Element：0=无 1=炎 2=雷 3=氷 4=酸）。酸命中玩家触发「削り」。
@export var attack_element: int = 0
## Heat 攻击（原作 §4.6，如 Hunter 系"首狩り"）：命中玩家 → Heat 状态
## （禁止见切/反击、TP 停止回复、Guts 停止）+ 削り。
@export var attack_causes_heat: bool = false
@export var attack_range: Vector2 = Vector2(80, 64)  ## 攻击触发矩形（宽×高），跟随朝向旋转，玩家进入则攻击
@export var attack_range_forward_offset: float = 20.0     ## 攻击触发矩形前方偏移
@export var attack_hit_range: Vector2 = Vector2(48, 32)  ## 攻击判定矩形（宽×高）
@export var attack_hit_forward_offset: float = 28.0       ## 攻击判定前方偏移
@export var attack_cooldown_frames: int = 30              ## 攻击后摇帧数（≈0.5秒@60fps）

# ── 步行/跑步双移动模式（暴君・猎杀者，2026-09-13 用户指定）──
## 远距离 = 跑步逼近（切 run_char_index 行 + run_speed），近距离 = 步行。
## 素材索引映射（用户钦定）：T-002 body 表 跑步=索引0/走路=索引1；
## ハンター1 走路=索引0/跑步=索引1。-1 = 无跑步模式（普通丧尸/女巫不注入）。
@export_group("跑步模式（特感）")
@export var run_char_index: int = -1        ## 跑步行走图角色索引（-1 = 禁用）
@export var run_speed: float = 0.0          ## 跑步移速（px/s，0 = 禁用）
@export var run_trigger_distance: float = 0.0  ## 超过该距离切跑步（0 = 默认 320；带回滞）

@export_group("受击碰撞体")
@export var hurtbox_size: Vector2 = Vector2(28, 44)  ## 受击碰撞体尺寸
@export var hurtbox_offset: Vector2 = Vector2(0, -8)  ## 受击碰撞体偏移（相对角色原点）

@export_group("外观")
@export var walk_texture: Texture2D            ## 精灵表
@export var walk_char_index: int = 0           ## 角色索引
## 行走动画帧时长（秒）。0 = 按移动速度自动算（2026-09-15 默认：
## duration = 0.18 × 150 / move_speed，速度越快帧间隔越短，含跑步/狂暴换速）；
## >0 = 手动固定（个别怪微调用）。ZombieVariant 注入 >0 同样视为手动固定。
@export var walk_frame_duration: float = 0.0
@export var initial_facing: int = FaceDir.DOWN

@export_group("视野")
@export var vision_angle: float = 90.0         ## 视野角度（度）
@export var vision_range: float = 200.0        ## 视野距离（像素）

@export_group("初始行为")
## 一登场就进入追击：跳过 Idle 徘徊与 Discover 提示，开场立即锁定最近的存活玩家。
## 特感（Hunter 系 / 女巫）与 Tank 使用 —— 它们不是"路过时才注意到你"的杂兵，
## 而是带着压迫感登场的威胁，不该在玩家面前漫无目的地游荡或先发一个"!"。
## 普通僵尸保持 false（保留"发现玩家"的节奏缓冲与街道巡逻感）。
@export var starts_in_chase: bool = false
## 开场锁定的目标距离上限（px）。0 = 不限距离，直接锁最近的存活玩家。
## 需要"只在玩家接近到某距离才立刻警觉"时填正值。
@export var chase_acquire_range: float = 0.0

## 登场即追击是否已成功锁定目标（成功后退订重试）。
var _chase_acquired: bool = false

@export_group("蹭墙 / 拐角平滑")
## 与玩家同一套像素级蹭墙机制（算法在 script/corner_assist.gd）：某一轴被墙面挡住时，
## 沿另一轴做限速小位移蹭过去。敌人用它解决"卡在门框/墙角上摩擦"的老问题。
@export var corner_assist_enabled: bool = true
## 侧移速度上限（像素/秒）
@export var corner_assist_speed: float = 160.0
## 侧移试探的最大距离（像素）。不要随意调大（见 player.gd 中同名参数的说明）
@export var corner_assist_max_shift: float = 16.0
## 试探步长（像素）。敌人数量多，取 4 以减少 test_move 次数
@export var corner_assist_step: float = 4.0
## 敌人没有玩家入力，侧移方向不做入力优先（固定正向优先）
@export var corner_assist_follow_input: bool = false
## 只把「图块」层（bit 1）算作静态墙面，避免被玩家/其它敌人/掉落物干扰探测
@export var corner_assist_world_mask: int = CornerAssist.WORLD_LAYER_BIT

@export_group("友军伤害")
@export var can_damage_enemies: bool = false       ## 是否可对其他敌人造成伤害（默认关闭）

@export_group("受击反馈")
## 受击反馈模式：0=闪（瞬间变色→逐渐恢复），1=渐隐（变色→渐渐消失）
@export var hit_feedback_mode: int = 0
## 受击反馈持续时间（秒）
@export var hit_feedback_duration: float = 0.5
## 受伤表现偏移（2026-09-15）：伤害数字/受击表现相对角色原点的偏移。
## 大体型敌人（T-002）原点在脚部，配 (0, -60) 一类的值把表现抬到躯干。
@export var hurt_effect_offset: Vector2 = Vector2.ZERO

@export_group("攻击动画")
@export var attack_char_sequence: Array[int] = [1, 2, 3, 1, 0]  ## 攻击动画序列
## 攻击动画每帧持续时间（秒），长度应与 attack_char_sequence 一致
## 为空时使用默认 0.1 秒
@export var attack_frame_durations: Array[float] = []
@export var hit_at_sequence_idx: int = 2       ## 在此序列索引处判定伤害（该帧时长拉长=停顿）

@export_group("死亡")
@export var death_char_index: int = 4          ## 普通死亡角色索引
@export var headshot_char_index_1: int = 5     ## 爆头死亡帧1
@export var headshot_char_index_2: int = 6     ## 爆头死亡帧2（最终保持）

@export_group("回收")
## true = 「离玩家太远就清除」的回收机制会跳过该敌人（用于必须留在原地的事件敌人）。
@export var recycle_exempt: bool = false

# ── 僵尸变体（由 Director 从 ZombieVariant 池注入，不手工编辑）──
## 狂暴形态行走图（クリムゾンヘッド）。null = 该外观没有狂暴形态。
var variant_rage_texture: Texture2D = null
var variant_rage_move_speed: float = 0.0        ## 狂暴移动速度（0 = 沿用当前值不变）
var variant_rage_attack_damage: float = 0.0     ## 狂暴攻击伤害（0 = 沿用当前值不变）
var variant_rage_discover_sound: AudioStream = null  ## 狂暴状态下的发现/吼叫音效
var variant_rage_discover_pitch: float = 1.0         ## 狂暴吼叫音调（ZombieVariant 注入，0/1=原调）
## 狂暴力竭阈值（秒）：狂暴态累计**移动**达到该值 → 力竭倒地（EnemyExhaustedState）。
## 原作说明书（enemy.html クリムゾンヘッド条）：「中身はエキストラ（一般人）であるため
## この状態で１０秒ほど走り回されると倒れてしまう」——逼玩家占位、边打边走的核心谜题。
## 0 = 该变体禁用力竭。
var variant_rage_exhaust_seconds: float = 0.0
var variant_rage_exhaust_down_seconds: float = 3.5  ## 力竭倒地时长（秒），起身时变回普通形态
var _rage: bool = false                         ## 当前是否处于狂暴（クリムゾンヘッド）形态
var _rage_move_accum: float = 0.0               ## 狂暴态累计移动时间（秒）
var _rage_exhaust_target: float = 0.0           ## 本次狂暴的力竭阈值（含 ±抖动，防同批同时倒）
var _exhausted: bool = false                    ## 是否处于力竭倒地
var _base_walk_texture: Texture2D = null        ## 变体注入前的普通行走图（set_rage(false) 恢复用）
## 附加动作表栈（特感攻击/死亡贴图）。空 = 用行走表。
var _action_texture_stack: Array[Texture2D] = []
var _action_texture_prev: Texture2D = null
var _frame_w_prev: int = 0
var _frame_h_prev: int = 0
## 死亡表现是否已切到专用死亡表（death_texture）。防快照路径重复覆盖（见 apply_death_appearance）。
var _death_appearance_applied: bool = false
## ── 每张贴图各自的帧尺寸缓存 ──
##
## 为什么需要它：自动推断（_guess_frame_dim）只在"整表恰好 4 个角色格宽"时可靠，
## T-002 的三张表实际是 **6 列 × 4 行**，推断会得出帧高 72（= 144 的一半）→
## 每个角色都被水平腰斩。而 .tres 里 `sprite_frame_w/h` 只描述**行走表**，
## push_action_texture() 切到攻击/死亡表时会把它们清零重推，于是显式值被丢掉。
## 做法：按贴图记住"首次确定的帧尺寸"，切表时优先复用；
## 行走表则把 .tres 的显式值当作它的缓存，永远不会被推断覆盖。
var _frame_size_by_texture: Dictionary = {}
var _base_move_speed: float = 0.0
var _base_attack_damage: float = 0.0
@export var headshot_pause_frames: int = 20    ## 爆头动画暂停帧数

@export_group("音效")
@export var hurt_sound: AudioStream = null
## 各音效可独立设置音调（2026-09-15）：1.0=原调，>1 变高、<1 变低。
@export var hurt_sound_pitch: float = 1.0
## 击中目标音效（攻击命中玩家且实际掉血时播放；起手挥击音之外的中掌声）。
## 默认 噛む（咬）＋ 音调 1.3（2026-09-15 用户定稿）。
@export var hit_target_sound: AudioStream = preload("res://sound/噛む.ogg")
@export var hit_target_sound_pitch: float = 1.3

## 正面抗性「弹开」音效（2026-09-16 用户反馈补足）：Hunter β 正面完全回避 /
## Tyrant Normalize 生效时播放，配合金色闪白 + 「無効」飘字，让玩家立刻明白
## "这个方向打不进去"（原先只有 0.08s 闪白、无音效，被读作"怪无敌/枪打不到"）。
@export var frontal_block_sound: AudioStream = preload("res://sound/コピー ～ 弾き.ogg")
@export_range(0.0, 4.0, 0.1) var frontal_block_sound_pitch: float = 1.0

# ── 属性抗性表（原作说明书 §4.5/§7：○=有抗性 ×=无抗性；默认全部无抗性=普通丧尸）──
## 酸在原作是"抗性持有者最少"的属性（实际最泛用）。
@export_group("属性抗性")
@export var resist_fire: bool = false       ## 炎抗性：不被点燃
@export var resist_lightning: bool = false  ## 雷抗性：不被感电
@export var resist_ice: bool = false        ## 氷抗性：不被冻结
@export var resist_acid: bool = false       ## 酸抗性：抗性持有者最少（预留）

# ── 属性状态参数（原作数值无公开精确值，按体感设定，Inspector 不可调）──
const BURN_TIME: float = 4.0            ## 燃烧持续时间（秒）
const BURN_DPS: float = 8.0             ## 燃烧每秒掉血（燃烧中仍会攻击，非即效性）
const ELECTRO_TIME: float = 3.0         ## 感电持续时间（攻击不能，直到解除）
const FREEZE_TIME: float = 2.5          ## 冻结持续时间
const FROZEN_DMG_MULT: float = 1.5      ## 原作：冻结中受 1.5 倍伤害（"一击粉碎"的数值化）

# ── 正面抗性（特感专用：Hunter β 正面枪击回避 / Tyrant Normalize）──
## 设计（2026-09-12，对齐设计总纲 §3.1）：
##   · Hunter β：`frontal_damage_mult = 0.0` + `frontal_arc_degrees = 120`
##     → 正面 120° 扇区内的枪击完全无伤，逼玩家绕背或改用格斗武器；
##   · Tyrant：`frontal_damage_mult` 用较小值（如 0.4）实现"Normalize"式硬抗，
##     单发高伤被削得更多（见 _apply_frontal_resist 的 normalize 选项）。
## 判定基于"伤害来源方向 vs 敌人当前朝向"，由 take_damage 的 direction 参数推导，
## 因此对子弹/近战/投掷全部一致，且 Host 权威下天然同步（Client 只跑表现）。
@export_group("正面抗性（特感）")
## 正面扇区内受到的伤害倍率：1.0 = 无减免（默认）；0.0 = 完全回避。
@export var frontal_damage_mult: float = 1.0
## 正面扇区半角（度）：60 = 以朝向为中心的 ±60°（合计 120°）算作"正面"。
@export var frontal_arc_degrees: float = 60.0
## Normalize 模式（Tyrant）：开启后正面伤害改为"减免固定值"而非按倍率缩放 ——
## 单发伤害越高削得越多（对齐原作"单发伤害越高削越多 → 平衡连射 vs 单发"）。
@export var frontal_normalize: bool = false
## Normalize 减免系数：实际伤害 = max(0, 伤害 - 伤害 * 本值)。
## 例如 0.6 → 100 伤只吃 40，10 伤只吃 4（高伤被削得更狠）。
@export var frontal_normalize_ratio: float = 0.6

# ── 属性状态运行时 ──
## 本次命中是否被正面抗性完全回避（供 take_damage 跳过"推击"分支的误打印/二次闪白，
## 但保留受击转向、Idle→Discover 等既有副作用）。2026-09-16。
var _front_blocked_this_hit: bool = false
var _burning_time: float = 0.0
var _burn_tick: float = 0.0
var _frozen_time: float = 0.0
var _electro_time: float = 0.0
@export var death_sound: AudioStream = null
## 爆头相关默认音效（2026-09-17 用户指定）：命中=首粉々、倒地=首ゴロ。tres 可逐敌覆盖。
@export var headshot_sound: AudioStream = preload("res://sound/首粉々.ogg")
@export var headshot_fall_sound: AudioStream = preload("res://sound/首ゴロ.ogg")
@export var attack_sound: AudioStream = null
@export var discover_sound: AudioStream = null
## 对应音效的音调（每音效独立；1.0=原调）
@export var death_sound_pitch: float = 1.0
@export var headshot_sound_pitch: float = 1.0
@export var headshot_fall_sound_pitch: float = 1.0
@export var attack_sound_pitch: float = 1.0
@export var discover_sound_pitch: float = 1.0

@export_group("首狩り突进（ハンター 系）")
## 首狩り（クビカリ）突进总开关。仅ハンター 系特感开启；普通僵尸保持 false。
@export var pounce_enabled: bool = false
## 触发首狩り的最小距离（px）：比这更近就直接走普通 Attack（近距离不必起跳）。
@export var pounce_trigger_min_dist: float = 110.0
## 触发首狩り的最大距离（px）：比这更远够不着，继续正常追击。
@export var pounce_trigger_max_dist: float = 340.0
## 蓄力（预备）时长（秒）：给玩家反应窗口，避免"无预警瞬移"。
@export var pounce_windup_seconds: float = 0.28
## 冲刺持续时长（秒）。
@export var pounce_dash_seconds: float = 0.42
## 冲刺速度倍率（相对 move_speed）。1.8 ≈ 冲刺感明显但仍可被预判。
@export var pounce_speed_mult: float = 1.8
## 突进绝对速度（2026-09-15）：>0 时直接用作冲刺速度，忽略 move_speed×pounce_speed_mult。
## 猎杀者系 move_speed 低、乘系数难调时用这个定值（ハンター=400）。
@export var pounce_dash_speed: float = 0.0
## 命中半径（px）：突进途中与玩家距离小于此值即判定命中。
@export var pounce_hit_radius: float = 42.0
## 吸附转向速率（0~1）：冲刺途中 _dash_dir 朝玩家的插值系数。
## 位移通常小于触发带宽，纯直线必然扑空，故默认开启吸附（0.08 偏"有惯性"）。
## 设 0 则退回纯直线突进（需要把触发带收窄到位移可达范围）。
@export var pounce_homing_turn_rate: float = 0.08
## 冲刺末帧命中宽容倍率：终点时距离 ≤ hit_radius × 此值即视作接触命中。
## 兜底防止「差几像素就空扑」，1.6 表示允许 42×1.6≈67px。
@export var pounce_hit_tolerance: float = 1.6
## 命中伤害倍率（相对 attack_damage）。
@export var pounce_damage_mult: float = 1.2
## 命中击退力度。
@export var pounce_knockback_force: float = 180.0
## 起跳音效。留空则用 attack_sound。
@export var pounce_sound: AudioStream = null
@export var pounce_sound_pitch: float = 1.0
## 首狩り冷却（秒）：两次首狩り之间的最短间隔，防止连续扑咬把玩家按死。
@export var pounce_cooldown_seconds: float = 2.5
## 冲刺期间锁定突刺帧：true = 整个 DASH 保持攻击序列第 1 帧（ハンターγ 的突刺姿势）。
## 原作「直到突刺移动结束之前，一直保持1」。默认 false 保持既有ハンター 的进度式推进。
@export var pounce_hold_frame_during_dash: bool = false

# ── 首狩り运行时 ──
var _pounce_cooldown_left: float = 0.0

@export_group("远程吐酸（ブレインディモス）")
## 远程吐酸总开关（全工程首个敌人远程攻击）。由 Director 从 SpecialEnemyData 注入。
## 原作依据（enemy.html ブレインディモス条）：「遠距離から酸をはきかけてくる」
## 「この酸には削り効果があり、連続で食らうと武器があっという間にダメにされてしまう」。
@export var spit_enabled: bool = false
## 是否启用近战攻击（玩家进攻击矩形时切 Attack）。false = 纯远程（贴脸也只吐酸）。
@export var melee_enabled: bool = true
## 吐酸触发距离带（px）：更近走普通近战 Attack（melee_enabled 时），更远继续追击。
@export var spit_trigger_min_dist: float = 0.0
@export var spit_trigger_max_dist: float = 400.0
## 吐酸冷却（秒）：从后摇结束后起算（与首狩り同规则）。
@export var spit_cooldown_seconds: float = 1.8
## 蓄力（后仰）时长（秒）。
@export var spit_windup_seconds: float = 0.35
## 吐酸后摇（秒）。
@export var spit_recover_seconds: float = 0.6
## 酸弹飞行速度（px/s）。2026-09-17 用户：加快 → 450。
@export var spit_projectile_speed: float = 450.0
## 酸弹伤害（削り由 element=4 命中自动触发，不走此数值）。
@export var spit_damage: float = 8.0
## 吐酸动画角色格序列（空 = 沿用 attack_char_sequence）。
@export var spit_char_sequence: Array[int] = []
## 在此序列索引处发射酸弹（0 起始；别配 0 —— 帧步进后检查的永假边界）。
@export var spit_fire_at_sequence_idx: int = 1
## 吐酸音效（酸弹场景自播着弾音；此处是发射音）。
@export var spit_sound: AudioStream = null
@export var spit_sound_pitch: float = 1.0
## 酸弹命中/落地特效（VXAnimSprite 场景）与染色。由 Director 从 SpecialEnemyData 注入；
## 空 = 不播特效（命中玩家与撞墙/落地共用）。
@export var spit_impact_effect: PackedScene = null
@export var spit_impact_tone: Color = Color(1, 1, 1, 1)
## 吐酸场景（酸弹投射物）。留空 = 由 EnemySpitState 用内置默认。
@export var spit_projectile_scene: PackedScene = null

# ── 吐酸运行时 ──
var _spit_cooldown_left: float = 0.0

@export_group("即死耐性")
## 集中射撃（覚醒）即死弹免疫：true = 走 Boss 同款结算（伤害 ×1.5 + 0.8s 怯み，不死）。
## 原作 enemy.html ブレインディモス条：即死 ×。由 Director 从 SpecialEnemyData 注入。
@export var instant_kill_immune: bool = false

@export_group("女巫徘徊（ブレアウィッチ）")
## 女巫模式总开关。开启后初始状态为 WitchIdle（徘徊，不主动接近/攻击），
## 被刺激后激怒追杀。仅女巫特感开启。
@export var witch_enabled: bool = false
## 徘徊移速（px/s）。女巫平时"うずくまって泣いている"，移动应极慢。
@export var witch_wander_speed: float = 18.0
## 刺激半径（px）：玩家进入此范围开始累积刺激值。范围外不累积。
@export var witch_stim_radius: float = 160.0
## 刺激累积速度基准：越近越快（rate = radius / dist）；此值再乘上去。
@export var witch_stim_speed: float = 1.0
## 激怒后的移速倍率（相对 base 移速）。
@export var witch_enrage_speed_mult: float = 2.2
## 激怒尖叫音效。留空则用 discover_sound。
@export var witch_scream_sound: AudioStream = null
@export var witch_scream_sound_pitch: float = 1.0

## 女巫是否已被激怒（激怒不可逆）。由 EnemyWitchIdleState 置位。
var witch_enraged: bool = false

@export_group("丸呑み（ハンターγ）")
## 丸呑み（零距离必杀）总开关。仅ハンターγ 开启：玩家贴脸时吞入 → 咀嚼 → 吐出即死。
@export var swallow_enabled: bool = false
## 触发距离（px）：玩家在此距离内才可能被丸呑み（原作「零距離で」）。
@export var swallow_trigger_range: float = 52.0
## 触发概率（0~1）：满足距离时的单次判定成功率，避免贴脸必被吞。
@export var swallow_chance: float = 0.45
## 咀嚼循环次数（2→3 循环次数）。原作「多次后回到 1」。
@export var swallow_chew_cycles: int = 3
## 单轮咀嚼时长（秒）。
@export var swallow_chew_interval: float = 0.28
## 吐出后恢复待机的停顿（秒）。原作「过一会回到 0」。
@export var swallow_recover_seconds: float = 0.9
## 丸呑み动作表（独立贴图）。空 = 复用 texture。
@export var swallow_texture: Texture2D = null
## 丸呑み动画角色索引序列：[0]=准备, [1]=吞入判定, [2]=咀嚼A, [3]=咀嚼B。
@export var swallow_char_sequence: Array[int] = [0, 1, 2, 3]
## 丸呑み是否无视ガッツ直接致死（原作：伤害是致死）。
@export var swallow_is_lethal: bool = true
## 丸呑み的多段削り总量（武器弹药/耐久削减）。
@export var swallow_weapon_attrition: float = 0.0

## 丸呑み冷却（秒）：避免连续触发把玩家锁死。
@export var swallow_cooldown_seconds: float = 6.0
## 丸呑み冷却剩余。由 EnemySwallowState 在收尾时置位。
var _swallow_cooldown_left: float = 0.0

@export_group("动画特效")
## 攻击命中时的特效场景，拖入 anim/ 目录下的 .tscn 文件
@export var attack_effect_anim: PackedScene = null
## 攻击特效是否跟随玩家实体移动（开启后特效每帧跟随玩家位置）
@export var attack_effect_follow: bool = false
## 攻击特效位置偏移覆盖（非零时替换 .tscn 内置的 position_offset）
@export var attack_effect_offset_override: Vector2 = Vector2.ZERO

# ═══════════════════════════════════════
# 运行时状态
# ═══════════════════════════════════════
var current_hp: float = 100.0
var _facing: int = FaceDir.DOWN
var _anim_step: int = 0
var _moving: bool = false
var _player_ref: CharacterBody2D = null       ## 发现的玩家引用
var _player_in_sight: bool = false
var _is_dead: bool = false                     ## 是否已死亡
var _knockback_dir: Vector2 = Vector2.ZERO     ## 击退方向（由 take_damage 设置）
var _knockback_force: float = 0.0              ## 击退力度
var _knockback_stun: float = 0.0               ## 击退硬直时长
var _hitstun_duration: float = 0.0             ## 命中硬直时长（无击退位移）
var _recent_damage_sources: Dictionary = {}    ## source_id → hit_time_msec（防同一源头重复判定）

## ── 防守战目标锁定（由 HoldoutMachine → EventManager 注入）──
## 锁定期间敌人无视视野扇形与距离，直扑指定玩家；目标倒下后自动改锁其他存活玩家。
## 防守战结束调用 release_forced_target() 即恢复普通 AI（视野发现 → 追击）。
var _forced_target: CharacterBody2D = null
var _forced_target_locked: bool = false

## 联机表现层：Host 保持 AI 与伤害权威；Client 只接收并渲染快照。
var network_entity_id: int = 0
var network_presentation_only: bool = false
## Host 侧：spawn_special_enemy 注入的特感数据引用（联机 spawn 快照据此反查
## NetworkWorld.NETWORK_SPECIALS 白名单 id 下发）。Client 重建节点不走本字段 ——
## 由 network_world 按 special_id 拿到同一份 tres 后调 apply_to_enemy 注入。
var special_data: SpecialEnemyData = null
var _network_target_position: Vector2 = Vector2.ZERO
var _network_has_target: bool = false
var _network_headshot_death: bool = false
var _current_char_index: int = 0
## 远端敌人位置插值：快照样本按固定延迟渲染，取代旧的指数平滑
## （旧的每帧 lerp 会让远端实体起停带"摩擦力"观感）。
const NETWORK_SNAPSHOT_INTERP := preload("res://script/network_snapshot_interp.gd")
## 敌人快照跟随 40Hz 的 player_snapshot 到达，延迟取约 2.5 个快照间隔。
const NETWORK_RENDER_DELAY := 0.06
var _remote_interp: Variant = null

# ═══════════════════════════════════════
# A* 调试字段（由 EnemyChaseState 写入，_draw() 读取）
# ═══════════════════════════════════════
var _debug_path: Array = []
var _debug_path_found: bool = false
var _debug_start_grid: Vector2i = Vector2i.ZERO
var _debug_end_grid: Vector2i = Vector2i.ZERO
var _debug_start_walkable: bool = false
var _debug_end_walkable: bool = false
var _debug_astar_iters: int = 0
var _debug_walk_cache: Dictionary = {}
var _debug_path_idx: int = 0
var _debug_cell_size: float = 32.0  ## 由 EnemyChaseState 在 enter() 中设置

# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════
@onready var sprite: Sprite2D = $Sprite2D
@onready var animation_timer: Timer = $AnimationTimer
@onready var vision_area: Area2D = $VisionArea
@onready var discover_label: Label = $DiscoverLabel
@onready var hurt_area: Area2D = _setup_hurt_area()


func _ready() -> void:
	## 难度缩放（2026-09-16 用户反馈「不管哪个难度丧尸血量都一样」）：
	## 此前 Global.difficulty_multipliers 的 enemy_hp 全仓零消费 → 敌人血量与难度完全无关。
	## 只在 Host / 单机应用 —— Client 的 HP 由 Host 快照驱动，两端各乘会算出不同血量。
	## 必须赶在 current_hp = max_hp 之前，否则第一条命仍是未缩放的旧值。
	if not network_presentation_only:
		max_hp *= Global.difficulty_enemy_hp()
	current_hp = max_hp
	_facing = initial_facing
	_remote_interp = NETWORK_SNAPSHOT_INTERP.new(NETWORK_RENDER_DELAY)
	# 俯视角：浮动模式，所有碰撞都是墙壁
	motion_mode = MOTION_MODE_FLOATING
	# 敌人之间正常碰撞（move_and_collide 滑墙会自然推开）
	_update_facing_sprite()

	# 加入敌人组（用于友军伤害等场景查找）
	_base_walk_texture = walk_texture
	_base_move_speed = move_speed
	_base_attack_damage = attack_damage
	add_to_group("enemy")

	# 放大版素材（帧尺寸非 48×64）自动推断帧宽高，避免硬编码常量切错。
	_sync_frame_size_to_texture()

	# 登记行走表的帧尺寸。此后切到攻击/死亡表再切回来，直接复用这份值，
	# 不再走推断（推断对 6 列布局的表会算错）。
	_frame_w_prev = sprite_frame_w
	_frame_h_prev = sprite_frame_h
	if walk_texture != null and sprite_frame_w > 0 and sprite_frame_h > 0:
		_frame_size_by_texture[walk_texture] = Vector2i(sprite_frame_w, sprite_frame_h)

	if animation_timer:
		animation_timer.wait_time = _current_anim_frame_duration()
		animation_timer.timeout.connect(_on_animation_timer_timeout)
		animation_timer.start()

	if discover_label:
		discover_label.hide()

	_refresh_sprite()
	if network_presentation_only:
		_disable_network_simulation()

	# ── 女巫：初始进徘徊态（不主动接近/攻击）──
	# 状态机的 initial_state 在 .tscn 里硬编码为 Idle，各特感不宜各自改内核；
	# 这里在就绪后按参数切换，保持"新增敌种=加配置"的约定。
	# ⚠ 必须 call_deferred：子节点 StateMachine 的 _ready 在本节点之后才跑，
	#   此刻 states 字典仍为空，直接调用会被 _on_transition_requested 静默丢弃。
	#
	# 女巫与"登场即追击"语义相反（她是被激怒才追），故 witch_enabled 优先：
	# 即使 tres 里 starts_in_chase 忘了关，女巫也不会开场直冲玩家。
	if witch_enabled and not network_presentation_only:
		_enter_witch_idle_deferred.call_deferred()
	elif should_start_in_chase():
		_enter_chase_deferred.call_deferred()


## 「登场即追击」的唯一判据 —— _ready 的初始分支与 _process 的补锁重试**必须共用本函数**，
## 否则两条路径会各自漂移（曾出过：_ready 分支被 witch_enabled 挡住，但 _process
## 重试没挡，导致女巫每帧被强推进 Chase）。
func should_start_in_chase() -> bool:
	if network_presentation_only:
		return false
	if not starts_in_chase:
		return false
	# 女巫是"被激怒才追"，与"登场即追"语义相反 —— 她永远不走本路径。
	# 这条不能只是"数据里记得填 false"，必须是代码级硬约束。
	return not witch_enabled


## 一登场就追击：跳过 Idle 徘徊与 Discover，开场直接锁定最近的存活玩家并进 Chase。
##
## 与女巫分支互斥（`elif`）：女巫是"被激怒才追"，特感/Tank 是"登场即追"，
## 两者语义相反，同时开会自相矛盾（女巫被激怒后本来就会转 Chase）。
func _enter_chase_deferred() -> void:
	if not is_instance_valid(self) or _is_dead:
		return
	if _try_enter_chase_now():
		_chase_acquired = true


## 尝试锁定目标并切 Chase。成功返回 true（此时 _chase_acquired 应被置位，停止重试）。
func _try_enter_chase_now() -> bool:
	var sm: Node = get_node_or_null("StateMachine")
	if sm == null or not sm.has_method("_on_transition_requested"):
		return false
	if not sm.get("states").has("Chase"):
		return false
	# 锁最近的存活玩家（_is_player_body 会剔除倒地/死亡玩家，不会锁尸体）
	var target: Node2D = _find_player_in_scene()
	if not is_instance_valid(target) or not _is_player_body(target):
		# 场上还没有可追目标（例如玩家尚未生成 / 已全灭）→ 保持 Idle，
		# 之后 Idle 的视野轮询会在玩家出现时自然接管。
		return false
	if chase_acquire_range > 0.0 \
			and target.global_position.distance_to(global_position) > chase_acquire_range:
		return false
	_player_ref = target
	_player_in_sight = true
	# 登场即面朝玩家，避免"背对着敌人冲过来"的滑稽表现
	update_facing_from_direction(target.global_position - global_position)
	sm._on_transition_requested("Chase")
	return true


func _enter_witch_idle_deferred() -> void:
	if not is_instance_valid(self) or _is_dead:
		return
	var sm_w: Node = get_node_or_null("StateMachine")
	if sm_w and sm_w.has_method("_on_transition_requested") \
			and sm_w.get("states").has("WitchIdle"):
		sm_w._on_transition_requested("WitchIdle")


# ═══════════════════════════════════════
# 蹭墙 / 拐角平滑（与玩家共用 script/corner_assist.gd）
# ═══════════════════════════════════════

## 带蹭墙辅助的移动入口 —— 使用 `move_and_slide()` 的敌人状态应改调本方法。
func move_with_corner_assist() -> void:
	CornerAssist.move_with_assist(self, velocity,
		corner_assist_enabled, corner_assist_speed, corner_assist_max_shift,
		corner_assist_step, corner_assist_follow_input, corner_assist_world_mask)


## 蹭墙修正的"手动版"：供 EnemyChaseState 这类自己用 `move_and_collide()` 走位、
## 不走 `move_and_slide()` 的代码路径复用。返回本帧实际施加的侧移向量（ZERO = 未修正）。
##
## `move_dir` 是期望前进方向，`motion` 是本帧应有的位移量（用于判断哪一轴被挡）。
func apply_corner_nudge(move_dir: Vector2, motion: Vector2) -> Vector2:
	if not corner_assist_enabled or move_dir.is_zero_approx():
		return Vector2.ZERO
	var nudge: Vector2 = CornerAssist.nudge_for(self, move_dir, motion,
		corner_assist_max_shift, corner_assist_step,
		corner_assist_follow_input, corner_assist_world_mask)
	if nudge == Vector2.ZERO:
		return Vector2.ZERO
	var max_step: float = maxf(corner_assist_speed, 0.0) * get_physics_process_delta_time()
	var applied: Vector2 = nudge.normalized() * minf(nudge.length(), max_step)
	global_position += applied
	return applied


func _process(delta: float) -> void:
	# 行走动画帧时长随移动速度换算（2026-09-15）：每帧刷新 wait_time，
	# 覆盖步行/跑步/狂暴所有换速点；动作表激活期 timer 已停，此处只改数值无副作用。
	if animation_timer:
		animation_timer.wait_time = _current_anim_frame_duration()
	if network_presentation_only:
		if _network_has_target:
			# 远端实体：按固定延迟在两个快照样本间插值，起停干脆、匀速贴合。
			var render_position: Variant = _remote_interp.sample_render_position()
			if render_position != null:
				global_position = render_position
		# 步行/跑步模式：Client 无 AI，按同一距离规则本地推导（零网络改动）
		_update_run_mode()
		if Global.debug_visuals:
			queue_redraw()
		return
	if Global.debug_visuals:
		queue_redraw()

	# 属性状态（炎/雷/氷）更新：燃烧掉血、感电/冻结计时与褪色
	_update_element_status(delta)

	# 狂暴力竭计时（クリムゾンヘッド）：只累计「实际在跑」的时间 —— 被玩家放风筝
	# 才会累，站着围殴不算。达到阈值切 Exhausted（倒地）。
	if _rage and not _exhausted and _rage_exhaust_target > 0.0 and _moving:
		_rage_move_accum += delta
		if _rage_move_accum >= _rage_exhaust_target:
			_enter_exhausted()

	# 防守战锁定维持：目标倒下则改锁、被视野轮询抢走则夺回（未锁定时是空操作）
	_maintain_forced_target()

	# 登场即追击的补锁：特感/Tank 若因"生成时玩家尚未就绪/超出 acquire_range"
	# 而没能在 _ready 里进 Chase，这里持续重试，直到拿到目标为止。
	if should_start_in_chase() and not _chase_acquired:
		if _try_enter_chase_now():
			_chase_acquired = true

	# 步行/跑步双移动模式（暴君・猎杀者）：按与目标的距离切速与行走图行
	_update_run_mode()

	# 首狩り冷却（ハンター 系）：两次突进之间的最短间隔
	if _pounce_cooldown_left > 0.0:
		_pounce_cooldown_left = maxf(0.0, _pounce_cooldown_left - delta)

	# 吐酸冷却（ブレインディモス）：两次吐酸之间的最短间隔
	if _spit_cooldown_left > 0.0:
		_spit_cooldown_left = maxf(0.0, _spit_cooldown_left - delta)

	# 丸呑み冷却（ハンターγ）：两次零距离必杀之间的最短间隔
	if _swallow_cooldown_left > 0.0:
		_swallow_cooldown_left = maxf(0.0, _swallow_cooldown_left - delta)


# ═══════════════════════════════════════
# 联机表现接口（由 NetworkWorld 调用）
# ═══════════════════════════════════════

## Host 侧：特感白名单 id（非特感返回空串，快照不带该字段）。
func get_network_special_id() -> String:
	return String(special_data.id) if special_data != null else ""


## entity_id 为 Host 分配的稳定实体 ID。presentation_only=true 时关闭本地 AI/判定。
func configure_network_entity(entity_id: int, presentation_only: bool) -> void:
	network_entity_id = entity_id
	network_presentation_only = presentation_only
	velocity = Vector2.ZERO
	if network_presentation_only and is_node_ready():
		_disable_network_simulation()


## Client 专用：应用 Host 快照；位置在 _process 中平滑，攻击/死亡帧由 Host 当前角色索引驱动。
func apply_network_presentation(new_position: Vector2, new_facing: int, moving: bool, hp: float, visual_char_index: int, is_dead: bool, is_headshot: bool, snap: bool = false, element_state: int = -1) -> void:
	if not network_presentation_only:
		return
	var previous_hp := current_hp
	current_hp = clampf(hp, 0.0, max_hp)
	if not snap and not _is_dead and current_hp < previous_hp:
		var damage := previous_hp - current_hp
		_play_hit_feedback(Color.RED)
		var tree := get_tree()
		if tree and tree.current_scene:
			DamageNumber.spawn(global_position + hurt_effect_offset, damage, tree.current_scene)
		_play_sound(hurt_sound, hurt_sound_pitch)
	_facing = clampi(new_facing, FaceDir.DOWN, FaceDir.UP)
	_network_headshot_death = is_headshot
	if snap:
		_remote_interp.reset(new_position)
		global_position = new_position
		_network_target_position = new_position
		_network_has_target = false
	else:
		if not _network_has_target:
			global_position = new_position
		_remote_interp.push_sample(new_position)
		_network_target_position = new_position
		_network_has_target = true

	if is_dead:
		_is_dead = true
		_moving = false
		_disable_network_simulation()
		# 已切过死亡表的不动；未切的（晚加入 Client 只拿到快照）补一次死亡表现。
		if not _death_appearance_applied:
			apply_death_appearance(is_headshot)
			if death_texture == null:
				_refresh_sprite_with_index(visual_char_index if visual_char_index >= 0 else (headshot_char_index_2 if is_headshot else death_char_index))
		return

	_is_dead = false
	update_moving(moving)
	if visual_char_index >= 0 and visual_char_index != walk_char_index:
		_refresh_sprite_with_index(visual_char_index)
	# P0-B3 元素染色（炎/雷/氷）随快照同步；-1 = 本包未携带，保持现状。
	if element_state >= 0:
		apply_network_element_tint(element_state)


## Host 侧：把当前元素状态压成 3bit 整数随敌人快照下发（bit0=炎 bit1=氷 bit2=雷）。
func get_network_element_state() -> int:
	var state: int = 0
	if _burning_time > 0.0:
		state |= 1
	if _frozen_time > 0.0:
		state |= 2
	if _electro_time > 0.0:
		state |= 4
	return state


## Client 专用：按快照字节设置元素染色（与 _apply_element_tint 同一配色与优先级：
## 氷 > 雷 > 炎）。Client 不跑 _update_element_status，染色完全由快照驱动，
## 状态结束 Host 发 state=0 还原白色。
func apply_network_element_tint(state: int) -> void:
	if not sprite:
		return
	if state & 2:
		sprite.modulate = Color(0.6, 0.85, 2.0)       # 氷=青蓝
	elif state & 4:
		sprite.modulate = Color(2.0, 2.0, 0.7)        # 雷=黄白
	elif state & 1:
		sprite.modulate = Color(1.8, 0.9, 0.55)       # 炎=橙红
	else:
		sprite.modulate = Color.WHITE


## Client 专用：立即应用 Host 可靠广播的死亡表现。
## 高频紧凑快照会跳过尸体（死物位置不再变化），死亡若只靠快照传递，
## Client 要等 2 秒一次的可靠世界重同步才能看到尸体 —— 期间丧尸会保持
## 最后一次快照的移动状态原地踏步。爆头死亡按 Host 相同节奏播放两帧倒地。
func apply_network_death(is_headshot: bool) -> void:
	if not network_presentation_only or _is_dead:
		return
	_is_dead = true
	_network_headshot_death = is_headshot
	_moving = false
	_disable_network_simulation()
	# 尸体不再消费位置样本；留在当前位置，避免向 Host 死亡坐标跳帧。
	_network_has_target = false
	_remote_interp.reset(global_position)
	# Client 不走 _register_corpse()（尸体表是 Host 侧的），所以贴地要在这里单独接一次，
	# 否则联机时尸体留在 DecorLayer 按 y 排序，会盖住玩家 —— 用户报的"有时候在玩家上方"。
	_lay_corpse_on_ground()
	# 尸体 3 秒渐隐同理：Client 也走 _register_corpse()，这里必须单独启动一次，
	# 否则联机下只有 Host 侧的尸体会消失，Client 留下一具永久站立不动的"活尸"。
	_start_corpse_lifecycle()
	if is_headshot:
		_play_sound(headshot_sound, headshot_sound_pitch)
		if death_texture != null:
			# 特感：headshot_char_index_1/2 是行走表索引，不适用 → 直接死亡表终帧。
			apply_death_appearance(true)
		else:
			_refresh_sprite_with_index(headshot_char_index_1)
			_schedule_network_headshot_fall()
	else:
		_play_sound(death_sound, death_sound_pitch)
		apply_death_appearance(false)


func _schedule_network_headshot_fall() -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	if not tree:
		return
	# Host 的爆头暂停按 headshot_pause_frames 帧计；Client 以 60fps 折算等待后切最终帧。
	await tree.create_timer(headshot_pause_frames / 60.0).timeout
	if is_inside_tree() and _is_dead:
		_refresh_sprite_with_index(headshot_char_index_2)
		_play_sound(headshot_fall_sound, headshot_fall_sound_pitch)


func get_network_facing() -> int:
	return _facing


func is_moving_for_network() -> bool:
	return _moving


func get_network_ai_state() -> String:
	if _is_dead:
		return "HeadshotDeath" if _network_headshot_death else "Death"
	var sm: Node = get_node_or_null("StateMachine")
	return sm.current_state.name if sm and sm.current_state else ""


func get_network_visual_char_index() -> int:
	return _current_char_index


func is_network_dead() -> bool:
	return _is_dead


func is_network_headshot_dead() -> bool:
	return _network_headshot_death


## 在状态机读取目标前验证实例仍存活且仍是有效目标，处理断线/切图时
## queue_free 的延迟释放边界。
## 【存活校验】目标玩家倒地/死亡（HP=0、躺地）后 _player_ref 仍指向它；
## 不在这里复核的话丧尸会继续追着尸体走、对着尸体空挥攻击动画。
## 校验失败时立即清空目标 —— Chase/Attack 随之回 Idle，Idle 的视野轮询
## 会自动改找附近仍在视野内的存活玩家；一个都没有就保持 Idle 待机。
func has_valid_player_target() -> bool:
	if is_instance_valid(_player_ref):
		if _is_player_body(_player_ref):
			return true
		_player_ref = null
		_player_in_sight = false
	velocity = Vector2.ZERO
	return false


## Host 专用：断线玩家释放前清除追击目标，避免状态机读取已释放节点。
func clear_target_if_matches(target: Node) -> void:
	if _player_ref != target:
		return
	_player_ref = null
	_player_in_sight = false
	velocity = Vector2.ZERO
	if _is_dead:
		return
	var sm: Node = get_node_or_null("StateMachine")
	if sm and sm.get_node_or_null("Idle"):
		sm._on_transition_requested("Idle")


func _disable_network_simulation() -> void:
	velocity = Vector2.ZERO
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", true)
	if vision_area:
		vision_area.set_deferred("monitoring", false)
		vision_area.set_deferred("monitorable", false)
	if hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)
	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		sm.process_mode = Node.PROCESS_MODE_DISABLED
	if discover_label:
		discover_label.hide()


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


func guard_dead() -> bool:
	# 检查是否已死亡（HP<=0），如果未标记死亡则触发死亡流程
	# 返回 true 表示敌人已死亡，调用者应立即 return
	if _is_dead:
		return true
	if current_hp <= 0.0:
		_die(false)
		return true
	return false


func _on_animation_timer_timeout() -> void:
	if _moving:
		_anim_step = (_anim_step + 1) % WALK_SEQUENCE.size()
	_refresh_sprite()


# ═══════════════════════════════════════
# 外观
# ═══════════════════════════════════════

func update_facing_from_direction(move_dir: Vector2) -> void:
	if move_dir == Vector2.ZERO:
		return
	var new_facing: int
	if abs(move_dir.x) > abs(move_dir.y):
		new_facing = FaceDir.RIGHT if move_dir.x > 0 else FaceDir.LEFT
	else:
		new_facing = FaceDir.DOWN if move_dir.y > 0 else FaceDir.UP
	if new_facing != _facing:
		_facing = new_facing
		_refresh_sprite()


func set_facing(f: int) -> void:
	_facing = f
	_update_facing_sprite()


func _update_facing_sprite() -> void:
	_refresh_sprite()


func update_moving(moving: bool) -> void:
	_moving = moving
	if not moving:
		_anim_step = 0
	## 动作表激活期（攻击/突进）不重绘——帧归状态机管。否则攻击后摇的 update_moving(false)
	## 会按当前 walk_char_index（跑步形态=0）在攻击表上重画一帧站立（2026-09-15 用户反馈：
	## 后摇角色索引从 3 变 0），与 _apply_run_mode 的动作表保护同规则。
	if not has_action_texture():
		_refresh_sprite()


## 敌人对玩家的最终攻击伤害 = attack_damage × 难度 enemy_damage 倍率（2026-09-16 用户反馈
## 「不管哪个难度攻击伤害都一样」—— 此前该倍率只被玩家**自己**的灼烧 DoT 消费过一处）。
## 普通攻击与首狩り都走这个入口，别再直接读 attack_damage。
## Client 侧不缩放：伤害由 Host 权威结算，两端各乘会造成数值分歧。
func get_final_attack_damage() -> float:
	if network_presentation_only:
		return attack_damage
	return attack_damage * Global.difficulty_enemy_damage()


## 酸弹最终伤害 = spit_damage × 难度 enemy_damage 倍率（与 get_final_attack_damage 同规则：
## Host/单机缩放，Client 不缩放，避免两端数值分歧）。
func get_spit_damage() -> float:
	if network_presentation_only:
		return spit_damage
	return spit_damage * Global.difficulty_enemy_damage()


## 近战/突进/吐酸等敌人攻击的 source_id：实例 ID + 递增序列。
## （2026-09-17 女巫"隔下掉血"修复）玩家受击侧有 1s 源头去重，而近战每次挥击都传同一个
## 实例 ID → 攻击周期 <1s 的敌人（女巫/丧尸）第二爪必撞冷却窗被吞，第三爪放行，
## 表现为"1 有 2 无 3 有 4 无"。改成每次攻击唯一 ID：去重仍然拦得住"同一次挥击的
## 双路径重复判定"，但不再误杀合法的连续攻击。
var _attack_seq: int = 0

func next_attack_source_id() -> int:
	_attack_seq = (_attack_seq + 1) % 0xFFFFF
	return int(get_instance_id()) + _attack_seq


func get_facing_vector() -> Vector2:
	match _facing:
		FaceDir.DOWN:  return Vector2(0, 1)
		FaceDir.UP:    return Vector2(0, -1)
		FaceDir.LEFT:  return Vector2(-1, 0)
		FaceDir.RIGHT: return Vector2(1, 0)
	return Vector2(0, 1)


## ── 正面抗性结算 ──
## 判定"这一击是否落在敌人正面扇区内"，并按配置缩放伤害。
##
## direction 语义（调用方约定）：伤害的**传播前向** ——
##   · 子弹：子弹飞行方向；
##   · 近战/推击：攻击者的朝向 get_facing_vector()；
##   · 投掷爆炸：从爆心指向敌人的方向。
## 三种都满足"该向量指向敌人被击中的那一侧"，因此：
##   把 direction 反向（= 从敌人指向攻击者的方向），与敌人自身朝向比夹角，
##   夹角 ≤ frontal_arc_degrees 即视为"敌人在正面承受这一击"。
##
## 完全回避（mult=0）时返回 0：调用方后续的属性结算/掉血/硬直都会自然停摆
## （damage>0 的分支全部跳过），但依然走完"被弹开"的红色闪白与音效。
func _apply_frontal_resist(damage: float, direction: Vector2) -> float:
	if frontal_damage_mult >= 1.0 and not frontal_normalize:
		return damage
	if direction == Vector2.ZERO:
		return damage
	# 从敌人指向攻击者的方向
	var to_attacker: Vector2 = -direction.normalized()
	var facing_vec: Vector2 = get_facing_vector()
	var cos_angle: float = to_attacker.dot(facing_vec)
	# 扇区半角比较：cos 单调递减，夹角 ≤ 半角 ⟺ cos ≥ cos(半角)
	var arc: float = clampf(frontal_arc_degrees, 0.0, 180.0)
	if cos_angle < cos(deg_to_rad(arc)):
		return damage  # 落在背面/侧面 → 全额
	var before: float = damage
	if frontal_normalize:
		# Normalize：减免与伤害成比例 → 高伤削得多（对齐原作 Tyrant 设计意图）
		damage = maxf(0.0, damage - damage * clampf(frontal_normalize_ratio, 0.0, 1.0))
	else:
		damage = damage * clampf(frontal_damage_mult, 0.0, 1.0)
	if damage < before:
		# 反馈：正面抗性触发的"弹开"表现（金色偏白闪 + 弹开音效）
		_play_hit_feedback(Color(1.0, 0.95, 0.6, 1.0), 0.08)
		if damage <= 0.0:
			## 完全回避（Hunter β 正面 120°）：加足反馈 —— 弹开音效 + 「無効」飘字。
			## 2026-09-16 用户实测反馈：只有闪白时玩家以为"打不死/枪坏了"。
			_play_sound(frontal_block_sound, frontal_block_sound_pitch)
			var tree := get_tree()
			if tree and tree.current_scene:
				DamageNumber.spawn(global_position + hurt_effect_offset, 0.0,
					tree.current_scene, 0, Color(1.0, 0.95, 0.6), "無効")
		print("[敵人] 正面抗性: %d → %d（扇区 ±%d°）" % [int(before), int(damage), int(arc)])
	return damage


## 获取攻击动画每帧持续时间（秒）
## 优先使用 attack_frame_durations[seq_idx]，为空则使用默认值
func get_attack_frame_duration(seq_idx: int) -> float:
	if attack_frame_durations.size() > seq_idx:
		return attack_frame_durations[seq_idx]
	return 0.1


# ═══════════════════════════════════════
# 伤害
# ═══════════════════════════════════════

func take_damage(damage: float, knockback_force: float, direction: Vector2, is_headshot: bool = false, knockback_stun: float = 0.0, hitstun_duration: float = 0.0, source_id: int = 0, element: int = 0) -> void:
	if _is_dead:
		return

	# ── 正面抗性（特感：Hunter β 回避 / Tyrant Normalize）──
	# 必须在属性结算与 HP 扣减之前：完全回避时不应触发燃烧/冻结/掉血，
	# 但仍要播放"被弹开"的反馈，让玩家知道"这个方向打不进去"。
	if damage > 0.0:
		damage = _apply_frontal_resist(damage, direction)
		## 完全回避（Hunter β 正面扇区）时标记：后续"推击"分支据此跳过误打印与二次闪白，
		## 但**不早退** —— 受击转向、Idle→Discover、击退/硬直等既有副作用必须照常走
		## （2026-09-16 回归：早退会让敌人停在 Idle，正面抗性测试 45° 用例因此失败）。
		_front_blocked_this_hit = damage <= 0.0

	# ── 属性结算（原作 §4.5，按抗性表）──
	# 氷：冻结中受 1.5 倍（"一击粉碎"的数值化）
	if _frozen_time > 0.0:
		damage *= FROZEN_DMG_MULT
	# 雷=感电 / 氷=冻结：并入硬直（Hitstun 状态即"原地冻结、攻击不能"）
	match element:
		WeaponData.Element.LIGHTNING:
			if not resist_lightning:
				hitstun_duration = maxf(hitstun_duration, ELECTRO_TIME)
				_electro_time = ELECTRO_TIME
		WeaponData.Element.ICE:
			if not resist_ice:
				hitstun_duration = maxf(hitstun_duration, FREEZE_TIME)
				_frozen_time = FREEZE_TIME
		WeaponData.Element.FIRE:
			if not resist_fire:
				# tick 只在首燃清零（防火海连续点燃饿死 DoT）；重复点燃只重置持续时间
				if _burning_time <= 0.0:
					_burn_tick = 0.0
				_burning_time = BURN_TIME
				BurnEffect.attach(self)  # 跟随火焰行走图（重复点燃复用同一实例）
		_:
			pass
	_apply_element_tint()

	# 源头去重 + 调试打印
	if source_id != 0:
		var _now: int = Time.get_ticks_msec()
		_clean_expired_damage_sources(_now)
		if source_id in _recent_damage_sources:
			if _now - _recent_damage_sources[source_id] < DAMAGE_SOURCE_COOLDOWN_MSEC:
				print("[敵人] ★★★ 源头去重拦截！source_id=%d 帧=%d ★★★" % [source_id, Engine.get_physics_frames()])
				return
		_recent_damage_sources[source_id] = _now

	# 提前获取当前状态（用于推击闪白判定）
	var sm: Node = get_node_or_null("StateMachine")
	var current_state: String = sm.current_state.name if sm and sm.current_state else ""

	var hp_before := current_hp
	current_hp = maxf(0.0, current_hp - damage)
	var actual_damage := maxf(0.0, hp_before - current_hp)
	if actual_damage > 0.0:
		network_damage_applied.emit(actual_damage, global_position + hurt_effect_offset, is_headshot)
	if damage > 0.0:
		print("[敵人] 受到伤害: %d | HP: %.0f/%.0f | 爆头=%s | source=%d" % [int(damage), current_hp, max_hp, str(is_headshot), source_id])
		_play_hit_feedback(Color.RED)
	elif not _front_blocked_this_hit:
		print("[敵人] 被推击 | HP: %.0f/%.0f" % [current_hp, max_hp])
		# 已在击退/硬直状态中，不重复播放闪白
		if current_state != "Knockback" and current_state != "Hitstun":
			_play_hit_feedback(Color(3, 3, 3, 1), 0.08)

	# 弹出伤害数字（0 伤害如推击不弹出）
	if damage > 0.0:
		var tree := get_tree()
		if tree and tree.current_scene:
			var dmg_color: Color = Color(1.0, 0.85, 0.2) if is_headshot else Color.WHITE
			DamageNumber.spawn(global_position + hurt_effect_offset, damage, tree.current_scene, 0, dmg_color)

	# 播放受伤音效（0 伤害不播放）
	if damage > 0.0:
		_play_sound(hurt_sound, hurt_sound_pitch)

	# 设置击退参数（所有状态统一设置，包括 Idle）
	var has_knockback: bool = knockback_force > 0.0 and knockback_stun > 0.0
	if has_knockback:
		_knockback_dir = direction.normalized()
		_knockback_force = knockback_force
		_knockback_stun = knockback_stun

	# 设置硬直时长（无击退位移的原地冻结，击退优先）
	var has_hitstun: bool = hitstun_duration > 0.0 and not has_knockback
	if has_hitstun:
		_hitstun_duration = hitstun_duration
		_knockback_dir = direction.normalized()  # 仅用于朝向伤害来源

	# 如果处于 Idle 状态（未发现玩家）→ 被发现 + 击退/Discover
	# 注意：Idle 状态下硬直不生效，先进 Discover（"！"发现玩家）
	if current_state == "Idle":
		_try_find_player()
		update_facing_from_direction(-direction)
		_play_sound(get_discover_sound(), get_discover_pitch())

		if current_hp <= 0.0:
			_die(is_headshot)
			return

		if sm:
			if has_knockback and sm.get_node_or_null("Knockback"):
				sm._on_transition_requested("Knockback")
			else:
				sm._on_transition_requested("Discover")
		return

	if current_hp <= 0.0:
		_die(is_headshot)
		return

	# 击退/硬直判定（非 Idle 状态）
	# 硬直仅在追击状态下生效，攻击/发现状态不跳过
	# Exhausted（力竭倒地）视同受控例外：只掉血+闪色，不被击退/硬直打断 ——
	# 倒地是给玩家的输出窗口，不能被流弹搅成反复起倒。
	if sm:
		var blocked_states: Array[String] = ["Knockback", "Death", "HeadshotDeath", "Exhausted"]
		if has_knockback and not current_state in blocked_states:
			if sm.get_node_or_null("Knockback"):
				sm._on_transition_requested("Knockback")
			else:
				print("[敵人] StateMachine 中未找到 Knockback 状态节点")
		elif has_hitstun and current_state == "Chase":
			if sm.get_node_or_null("Hitstun"):
				sm._on_transition_requested("Hitstun")
			else:
				print("[敵人] StateMachine 中未找到 Hitstun 状态节点")


func play_network_hurt_presentation(damage: float, impact_position: Vector2 = global_position, is_headshot: bool = false) -> void:
	if damage <= 0.0:
		return
	_play_hit_feedback(Color.RED)
	var tree := get_tree()
	if tree and tree.current_scene:
		var dmg_color := Color(1.0, 0.85, 0.2) if is_headshot else Color.WHITE
		DamageNumber.spawn(impact_position, damage, tree.current_scene, 0, dmg_color)
	_play_sound(hurt_sound, hurt_sound_pitch)


func _clean_expired_damage_sources(now: int) -> void:
	## 清理超过冷却时间的伤害源记录，防止字典无限增长
	var to_erase: Array[int] = []
	for sid: int in _recent_damage_sources:
		if now - _recent_damage_sources[sid] >= DAMAGE_SOURCE_COOLDOWN_MSEC:
			to_erase.append(sid)
	for sid: int in to_erase:
		_recent_damage_sources.erase(sid)

## 播放受击反馈（闪红/渐隐/闪白）
## hit_color: 变色目标颜色（受击=红，推击=亮白）
## duration: 持续时间（秒），<0 则使用节点默认 hit_feedback_duration
func _play_hit_feedback(hit_color: Color = Color.RED, duration: float = -1.0) -> void:
	if duration < 0.0:
		duration = hit_feedback_duration
	if not sprite:
		return
	# 终止已有的反馈 tween
	if has_meta("_hf_tween"):
		var old: Tween = get_meta("_hf_tween")
		if old and old.is_valid():
			old.kill()
	if hit_feedback_mode == 0:
		# 闪模式：瞬间变色 → 渐变恢复
		var tween := create_tween()
		set_meta("_hf_tween", tween)
		tween.tween_property(sprite, "modulate", hit_color, 0.0)
		tween.tween_property(sprite, "modulate", Color.WHITE, duration)
	else:
		# 渐隐模式：变色 → 颜色渐渐消失
		sprite.modulate = hit_color
		var tween := create_tween()
		set_meta("_hf_tween", tween)
		tween.tween_property(sprite, "modulate", Color.WHITE, duration)
	print("[受击反馈] color=%s duration=%.2fs mode=%d" % [hit_color, duration, hit_feedback_mode])


func _die(is_headshot: bool) -> void:
	_is_dead = true
	_network_headshot_death = is_headshot
	died.emit(self)  ## 击杀统计挂点（防重复：_is_dead 已挡住重复进入 _die）
	BurnEffect.detach(self)  ## 烧死的尸体不留火焰（_update_element_status 死态早退不摘，在此统一摘）
	print("[敵人] 死亡！类型=%s" % ("爆头" if is_headshot else "普通"))

	if is_headshot:
		_play_sound(headshot_sound, headshot_sound_pitch)
	else:
		_play_sound(death_sound, death_sound_pitch)

	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		var death_state_name: String = "HeadshotDeath" if is_headshot else "Death"
		if sm.get_node_or_null(death_state_name):
			sm._on_transition_requested(death_state_name)
		else:
			_become_corpse(is_headshot)


func _become_corpse(is_headshot: bool) -> void:
	_network_headshot_death = is_headshot
	_disable_for_corpse()

	if is_headshot:
		if death_texture != null:
			# 特感：headshot_char_index_1/2 是行走表索引，不适用 → 直接死亡表终帧。
			apply_death_appearance(true)
			_register_corpse()
			return
		_refresh_sprite_with_index(headshot_char_index_1)
		_play_sound(headshot_fall_sound, headshot_fall_sound_pitch)
		var delay_timer: Timer = Timer.new()
		delay_timer.wait_time = headshot_pause_frames / 60.0
		delay_timer.one_shot = true
		delay_timer.timeout.connect(_on_headshot_delay_done.bind(delay_timer))
		add_child(delay_timer)
		delay_timer.start()
	else:
		apply_death_appearance(false)

	_register_corpse()


func _on_headshot_delay_done(timer: Timer) -> void:
	_refresh_sprite_with_index(headshot_char_index_2)
	timer.queue_free()


func _disable_for_corpse() -> void:
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", true)
	# 尸体贴地（reparent 到 GroundLayer）在 _register_corpse() 里统一做 ——
	# 那是所有死亡路径的唯一汇合点，放在这里会被其它路径漏掉（2026-09-11 实际发生过）。
	if vision_area:
		vision_area.set_deferred("monitoring", false)
		vision_area.set_deferred("monitorable", false)
	if hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)
	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)
	if animation_timer:
		animation_timer.stop()
	if discover_label:
		discover_label.hide()
	_moving = false
	velocity = Vector2.ZERO


## 变成尸体的唯一收尾点：贴到最底层 + 注册进全局尸体表。
## ⚠ 三条 Host 侧死亡路径（EnemyDeathState / EnemyHeadshotDeathState / _become_corpse 兜底）
## 全部只经过这里，所以「尸体永远在所有单位下方」这条规则不会再被某条路径漏掉；
## Client 侧的表现路径见 apply_network_death()。
## 尸体生命周期（2026-09-16 用户定）：尸体不再永久保留。
## 死亡后保持 CORPSE_DELAY 秒 → 渐隐 CORPSE_FADE 秒 → 摘除注册并清除实体。合计 3.0 秒。
## 实现要点：
##   · 淡出用**自身 Node2D 的 modulate**，与 sprite.modulate 的受击闪白/元素染色相乘，
##     互不干扰（enemy.gd 只改 sprite.modulate，self.modulate 全程空闲）。
##   · 用 Tween 而非 _process 计时 —— 进 Death 状态后 _disable_for_corpse() 会关掉处理循环。
const CORPSE_DELAY: float = 1.2   ## 死亡后保持不透明的时间（秒）
const CORPSE_FADE: float = 1.8    ## 渐隐时长（秒）

func _register_corpse() -> void:
	_lay_corpse_on_ground()
	_start_corpse_lifecycle()
	if not Global:
		return
	Global.register_corpse(self)


## 启动尸体淡出。幂等（重复调用只生效一次）；联机 Client 侧由 apply_network_death 调用。
func _start_corpse_lifecycle() -> void:
	if not is_inside_tree():
		return
	if has_meta("_corpse_tween"):
		return
	modulate = Color(1, 1, 1, 1)
	var tw: Tween = create_tween()
	set_meta("_corpse_tween", tw)
	tw.tween_interval(CORPSE_DELAY)
	tw.tween_property(self, "modulate:a", 0.0, CORPSE_FADE)
	tw.tween_callback(_despawn_corpse)


## 淡出结束：摘除全局尸体注册并清除敌人实体。
func _despawn_corpse() -> void:
	if Global and Global.has_method("unregister_corpse"):
		Global.unregister_corpse(self)
	queue_free()


## 尸体贴地（用户规则 2026-09-11）：尸体必须永远画在**所有活体单位之下**。
## 做法 = reparent 到 GroundLayer：树序上它在 DecorLayer 之前，而玩家与敌人全部挂在
## DecorLayer(y_sort) 里，于是尸体自然落在「地面图块之上、所有单位之下」。
## ⚠ 不能用负 z_index 实现 —— 那会让尸体沉到地面图块下面被直接盖住。
## 走 deferred 是因为死亡常发生在物理回调里；重复调用是安全的（内部已判重）。
func _lay_corpse_on_ground() -> void:
	if is_inside_tree():
		call_deferred("_reparent_to_ground_layer")


# ═══════════════════════════════════════
# 属性状态（炎/雷/氷）
# ═══════════════════════════════════════

## 每帧更新：燃烧 DoT（燃烧中仍会攻击，非即效性）+ 状态计时与褪色。
func _update_element_status(delta: float) -> void:
	if _is_dead:
		return
	if _burning_time > 0.0:
		_burning_time -= delta
		_burn_tick -= delta
		if _burn_tick <= 0.0:
			_burn_tick = 0.5
			current_hp = maxf(0.0, current_hp - BURN_DPS * 0.5)
			if current_hp <= 0.0:
				_die(false)
				return
	if _frozen_time > 0.0:
		_frozen_time -= delta
	if _electro_time > 0.0:
		_electro_time -= delta
	if _burning_time <= 0.0 and _frozen_time <= 0.0 and _electro_time <= 0.0:
		_clear_element_tint()
		BurnEffect.detach(self)  # 燃烧自然结束（死亡路径随宿主 queue_free 一并回收）


## 按当前状态染色（覆层 modulate；状态结束由 _clear_element_tint 还原）。
func _apply_element_tint() -> void:
	if not sprite:
		return
	if _frozen_time > 0.0:
		sprite.modulate = Color(0.6, 0.85, 2.0)       # 氷=青蓝
	elif _electro_time > 0.0:
		sprite.modulate = Color(2.0, 2.0, 0.7)        # 雷=黄白
	elif _burning_time > 0.0:
		sprite.modulate = Color(1.8, 0.9, 0.55)       # 炎=橙红

func _clear_element_tint() -> void:
	if sprite:
		sprite.modulate = Color.WHITE


## 尸体 reparent 到 GroundLayer（物理回调里不能直接改树，走 deferred）。
func _reparent_to_ground_layer() -> void:
	var tree := get_tree()
	if not tree or not tree.current_scene or not is_inside_tree():
		return
	var ground: Node = tree.current_scene.find_child("GroundLayer", true, false)
	if not ground or get_parent() == ground:
		return
	var gp := global_position
	get_parent().remove_child(self)
	ground.add_child(self)
	global_position = gp
	# z=1（2026-09-17 用户反馈：尸体被上层图块 z=0 图块盖住）：
	# 与玩家/单位同为 z=1 → 压过上层图块里 z=0 的图块；GroundLayer 树序在 DecorLayer
	# 之前 → 同 z 下仍画在所有活体单位之下；z≥2 的上层图块（树冠类）照常遮尸体。
	z_index = 1


# ═══════════════════════════════════════
# 玩家查找
# ═══════════════════════════════════════

## 判断目标是否为玩家（仅玩家拥有 get_weapon_data 方法）
##
## 【HP 归零豁免】current_hp <= 0 的玩家（联机倒地/真死亡、单机死亡瞬间）
## 不再算有效目标 —— 他们已经躺地免伤，继续索敌只会让感染者围尸、
## 压住前来救援的队友。倒地玩家的碰撞体虽然被 NetworkWorld 重新打开
## （为了允许爬行），这里仍会按 HP 把他们从视野/近身目标中剔除。
func _is_player_body(body: Node) -> bool:
	if not body is CharacterBody2D:
		return false
	if not body.has_method("get_weapon_data") or body == self:
		return false
	var hp: Variant = body.get("current_hp")
	if hp != null and float(hp) <= 0.0:
		return false
	return true


func _try_find_player() -> void:
	if vision_area:
		var bodies: Array[Node2D] = vision_area.get_overlapping_bodies()
		for body: Node2D in bodies:
			if _is_player_body(body):
				_player_ref = body
				_player_in_sight = true
				print("[敵人] 从 VisionArea 找到玩家: %s" % body.name)
				return

	# 场景树兜底同样只认存活玩家：最近的实体若是倒地/死亡玩家则放弃，
	# 交给 Idle 状态继续轮询，绝不锁定尸体。
	var nearest := _find_player_in_scene()
	if is_instance_valid(nearest) and _is_player_body(nearest):
		_player_ref = nearest
		_player_in_sight = true
		print("[敵人] 从场景树找到玩家: %s" % _player_ref.name)


func _find_player_in_scene() -> CharacterBody2D:
	return Players.nearest_entity_to(global_position) as CharacterBody2D


# ═══════════════════════════════════════
# 防守战目标锁定
# ═══════════════════════════════════════

## 锁定一名玩家为固定追击目标（防守战期间由 EventManager 调用）。
## 与普通发现流程的区别：无视视野扇形/朝向/距离，且不会因为丢失视野而放弃目标。
## 传入 null 或已倒下的目标时，自动在存活玩家中随机挑一个（单人模式下即唯一玩家）。
func lock_forced_target(target: Node2D = null) -> void:
	if network_presentation_only or _is_dead:
		return
	if not _is_player_body(target):
		target = _pick_random_living_player()
	if target == null:
		return
	_forced_target = target as CharacterBody2D
	_forced_target_locked = true
	_apply_forced_target()


## 解除锁定 → 恢复普通 AI。保留当前目标，后续按视野规则正常追击/放弃。
func release_forced_target() -> void:
	_forced_target_locked = false
	_forced_target = null


func has_forced_target() -> bool:
	return _forced_target_locked


func get_forced_target() -> CharacterBody2D:
	return _forced_target if is_instance_valid(_forced_target) else null


## 把锁定目标写入 _player_ref，并在 Idle 时踢进 Discover（→ Chase）。
func _apply_forced_target() -> void:
	if not is_instance_valid(_forced_target):
		return
	_player_ref = _forced_target
	_player_in_sight = true
	var sm: Node = get_node_or_null("StateMachine")
	if not sm or not sm.current_state:
		return
	if sm.current_state.name == "Idle" and sm.get_node_or_null("Discover"):
		sm._on_transition_requested("Discover")


## 每帧维持锁定：
## 1) 目标倒下/失效 → 随机改锁另一名存活玩家（全员倒下则暂时空转，等复活）
## 2) 目标被其他逻辑（Idle 视野轮询、枪声惊动）改掉 → 重新夺回
func _maintain_forced_target() -> void:
	if not _forced_target_locked or _is_dead or network_presentation_only:
		return
	if not is_instance_valid(_forced_target) or not _is_player_body(_forced_target):
		var replacement: CharacterBody2D = _pick_random_living_player()
		if replacement == null:
			_forced_target = null
			return
		_forced_target = replacement
	if _player_ref != _forced_target:
		_apply_forced_target()


## 在所有存活玩家中随机挑一个。单人模式下只有一个候选 → 必然锁定唯一玩家。
func _pick_random_living_player() -> CharacterBody2D:
	var candidates: Array[CharacterBody2D] = []
	for entity: Node2D in Players.all_entities(true):
		if _is_player_body(entity):
			candidates.append(entity as CharacterBody2D)
	if candidates.is_empty():
		return null
	return candidates[randi() % candidates.size()]


## 被枪声惊动（由玩家开火时调用）。
## 仅影响尚未发现玩家的敌人（Idle 状态）。
func alert_by_gunshot(shooter: Node2D) -> void:
	if _is_dead:
		return
	if _player_ref != null:
		return  # 已经发现玩家，不需要重复惊动
	_player_ref = shooter as CharacterBody2D
	var sm := get_node_or_null("StateMachine") as StateMachine
	if sm and sm.current_state and sm.current_state.name == "Idle":
		print("[敌人] %s 被枪声惊动！" % name)
		sm._on_transition_requested("Discover")

# ═══════════════════════════════════════
# 视野检测
# ═══════════════════════════════════════

func _on_vision_area_body_entered(body: Node2D) -> void:
	if _is_dead:
		return
	if _is_player_body(body):
		if _is_in_vision_cone(body):
			_player_in_sight = true
			_player_ref = body


func _on_vision_area_body_exited(body: Node2D) -> void:
	if body == _player_ref:
		_player_in_sight = false


func _is_in_vision_cone(target: Node2D) -> bool:
	var dir_to: Vector2 = target.global_position - global_position
	var dist: float = dir_to.length()
	if dist > vision_range:
		return false
	var forward: Vector2 = get_facing_vector()
	var angle: float = rad_to_deg(dir_to.normalized().angle_to(forward))
	if abs(angle) >= vision_angle / 2.0:
		return false
	# ── LOS 视线遮挡（2026-09-13 用户回归：敌人透过墙壁看到玩家）──
	# 朝目标打一条墙层射线（图块墙物理层 bit1），被挡 = 看不见。
	# 排除自己与目标本体；目标必须同时过扇形+距离+LOS 三关。
	var space := get_world_2d().direct_space_state
	if space:
		var q := PhysicsRayQueryParameters2D.create(global_position, target.global_position, 1)
		q.exclude = [get_rid(), target.get_rid()]
		q.hit_from_inside = false
		if not space.intersect_ray(q).is_empty():
			return false
	return true


# ═══════════════════════════════════════
# 精灵渲染
# ═══════════════════════════════════════

func set_attack_char_index(char_idx: int) -> void:
	_anim_step = 0
	_refresh_sprite_with_index(char_idx)


## ── 附加动作表切换（特感：攻击/死亡使用独立贴图）──
##
## 普通僵尸的攻击/死亡帧都在同一张行走图表内（不同角色格索引），因此只需切 char_index。
## 特感（如 T-002）的动作分属不同贴图文件，需要连贴图一起换。
## 用法：状态 enter() 调 push_action_texture(tex)，exit() 调 restore_walk_texture()。
## 切换后帧尺寸会被重新推断（不同动作表的帧宽高可能不同）。

## 切到附加动作表。tex 为空则不动作（保持当前贴图）。
##
## 帧尺寸 determination 顺序（用户 2026-09-12 定稿）：
##   1. 该表自己的缓存（此前推过且确认过）；
##   2. **继承当前（行走）表的帧尺寸** —— 特感的攻击/死亡表画的是同一角色同一比例，
##      只要当前尺寸能整除新表尺寸就直接沿用（"像行走那样的尺寸就没问题"）。
##      T-002 攻击表 1536×576 是"1 角色列"布局（高只有标准的一半角色数，画布高度不变），
##      盲目重推会得出 128×72 把角色水平腰斩；继承行走表的 128×144 则完全正确。
##   3. 兜底：按贴图自动推断（_guess_frame_dim，对标准 4 列×2 角色布局可靠）。
func push_action_texture(tex: Texture2D, char_idx: int = 0) -> void:
	if tex == null:
		return
	if _action_texture_stack.is_empty():
		_action_texture_prev = walk_texture
		# 记住行走表的帧尺寸，restore 时精确还原（不靠重新推断）
		_frame_w_prev = sprite_frame_w
		_frame_h_prev = sprite_frame_h
	_action_texture_stack.append(tex)
	walk_texture = tex
	var cached: Variant = _frame_size_by_texture.get(tex)
	var tex_w: int = tex.get_width()
	var tex_h: int = tex.get_height()
	if cached is Vector2i and cached.x > 0 and cached.y > 0 \
			and tex_w % cached.x == 0 and tex_h % cached.y == 0:
		sprite_frame_w = cached.x
		sprite_frame_h = cached.y
	elif sprite_frame_w > 0 and sprite_frame_h > 0 \
			and tex_w % sprite_frame_w == 0 and tex_h % sprite_frame_h == 0:
		# 同角色动作表：沿用行走表帧尺寸（见函数头注释）
		pass
	else:
		sprite_frame_w = 0
		sprite_frame_h = 0
		_sync_frame_size_to_texture()
	_frame_size_by_texture[tex] = Vector2i(sprite_frame_w, sprite_frame_h)
	_refresh_sprite_with_index(char_idx)


## 恢复到行走图（并恢复切换前的角色索引与帧尺寸）。
func restore_walk_texture() -> void:
	if _action_texture_stack.is_empty():
		return
	_action_texture_stack.pop_back()
	walk_texture = _action_texture_prev if _action_texture_stack.is_empty() else _action_texture_stack.back()
	if _action_texture_stack.is_empty():
		# 精确还原行走表帧尺寸（推断不可靠：多动作表宽度整除方式有歧义）
		sprite_frame_w = _frame_w_prev
		sprite_frame_h = _frame_h_prev
		## 回到站立帧（中帧）：攻击/突进期间 _anim_step 停在 0（左踏步），
		## 直接恢复会以「迈步」姿势站着，下一拍行走动画才归位（2026-09-15 用户反馈）
		_anim_step = 1
		_apply_sprite_anchor()
	else:
		# 回到栈顶那张动作表的帧尺寸（用缓存，避免重复推断出错）
		var top: Texture2D = _action_texture_stack.back()
		var cached: Variant = _frame_size_by_texture.get(top)
		if cached is Vector2i and cached.x > 0 and cached.y > 0:
			sprite_frame_w = cached.x
			sprite_frame_h = cached.y
			_apply_sprite_anchor()
		else:
			sprite_frame_w = 0
			sprite_frame_h = 0
			_sync_frame_size_to_texture()
	_refresh_sprite()


## 当前是否处于附加动作表（供状态机判断是否需要恢复）。
func has_action_texture() -> bool:
	return not _action_texture_stack.is_empty()


## ── 死亡表现统一入口（death_texture 接入，2026-09-13）──
##
## 普通僵尸的死亡帧在行走表内（death_char_index 索引），历史路径直接
## _refresh_sprite_with_index(death_char_index)。特感（T-002 等）的死亡帧在
## **专用死亡表**（death_texture）里，行走表没有那个角色格 —— 直接索引会越界
## （T-002 death_char_index=3 在行走表只显示错误格子）。
## 统一规则：
##   - death_texture 非空 → push 到死亡表（死亡是终态，不存在 restore 回走表）；
##     帧索引用 death_texture_char_index（-1 回退 death_char_index）。
##   - 爆头死亡对特感同理：headshot_char_index_1/2 是行走表索引，对特感无意义，
##     直接显示死亡表最终帧（放弃两段倒地动画）。
##   - death_texture 为空 → 完全维持旧行为，普通僵尸零影响。
func apply_death_appearance(is_headshot: bool) -> void:
	if death_texture != null:
		push_action_texture(death_texture,
				death_texture_char_index if death_texture_char_index >= 0 else death_char_index)
		_death_appearance_applied = true
	elif is_headshot:
		_refresh_sprite_with_index(headshot_char_index_1)
	else:
		_refresh_sprite_with_index(death_char_index)


func _refresh_sprite() -> void:
	if not sprite or not walk_texture:
		return
	if _is_dead:
		return
	sprite.texture = walk_texture
	var frame: int = STAND_FRAME if not _moving else WALK_SEQUENCE[_anim_step]
	_current_char_index = walk_char_index
	_draw_sprite_rect(walk_char_index, frame)


func _refresh_sprite_with_index(char_idx: int) -> void:
	if not sprite or not walk_texture:
		return
	sprite.texture = walk_texture
	_current_char_index = char_idx
	_draw_sprite_rect(char_idx, STAND_FRAME)


# ── 步行/跑步双移动模式（暴君・猎杀者）──
var _run_mode: bool = false            ## 当前是否处于跑步形态
var _walk_char_index_base: int = -1    ## 注入时的步行角色索引（切回步行用）
var _walk_speed_base: float = 0.0      ## 注入时的步行移速（切回步行用）
var _run_bases_cached: bool = false

## 按与最近存活玩家的距离切步行/跑步（2026-09-13 用户定稿规则）：
##   - 步行态：距离 > trigger → 切跑步；
##   - 跑步态：**保持跑步，直到命中玩家**（notify_run_mode_hit）才切回步行——
##     不做「离得近就自动降速」（用户：暴君贴脸变散步很怪），切回后恢复距离判定；
##   - 无目标（玩家全灭/死亡/切人）→ 步行（玩家死亡后 T-002 徘徊必须显示走路图，索引1）。
## 距离规则在 Host/Client 两侧确定性一致 → Client 本地推导即可，零网络改动。
## 只动 walk_char_index 与 move_speed 两个变量：攻击/突进状态推自己的动作表与帧，
## 不受影响；切表时（has_action_texture）不立即刷新，等回到行走表自然生效。
func _update_run_mode() -> void:
	if run_char_index < 0 or run_speed <= 0.0 or _is_dead:
		return
	if not _run_bases_cached:
		_walk_char_index_base = walk_char_index
		_walk_speed_base = move_speed
		_run_bases_cached = true
	var target: Node2D = _player_ref
	if not is_instance_valid(target) or target.get("_is_dying") == true:
		var players_node: Node = get_node_or_null("/root/Players")
		if players_node and players_node.has_method("nearest_entity_to"):
			target = players_node.nearest_entity_to(global_position)
	var dist: float = INF
	var has_target: bool = false
	if is_instance_valid(target) and target.get("_is_dying") != true:
		dist = global_position.distance_to(target.global_position)
		has_target = true
	var trigger: float = run_trigger_distance if run_trigger_distance > 0.0 else 320.0
	var want_run: bool = _run_mode if _run_mode else (has_target and dist > trigger)
	if want_run == _run_mode:
		return
	_apply_run_mode(want_run)


## 实际切跑步/步行形态（行走图行 + 移速 + 立即刷新行走帧）。
func _apply_run_mode(run: bool) -> void:
	_run_mode = run
	if not _run_bases_cached:
		_walk_char_index_base = walk_char_index
		_walk_speed_base = move_speed
		_run_bases_cached = true
	if _run_mode:
		walk_char_index = run_char_index
		move_speed = run_speed
	else:
		walk_char_index = _walk_char_index_base
		move_speed = _walk_speed_base
	# 行走图行切换立即生效（动作表激活期不动——帧归状态机管）
	if not has_action_texture():
		_refresh_sprite()


## 命中玩家 → 跑步切回步行（用户定稿：跑步只在打到玩家后结束）。
## 由 EnemyAttackState._do_attack_hit / EnemyPounceState._do_pounce_hit 调用。
func notify_run_mode_hit() -> void:
	if not _run_mode:
		return
	_apply_run_mode(false)


func _draw_sprite_rect(char_idx: int, frame: int) -> void:
	var fw: int = sprite_frame_w if sprite_frame_w > 0 else FRAME_W
	var fh: int = sprite_frame_h if sprite_frame_h > 0 else FRAME_H
	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var dir_row: int = DIR_ROWS[_facing]
	var x: int = char_col * (fw * 3) + frame * fw
	var y: int = char_row * (fh * DIRECTIONS) + dir_row * fh
	sprite.region_rect = Rect2(x, y, fw, fh)


## 按贴图实际尺寸自动推断帧宽高（仅当 sprite_frame_w/h 未显式指定时）。
##
## 推断依据 VX 规格：每角色格 = 3 帧 × 4 方向。整表宽度 = 角色格列数 × 3 × 帧宽。
## 表不一定是标准 4 列（T-002 的三张表是 6 列 × 4 行），因此不能直接除以 12/8。
## 做法：在候选帧宽里找"能整除且格子数合理"的最大值 —— 优先按 CHARS_PER_ROW
## 列推断，失败再逐档回退。
##
## ⚠ 对表列数 ≠ CHARS_PER_ROW 的素材（如 T-002 的 6 列）本函数会算错，
## 必须靠 .tres 的 sprite_frame_w/h 或 _frame_size_by_texture 缓存兜底 ——
## 见 push_action_texture()。
func _sync_frame_size_to_texture() -> void:
	if not walk_texture:
		return
	var tex_w: int = int(walk_texture.get_width())
	var tex_h: int = int(walk_texture.get_height())
	if tex_w <= 0 or tex_h <= 0:
		return
	if sprite_frame_w <= 0:
		sprite_frame_w = _guess_frame_dim(tex_w, true)
	if sprite_frame_h <= 0:
		sprite_frame_h = _guess_frame_dim(tex_h, false)
	if sprite_frame_w <= 0:
		sprite_frame_w = FRAME_W
	if sprite_frame_h <= 0:
		sprite_frame_h = FRAME_H
	_apply_sprite_anchor()


## 推断一维帧尺寸。`horizontal` = 是否宽度方向（宽度按 3 帧/格，高度按 4 方向/格）。
## 优先取"整表恰好 CHARS_PER_ROW 个角色格"的解；其次取最大的合法整除数。
func _guess_frame_dim(total: int, horizontal: bool) -> int:
	var per_block: int = 3 if horizontal else DIRECTIONS
	var prefer_cols: int = CHARS_PER_ROW if horizontal else 2
	# 首选：整表 = prefer_cols 个角色格（标准布局）
	if total % (per_block * prefer_cols) == 0:
		var v: int = total / (per_block * prefer_cols)
		if v > 0:
			return v
	# 回退：找最大整除数（格数从多到少试），保证格宽 ≥ 8px 避免噪声解
	var best: int = 0
	for blocks in range(prefer_cols, 0, -1):
		if total % (per_block * blocks) == 0:
			var cand: int = total / (per_block * blocks)
			if cand >= 8:
				best = cand
				break
	return best


## 按当前帧高把精灵"脚底"对齐到节点原点上方 16px（与原有 48×64 素材的观感一致）。
## Sprite2D 默认居中绘制，故 position.y = -(half_h - 16)：
##   帧高 64 → -16（原值，保持既有敌人不变）；帧高 144 → -56。
func _apply_sprite_anchor() -> void:
	if not sprite:
		return
	var fh: int = sprite_frame_h if sprite_frame_h > 0 else FRAME_H
	sprite.position = Vector2(0, -(fh * 0.5 - 16.0))


# ═══════════════════════════════════════
# 音效工具
# ═══════════════════════════════════════

## 行走动画帧时长（秒）：walk_frame_duration >0 = 手动固定；0 = 按全局基准
## （玩家默认步行 150px/s↔0.18s）与当前移动速度自动换算（2026-09-15）。
## move_speed 已被跑步/狂暴换速逻辑维护为「当前实际速度」，直接取值即可。
func _current_anim_frame_duration() -> float:
	if walk_frame_duration > 0.0:
		return walk_frame_duration
	var d: float = Global.ANIM_BASE_FRAME_DURATION * Global.ANIM_BASE_SPEED / maxf(move_speed, 1.0)
	return clampf(d, 0.05, 0.5)


func _play_sound(stream: AudioStream, pitch: float = 1.0) -> void:
	if not stream:
		return
	# 敌人是世界内声源：走 2D 定位（随距离衰减+声像）。旧的非定位播放让屏外
	# 丧尸叫和贴脸一样响，叠加并发上限内多实例 → 用户反馈「叫声音量大得离谱」。
	# pitch：每音效独立音调（2026-09-15）。
	Global.play_sfx_managed(stream, self, true, pitch)


# ═══════════════════════════════════════
# Debug 可视化
# ═══════════════════════════════════════

func _draw() -> void:
	if not Global.debug_visuals:
		return

	var cs: CollisionShape2D = $CollisionShape2D
	var color: Color = Color.GRAY if _is_dead else Color.RED
	var shape: Shape2D = cs.shape
	if shape is RectangleShape2D:
		var rect: RectangleShape2D = shape as RectangleShape2D
		var pos: Vector2 = cs.position
		draw_rect(Rect2(pos - rect.size / 2, rect.size), color, false, 1.0)

	if _is_dead:
		var bar_w: float = 48.0
		var bar_h: float = 4.0
		var bar_y: float = -40.0
		draw_rect(Rect2(-bar_w / 2, bar_y, bar_w, bar_h), Color.GRAY, true)
		return

	var forward: Vector2 = get_facing_vector()
	var half_angle: float = deg_to_rad(vision_angle / 2.0)
	var segments: int = 16
	var points: PackedVector2Array = PackedVector2Array()
	points.append(Vector2.ZERO)
	for i: int in range(segments + 1):
		var a: float = -half_angle + (2.0 * half_angle) * float(i) / float(segments)
		points.append(forward.rotated(a) * vision_range)
	draw_polygon(points, PackedColorArray([Color(1, 1, 0, 0.1)]))

	var left_edge: Vector2 = forward.rotated(-half_angle) * vision_range
	var right_edge: Vector2 = forward.rotated(half_angle) * vision_range
	draw_line(Vector2.ZERO, left_edge, Color(1, 1, 0, 0.3))
	draw_line(Vector2.ZERO, right_edge, Color(1, 1, 0, 0.3))
	draw_arc(Vector2.ZERO, vision_range, -half_angle, half_angle, 16, Color(1, 1, 0, 0.3))

	# 攻击命中矩形（attack_hit_range）—— 橙紅，跟随朝向旋转
	var hit_offset: Vector2 = forward * attack_hit_forward_offset
	var hw: float = attack_hit_range.x / 2.0
	var hh: float = attack_hit_range.y / 2.0
	var hit_side: Vector2 = Vector2(-forward.y, forward.x)
	var hit_corners: PackedVector2Array = PackedVector2Array([
			hit_offset + forward * hh + hit_side * hw,
			hit_offset + forward * hh - hit_side * hw,
			hit_offset - forward * hh - hit_side * hw,
			hit_offset - forward * hh + hit_side * hw,
	])
	hit_corners.append(hit_corners[0])
	draw_polyline(hit_corners, Color.ORANGE_RED, 1.0)

	# 攻击触发矩形（attack_range）—— 青色，与判定矩形相同旋转逻辑
	var tr_offset: Vector2 = forward * attack_range_forward_offset
	var tr_hw: float = attack_range.x / 2.0
	var tr_hh: float = attack_range.y / 2.0
	var tr_corners: PackedVector2Array
	if abs(forward.x) > abs(forward.y):
		var side: Vector2 = Vector2(-forward.y, forward.x)
		tr_corners = PackedVector2Array([
			tr_offset + forward * tr_hh + side * tr_hw,
			tr_offset + forward * tr_hh - side * tr_hw,
			tr_offset - forward * tr_hh - side * tr_hw,
			tr_offset - forward * tr_hh + side * tr_hw,
		])
	else:
		tr_corners = PackedVector2Array([
			tr_offset + Vector2(-tr_hw, -tr_hh),
			tr_offset + Vector2( tr_hw, -tr_hh),
			tr_offset + Vector2( tr_hw,  tr_hh),
			tr_offset + Vector2(-tr_hw,  tr_hh),
		])
	tr_corners.append(tr_corners[0])
	draw_polyline(tr_corners, Color.CYAN, 1.0)

	var bar_w: float = 48.0
	var bar_h: float = 4.0
	var bar_y: float = -40.0
	var ratio: float = current_hp / max_hp
	draw_rect(Rect2(-bar_w / 2, bar_y, bar_w, bar_h), Color.RED, false, 1.0)
	draw_rect(Rect2(-bar_w / 2, bar_y, bar_w * ratio, bar_h), Color.RED, true)

	# 绘制受击碰撞体（黄色）
	if hurt_area:
		var hshape_node: CollisionShape2D = hurt_area.get_node_or_null("HurtShape")
		if hshape_node and hshape_node.shape is RectangleShape2D:
			var hs: Vector2 = (hshape_node.shape as RectangleShape2D).size
			var ho: Vector2 = hshape_node.position
			draw_rect(Rect2(ho - hs / 2, hs), Color.YELLOW, false, 1.0)

	# ── A* 调试：绘制路径 ──
	_draw_debug_path()

	# ── A* 调试：绘制可行走网格 ──
	_draw_debug_walk_grid()


func _draw_debug_path() -> void:
	if _debug_path.is_empty():
		return

	# 路径线 — 绿色
	if _debug_path.size() >= 2:
		for i in range(_debug_path.size() - 1):
			var a: Vector2 = _debug_path[i] - global_position
			var b: Vector2 = _debug_path[i + 1] - global_position
			draw_line(a, b, Color.GREEN, 2.0)

	# 路径点 — 绿色小圈
	for wp: Vector2 in _debug_path:
		var lp: Vector2 = wp - global_position
		draw_circle(lp, 3.0, Color.GREEN)
		draw_circle(lp, 4.0, Color.DARK_GREEN, false, 1.0)

	# 下一个目标路径点 — 亮黄色
	if _debug_path_idx < _debug_path.size():
		var target: Vector2 = _debug_path[_debug_path_idx] - global_position
		draw_circle(target, 6.0, Color.YELLOW, false, 2.0)

	# 起点/终点标记（格子坐标 → 世界坐标）
	var cell_half: float = _debug_cell_size / 2.0
	var start_wp: Vector2 = Vector2(_debug_start_grid.x * _debug_cell_size + cell_half, _debug_start_grid.y * _debug_cell_size + cell_half) - global_position
	var end_wp: Vector2 = Vector2(_debug_end_grid.x * _debug_cell_size + cell_half, _debug_end_grid.y * _debug_cell_size + cell_half) - global_position
	draw_rect(Rect2(start_wp - Vector2(6, 6), Vector2(12, 12)), Color.BLUE, false, 2.0)
	draw_rect(Rect2(end_wp - Vector2(6, 6), Vector2(12, 12)), Color.RED, false, 2.0)

	# 路径状态文字
	var status: String = "OK:%d" % _debug_path.size() if _debug_path_found else "FAIL(iters:%d)" % _debug_astar_iters
	draw_string(ThemeDB.fallback_font, Vector2(20, -50), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.GREEN if _debug_path_found else Color.RED)


func _draw_debug_walk_grid() -> void:
	if _debug_walk_cache.is_empty():
		return

	var cell_half: float = _debug_cell_size / 2.0
	var cs: float = _debug_cell_size

	# 性能优化：按可见范围计算网格坐标遍历，而非遍历整个缓存字典
	# 预构建后缓存可能包含全图数万格子，遍历字典每帧极卡
	var view_range: int = 6  ## 格子数（约 192px @ 32px/cell）
	var center_gp: Vector2i = Vector2i(floori(global_position.x / cs), floori(global_position.y / cs))

	for dx in range(-view_range, view_range + 1):
		for dy in range(-view_range, view_range + 1):
			var gp: Vector2i = Vector2i(center_gp.x + dx, center_gp.y + dy)
			if not _debug_walk_cache.has(gp):
				continue
			var world: Vector2 = Vector2(gp.x * cs + cell_half, gp.y * cs + cell_half)
			var local: Vector2 = world - global_position

			var walkable: bool = _debug_walk_cache[gp]
			if walkable:
				draw_rect(Rect2(local - Vector2(cell_half, cell_half), Vector2(cs, cs)), Color(0, 1, 0, 0.08), true)
			else:
				draw_rect(Rect2(local - Vector2(cell_half, cell_half), Vector2(cs, cs)), Color(1, 0, 0, 0.15), true)
				draw_line(local + Vector2(-4, -4), local + Vector2(4, 4), Color.RED, 1.0)
				draw_line(local + Vector2(-4, 4), local + Vector2(4, -4), Color.RED, 1.0)


# ═══════════════════════════════════════
# 僵尸变体：狂暴（クリムゾンヘッド）形态
# ═══════════════════════════════════════

func set_rage(on: bool) -> void:
	## 狂暴形态切换：尸潮（peak 阶段）触发时行走图切为对应的クリムゾンヘッド并加速加攻，
	## 尸潮结束恢复普通形态。该外观没有狂暴图（variant_rage_texture == null）时是 no-op。
	##
	## ⚠ 只换行走图、不改角色帧索引 —— 本项目所有角色图都是同一转换器产出的同布局图
	## （576×512，走/攻/死/爆头帧索引一致），索引直接复用。
	if _rage == on:
		return
	if on and variant_rage_texture == null:
		return  ## 无狂暴形态的外观（如中年ゾンビ）保持普通
	_rage = on
	if on:
		walk_texture = variant_rage_texture
		if variant_rage_move_speed > 0.0:
			move_speed = variant_rage_move_speed
		if variant_rage_attack_damage > 0.0:
			attack_damage = variant_rage_attack_damage
		if variant_rage_discover_sound != null:
			_play_sound(variant_rage_discover_sound,
				variant_rage_discover_pitch if variant_rage_discover_pitch > 0.0 else 1.0)  ## 狂暴化瞬间的吼叫
		# 力竭阈值重置并加 ±20% 抖动：同批狂暴的丧尸不会整整齐齐一起倒
		_rage_move_accum = 0.0
		_rage_exhaust_target = (
			variant_rage_exhaust_seconds * randf_range(0.85, 1.2)
			if variant_rage_exhaust_seconds > 0.0 else 0.0
		)
	else:
		walk_texture = _base_walk_texture
		if variant_rage_move_speed > 0.0:
			move_speed = _base_move_speed
		if variant_rage_attack_damage > 0.0:
			attack_damage = _base_attack_damage
		_rage_move_accum = 0.0
		_rage_exhaust_target = 0.0
	_refresh_sprite()


func _enter_exhausted() -> void:
	## 狂暴力竭 → 切 Exhausted 状态（倒地）。已在力竭/死亡/无状态机时忽略。
	if _exhausted or _is_dead:
		return
	var sm: Node = get_node_or_null("StateMachine")
	if sm and sm.get_node_or_null("Exhausted"):
		_exhausted = true
		sm._on_transition_requested("Exhausted")


func is_exhausted() -> bool:
	return _exhausted


func is_rage() -> bool:
	return _rage


func get_discover_sound() -> AudioStream:
	## 发现玩家的音效：狂暴状态下用狂暴叫声（クリム_叫び），否则普通ゾンビ声。
	if _rage and variant_rage_discover_sound != null:
		return variant_rage_discover_sound
	return discover_sound


func get_discover_pitch() -> float:
	## 与 get_discover_sound 配套：狂暴叫声用狂暴音调，否则普通发现音调。
	if _rage and variant_rage_discover_sound != null:
		return variant_rage_discover_pitch if variant_rage_discover_pitch > 0.0 else 1.0
	return discover_sound_pitch
