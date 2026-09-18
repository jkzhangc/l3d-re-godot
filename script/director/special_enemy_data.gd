class_name SpecialEnemyData
extends Resource

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：数据（Resource，.tres）
## 联机：数据只读；Host 在 spawn_special_enemy 时注入敌人实体，Client 由快照驱动表现
## 职责：定义一种「特感」（特殊敌人：ハンター、タイラント 等，非普通僵尸变体）：
##       · texture —— 行走图（576×512 同布局表，与 ZombieVariant 素材同一转换器产出）
##       · 数值    —— 血量 / 移速 / 攻击力 / 攻击后摇 / 视野 / 攻击是否附带 Heat
##       · 音效    —— 发现音效（如 ハンター声）
## 依赖：无（纯数据）。消费方：DirectorConfig.special_pool → Director.spawn_special_enemy()。
##
## 【设计（2026-09-12，对齐原作说明书）】
##   · 特感与普通僵尸变体（ZombieVariant）分开建模：特感是「低频、高压、同屏互斥」的
##     独立编排对象，不走 ZombieVariant 的分段概率池，也不参与尸潮狂暴形态切换
##     （enemy.variant_rage_texture 保持 null → set_rage 自动 no-op）。
##   · 编排参数（出现延迟 / 冷却 / 同屏上限 / 紧张度门槛）在 DirectorConfig 的
##     「生成 — 特感」组配置，不在本资源里 —— 数值策略归关卡，个体能力归资源。
##   · 原作（E:/15.L3D 说明书）依据：
##     ハンター =「すばやい動きで接近し、爪で攻撃する。首狩り攻撃は弾薬耐久を削り
##     Heat を与える。首狩り後は大きな隙ができる」，登场自带高压迫感 → 数值取向：
##     高速（240）、中攻（15）、攻击附带 Heat、攻击后摇长（90 帧 ≈1.5s 破绽）。

@export_group("标识")
@export var id: StringName = &""
## 关卡特感池内被随机选中的权重（0 = 不会被选中）。
@export var weight: float = 1.0

@export_group("初始行为")
## 一登场就进入追击：跳过 Idle 徘徊与 Discover 提示，开场立即锁定最近的存活玩家。
## 特感与 Tank 默认开启 —— 它们不是"路过时才注意到你"的杂兵，而是带着压迫感
## 登场的威胁，不该在玩家面前游荡或先发一个"!"。普通僵尸保持 false。
@export var starts_in_chase: bool = true
## 开场锁定的目标距离上限（px）。0 = 不限距离，直接锁最近的存活玩家。
@export var chase_acquire_range: float = 0.0

@export_group("贴图")
## 行走图精灵表（576×512，角色帧索引与 enemy.gd 布局表一致）。
@export var texture: Texture2D = null
## 精灵表内的角色索引（默认 0 = 第一个角色）。
@export var walk_char_index: int = 0
## 攻击动画的角色帧序列（覆盖 enemy.gd 的 attack_char_sequence 默认值 [1,2,3,1,0]）。
## 空 = 沿用敌人默认（普通僵尸攻击帧）。特感若有不复用丧尸攻击帧的专属素材，
## 在此填其角色索引序列（与 walk_sequence 同构，仅作用于攻击状态）。
@export var attack_char_sequence: Array[int] = []

## ── 攻击动画节奏与判定帧（与 enemy.gd 同名字段对齐）──
## 动机：特感攻击素材的帧节奏/判定时机与普通丧尸不同（用户 2026-09-13 反馈
## 「猎杀者跟丧尸攻击判定位置不一样」）——把逐帧时长与判定帧索引下沉到 tres，
## 让攻击判定精确落在素材的「挥中」那一帧上。
## 每帧持续时间（秒），索引与 attack_char_sequence 对齐。
## 空 = 沿用 enemy 默认节奏（每帧 0.1s）。
@export var attack_frame_durations: Array[float] = []
## 在此序列索引处触发伤害判定（enemy.gd 默认 2）。-1 = 沿用默认。
@export var hit_at_sequence_idx: int = -1
## 攻击判定矩形相对敌人中心的前方偏移（px；enemy.gd 默认 28）。
## -1 = 沿用默认。爪击类素材挥得远的特感可调大，让判定区跟着素材走。
@export var attack_hit_forward_offset: float = -1.0

@export_subgroup("放大版素材（帧尺寸非 48×64）")
## 单帧宽（px）。0 = 由 enemy.gd 按贴图尺寸自动推断（推荐）。
## T-002 暴君素材单帧 128×144，靠自动推断即可，无需手填。
@export var sprite_frame_w: int = 0
## 单帧高（px）。0 = 自动推断。
@export var sprite_frame_h: int = 0

@export_subgroup("受击表现与受击碰撞体（大体型敌人用）")
## 受伤表现偏移（2026-09-15）：伤害数字/受击表现相对角色原点的偏移。
## T-002 原点在脚部，配 (0, -64) 把表现抬到躯干。
@export var hurt_effect_offset: Vector2 = Vector2.ZERO
## 受击碰撞体尺寸（enemy 默认 28×44，对大体型敌人太小——子弹只有脚部才结算）。
## Vector2.ZERO = 不覆盖，沿用 enemy 默认。
@export var hurtbox_size: Vector2 = Vector2.ZERO
## 受击碰撞体偏移（相对角色原点）。Vector2.ZERO = 不覆盖。
@export var hurtbox_offset: Vector2 = Vector2.ZERO

@export_subgroup("附加动作表（可选）")
## 攻击动作表（独立贴图）。攻击状态时临时切到这张表 + attack_char_sequence 指定角色格。
## 空 = 攻击也用 texture。T-002 的攻击 4 阶段表挂这里。
@export var attack_texture: Texture2D = null
## 死亡动作表（独立贴图）。死亡状态时切到这张表。空 = 用 texture。
@export var death_texture: Texture2D = null
## 死亡动画使用的角色格索引。-1 = 不覆盖（沿用 enemy 默认 4）。
##   · 配了 death_texture → 本值是**死亡表内**的格索引（T-002 = 3）；
##   · 没配 death_texture → 本值是**行走表内**的格索引（女巫 = 3）。
##
## 【素材规则（用户 2026-09-16 确认）】ハンター 系（α/β/γ）的死亡图**不在行走图里**，
## 而在同系列「带 2」的那张图 —— 例：行走 ハンター1.png → 死亡看 **ハンター2.png**，
## 一律取**索引 4**（血溅帧）。行走表 8 格全是站立/挥爪，直接用会摆出攻击姿势。
@export var death_char_index: int = -1

@export_group("数值")
## 最大生命值。0 = 沿用敌人默认（enemy.gd 的 max_hp=100）。
@export var max_hp: float = 150.0## 移动速度（px/s）。ハンター「すばやい動き」→ 240（普通僵尸约 120~160）。
@export var move_speed: float = 240.0

## ── 步行/跑步双移动模式（暴君・猎杀者，2026-09-13 用户指定素材映射）──
## 远距离跑步逼近、近距离步行。素材索引：T-002 body 跑步=0/走路=1；
## ハンター1 走路=0/跑步=1。-1/0 = 无跑步模式（单速）。
@export var run_char_index: int = -1
## 跑步移速（px/s）。ユーザー指定试值 260。
@export var run_speed: float = 0.0
## 切跑步的距离阈值（px，0 = 默认 320；回步行 = 0.75×阈值，带迟滞）。
@export var run_trigger_distance: float = 0.0
## 攻击伤害。
@export var attack_damage: float = 15.0
## 攻击触发矩形（宽×高，px），跟随朝向旋转。0 = 沿用敌人默认。
@export var attack_range: Vector2 = Vector2.ZERO
## 攻击判定矩形（宽×高，px）——真正造成伤害的范围。0 = 沿用敌人默认。
@export var attack_hit_range: Vector2 = Vector2.ZERO
## 攻击后摇帧数（≈0.5秒@60fps）。ハンター首狩り后「大きな隙」→ 90 帧（≈1.5s）。
## 0 = 沿用敌人默认（30 帧）。
@export var attack_cooldown_frames: int = 0
## 视野距离（px）。特感比普通僵尸（200）更早发现玩家 → 320。0 = 沿用敌人默认。
@export var vision_range: float = 0.0
## 攻击命中时是否给玩家叠加 Heat（原作：首狩り命中削弹药耐久并进入 Heat 异常）。
@export var attack_causes_heat: bool = true
## 攻击属性（WeaponData.Element：0=无 1=炎 2=雷 3=氷 4=酸）。酸命中玩家自动触发削り。
## ブレインディモス 的近战酸爪 = 4（远程酸弹的削り由酸弹命中路径自带 element=4）。
@export var attack_element: int = 0
## 是否启用近战攻击（玩家进攻击矩形时切 Attack）。false = 纯远程（贴脸也只吐酸）。
## ブレインディモス = false（2026-09-17 用户裁定：不要近战）。
@export var melee_enabled: bool = true

@export_group("音效")
## 发现/低吼音效（ハンター=「ハンター声」系列）。留空则沿用敌人自身 discover_sound。
@export var discover_sound: AudioStream = null
## 发现音效音调。0 = 沿用敌人自身 discover_sound_pitch（2026-09-15 每音效可设音调）。
@export var discover_sound_pitch: float = 0.0
## 受伤音效。留空则沿用敌人自身 hurt_sound。
@export var hurt_sound: AudioStream = null
## 受伤音效音调。0 = 沿用敌人自身 hurt_sound_pitch。
@export var hurt_sound_pitch: float = 0.0
## 攻击挥击音效（EnemyAttackState 起手播放）。留空则沿用敌人自身 attack_sound。
@export var attack_sound: AudioStream = null
## 攻击挥击音效音调。0 = 沿用敌人自身 attack_sound_pitch。
@export var attack_sound_pitch: float = 0.0
## 击中目标音效（攻击命中玩家且实际掉血时播放）。留空则沿用敌人自身 hit_target_sound。
@export var hit_target_sound: AudioStream = null
## 击中目标音效音调。0 = 沿用敌人自身 hit_target_sound_pitch。
@export var hit_target_sound_pitch: float = 0.0
## 死亡音效（普通死亡 EnemyDeathState / _die）。留空则沿用敌人自身 death_sound。
@export var death_sound: AudioStream = null
## 死亡音效音调。0 = 沿用敌人自身 death_sound_pitch（2026-09-15 特感 tres 可配）。
@export var death_sound_pitch: float = 0.0

@export_group("正面抗性")
## 正面扇区内受到的伤害倍率：1.0 = 无减免（默认）。
## Hunter β 的「正面枪击完全回避」= 0.0；Tyrant 的硬抗 = 用 frontal_normalize 代替。
@export var frontal_damage_mult: float = 1.0
## 正面扇区半角（度）：60 = 以朝向为中心 ±60°（合计 120°）算"正面"。
@export var frontal_arc_degrees: float = 60.0
## Normalize（Tyrant）：正面伤害改为按比例减免，单发越高削越多。
@export var frontal_normalize: bool = false
## Normalize 减免系数（frontal_normalize 开启时生效）：0.6 → 实际只吃 40%。
@export var frontal_normalize_ratio: float = 0.6

@export_group("首狩り突进（ハンター 系）")
## 是否启用首狩り突进（中距离高速扑咬）。普通僵尸与 Tyrant 保持 false。
@export var pounce_enabled: bool = false
## 触发首狩り的最小距离（px）：更近则直接走普通 Attack。
@export var pounce_trigger_min_dist: float = 110.0
## 触发首狩り的最大距离（px）：更远则继续正常追击。
@export var pounce_trigger_max_dist: float = 340.0
## 蓄力时长（秒）：给玩家反应窗口。
@export var pounce_windup_seconds: float = 0.28
## 冲刺时长（秒）。
@export var pounce_dash_seconds: float = 0.42
## 冲刺速度倍率（相对 move_speed）。
@export var pounce_speed_mult: float = 1.8
## 突进绝对速度（2026-09-15）：>0 直接用作冲刺速度（忽略 move_speed×mult）。ハンター=400。
@export var pounce_dash_speed: float = 0.0
## 命中半径（px）。
@export var pounce_hit_radius: float = 42.0
## 吸附转向速率（0~1）：冲刺途中朝玩家插值转向。位移通常小于触发带宽，
## 纯直线会扑空，故默认开启吸附。设 0 = 纯直线突进。
@export var pounce_homing_turn_rate: float = 0.08
## 冲刺末帧命中宽容倍率：终点距离 ≤ hit_radius × 此值即视作接触命中。
@export var pounce_hit_tolerance: float = 1.6
## 命中伤害倍率（相对 attack_damage）。
@export var pounce_damage_mult: float = 1.2
## 首狩り冷却（秒）：两次突进之间的最短间隔。
@export var pounce_cooldown_seconds: float = 2.5
## 冲刺期锁定突刺帧：true = 整个 DASH 保持攻击序列第 1 帧。
## ハンターγ 的突刺素材要求「直到突刺移动结束之前，一直保持1」；
## ハンター/ハンターβ 保持 false（进度式推进，视觉上是连续扑咬）。
@export var pounce_hold_frame_during_dash: bool = false
## 首狩り起跳/突进音效。留空则沿用敌人自身 pounce_sound（再回退 attack_sound）。
@export var pounce_sound: AudioStream = null
## 首狩り音效音调。0 = 沿用敌人自身 pounce_sound_pitch。
@export var pounce_sound_pitch: float = 0.0

@export_group("女巫徘徊（ブレアウィッチ）")
## 是否启用女巫模式：初始进徘徊态（不主动接近/攻击），被刺激后激怒全力追杀。
@export var witch_enabled: bool = false
## 徘徊移速（px/s）。女巫平时蹲着哭，移动极慢。
@export var witch_wander_speed: float = 18.0
## 刺激半径（px）：玩家进入才开始累积刺激值。
@export var witch_stim_radius: float = 160.0
## 刺激累积速度基准（越近越快）。
@export var witch_stim_speed: float = 1.0
## 激怒后的移速倍率。
@export var witch_enrage_speed_mult: float = 2.2
## 激怒尖叫音效。留空则用 discover_sound。
@export var witch_scream_sound: AudioStream = null
## 激怒尖叫音效音调。0 = 沿用敌人自身 witch_scream_sound_pitch。
@export var witch_scream_sound_pitch: float = 0.0

@export_group("丸呑み（ハンターγ）")
## 是否启用丸呑み（零距离必杀）：玩家贴脸时有概率触发「吞入 → 咀嚼 → 吐出即死」。
@export var swallow_enabled: bool = false
## 触发距离（px）：玩家在此距离内才可能被丸呑み。原作「零距離で」。
@export var swallow_trigger_range: float = 52.0
## 触发概率（0~1）：每次进入触发距离时的判定成功率（避免贴脸必被吞，太惩罚）。
@export var swallow_chance: float = 0.45
## 咀嚼循环次数（2→3 循环次数）：原作「多次后回到 1」。
@export var swallow_chew_cycles: int = 3
## 单次咀嚼间隔（秒）：即 2→3 循环的每轮时长。
@export var swallow_chew_interval: float = 0.28
## 吐出后到恢复待机的停顿（秒）：原作「过一会回到 0」。
@export var swallow_recover_seconds: float = 0.9
## 丸呑み动画的贴图（独立动作表）。空 = 复用 texture。
@export var swallow_texture: Texture2D = null
## 丸呑み动画的角色索引序列：[0]=准备, [1]=吞入判定, [2]=咀嚼A, [3]=咀嚼B。
## 对应原作 y2 的 0 → 1(丸吞判定区) → 2 → 3。
@export var swallow_char_sequence: Array[int] = [0, 1, 2, 3]
## 丸呑み是否无视ガッツ直接致死（原作：伤害是致死）。true = 吐出的瞬间必死。
@export var swallow_is_lethal: bool = true
## 丸呑み期间对玩家造成的多段削り总量（弹药/耐久削减，原作「多段削りで武器も駄目に」）。
@export var swallow_weapon_attrition: float = 0.0

@export_group("远程吐酸（ブレインディモス）")
## 是否启用远程吐酸（全工程首个敌人远程攻击）。普通僵尸与近战特感保持 false。
## 原作依据（enemy.html ブレインディモス条）：「遠距離から酸をはきかけてくる」「この酸には
## 削り効果があり、連続で食らうと武器があっという間にダメにされてしまう」。
@export var spit_enabled: bool = false
## 吐酸触发距离带（px）：更近走普通近战 Attack（melee_enabled 时），更远继续追击。
@export var spit_trigger_min_dist: float = 0.0
@export var spit_trigger_max_dist: float = 400.0
## 吐酸冷却（秒）：两次吐酸的最短间隔（从后摇结束后起算，与首狩り同规则）。
@export var spit_cooldown_seconds: float = 1.8
## 蓄力（后仰）时长（秒）：吐酸前的反应窗口。
@export var spit_windup_seconds: float = 0.35
## 吐酸后摇（秒）：吐完的硬直（原作近战武器的「大きな隙」在远程这里缩水成小破绽）。
@export var spit_recover_seconds: float = 0.6
## 酸弹飞行速度（px/s）。2026-09-17 用户：加快 → 450。
@export var spit_projectile_speed: float = 450.0
## 酸弹伤害（命中玩家）。削り不走数值——element=4（酸）命中自动触发 player._apply_attrition()。
@export var spit_damage: float = 8.0
## 吐酸动画的角色格序列（套图 1.png：3=后仰蓄势 4=前倾吐酸）。空 = 沿用攻击序列。
@export var spit_char_sequence: Array[int] = []
## 在此序列索引处发射酸弹（0 起始）。注意别配 0（帧步进后检查的永假边界，见十字弩教训）。
@export var spit_fire_at_sequence_idx: int = 1
## 吐酸音效。留空 = 不播（酸着弾音由酸弹场景自播）。
@export var spit_sound: AudioStream = null
@export var spit_sound_pitch: float = 1.0
## 酸弹命中/落地特效（anim/ 下的 VXAnimSprite 场景，如 anim_effect_酸.tscn）。
## 命中玩家与撞墙/落地共用。空 = 不播特效。
@export var spit_impact_effect: PackedScene = null
## 特效染色 tone（乘法调制，白 = 原样，见 VXAnimSprite.tone）。
@export var spit_impact_tone: Color = Color(1, 1, 1, 1)

@export_group("即死耐性")
## 集中射撃（覚醒）的即死弹免疫。原作 enemy.html ブレインディモス条：即死 ×（即死耐性）。
## true = 集中射撃命中时走 Boss 同款结算：伤害 ×1.5 + 0.8s 怯み，不死。
@export var instant_kill_immune: bool = false


# ═══════════════════════════════════════
# 注入（Host 生成 / Client 重建共用）
# ═══════════════════════════════════════

## 把本资源的全部字段注入一只 enemy 实例。Host 与 Client 共用同一份注入代码：
## · Host —— Director.spawn_special_enemy() 在 add_child 前调用（_ready 的 _refresh_sprite
##   需要注入后的 walk_texture 才能摆对首帧）。
## · Client —— NetworkWorld 按 special_id 从 NETWORK_SPECIALS 白名单取得本资源后调用
##   （Client 不跑 AI 状态机，注入的 AI 字段不会生效，只消费外观/帧表/受击盒）。
## 注意：必须在 add_child 之前调用；initial_facing 由调用方按出生点语义另行设置。
func apply_to_enemy(enemy: Node) -> void:
	if texture:
		enemy.walk_texture = texture
		enemy.walk_char_index = walk_char_index
	enemy.move_speed = move_speed
	enemy.attack_damage = attack_damage
	# 步行/跑步双移动模式（暴君・猎杀者：-1/0 = 未配置 = 单速）
	enemy.run_char_index = run_char_index
	enemy.run_speed = run_speed
	enemy.run_trigger_distance = run_trigger_distance
	# 初始行为：特感/Tank 登场即追击（Client 无 AI，字段随注入保持同源）
	enemy.starts_in_chase = starts_in_chase
	enemy.chase_acquire_range = chase_acquire_range
	if float(max_hp) > 0.0:
		enemy.max_hp = float(max_hp)
	if attack_range.x > 0.0 and attack_range.y > 0.0:
		enemy.attack_range = attack_range
	if attack_hit_range.x > 0.0 and attack_hit_range.y > 0.0:
		enemy.attack_hit_range = attack_hit_range
	if attack_cooldown_frames > 0:
		enemy.attack_cooldown_frames = attack_cooldown_frames
	if vision_range > 0.0:
		enemy.vision_range = vision_range
	enemy.attack_causes_heat = attack_causes_heat
	enemy.attack_element = attack_element
	enemy.melee_enabled = melee_enabled
	enemy.instant_kill_immune = instant_kill_immune
	# 远程吐酸（ブレインディモス）
	enemy.spit_enabled = spit_enabled
	enemy.spit_trigger_min_dist = spit_trigger_min_dist
	enemy.spit_trigger_max_dist = spit_trigger_max_dist
	enemy.spit_cooldown_seconds = spit_cooldown_seconds
	enemy.spit_windup_seconds = spit_windup_seconds
	enemy.spit_recover_seconds = spit_recover_seconds
	enemy.spit_projectile_speed = spit_projectile_speed
	enemy.spit_damage = spit_damage
	enemy.spit_char_sequence = spit_char_sequence
	enemy.spit_fire_at_sequence_idx = spit_fire_at_sequence_idx
	enemy.spit_sound = spit_sound
	enemy.spit_sound_pitch = spit_sound_pitch
	enemy.spit_impact_effect = spit_impact_effect
	enemy.spit_impact_tone = spit_impact_tone
	# 正面抗性（Hunter β 回避 / Tyrant Normalize）
	enemy.frontal_damage_mult = frontal_damage_mult
	enemy.frontal_arc_degrees = frontal_arc_degrees
	enemy.frontal_normalize = frontal_normalize
	enemy.frontal_normalize_ratio = frontal_normalize_ratio
	# 首狩り突进（ハンター 系）
	enemy.pounce_enabled = pounce_enabled
	enemy.pounce_trigger_min_dist = pounce_trigger_min_dist
	enemy.pounce_trigger_max_dist = pounce_trigger_max_dist
	enemy.pounce_windup_seconds = pounce_windup_seconds
	enemy.pounce_dash_seconds = pounce_dash_seconds
	enemy.pounce_speed_mult = pounce_speed_mult
	enemy.pounce_dash_speed = pounce_dash_speed
	enemy.pounce_hit_radius = pounce_hit_radius
	enemy.pounce_homing_turn_rate = pounce_homing_turn_rate
	enemy.pounce_hit_tolerance = pounce_hit_tolerance
	enemy.pounce_damage_mult = pounce_damage_mult
	enemy.pounce_cooldown_seconds = pounce_cooldown_seconds
	# 冲刺期锁定突刺帧（ハンターγ：原作「直到突刺移动结束之前，一直保持1」）
	enemy.pounce_hold_frame_during_dash = pounce_hold_frame_during_dash
	# 特感专属攻击动画帧序列（空 = 沿用丧尸默认帧）
	if attack_char_sequence.size() > 0:
		enemy.attack_char_sequence = attack_char_sequence
	# 攻击动画节奏与判定帧（tres 未配置 = 沿用 enemy 默认）
	if attack_frame_durations.size() > 0:
		enemy.attack_frame_durations = attack_frame_durations
	if hit_at_sequence_idx >= 0:
		enemy.hit_at_sequence_idx = hit_at_sequence_idx
	if attack_hit_forward_offset >= 0.0:
		enemy.attack_hit_forward_offset = attack_hit_forward_offset
	# 放大版素材帧尺寸（0 = 由 enemy.gd 按贴图自动推断）
	enemy.sprite_frame_w = sprite_frame_w
	enemy.sprite_frame_h = sprite_frame_h
	# 受击表现偏移 + 受击碰撞体（大体型敌人）
	enemy.hurt_effect_offset = hurt_effect_offset
	if hurtbox_size != Vector2.ZERO:
		enemy.hurtbox_size = hurtbox_size
	if hurtbox_offset != Vector2.ZERO:
		enemy.hurtbox_offset = hurtbox_offset
	# 附加动作表（T-002 等：走/攻/死分属不同贴图文件）
	if attack_texture != null:
		enemy.attack_texture = attack_texture
	if death_texture != null:
		enemy.death_texture = death_texture
	# death_char_index 语义按「有没有专用死亡表」分流（-1 = 不覆盖）：
	#   有 death_texture → 它是**死亡表内**的格索引（T-002 = 3）
	#   无 death_texture → 它是**行走表内**的格索引（女巫 = 3）
	if death_char_index >= 0:
		if death_texture != null:
			enemy.death_texture_char_index = death_char_index
		else:
			enemy.death_char_index = death_char_index
	# 女巫徘徊（ブレアウィッチ）
	enemy.witch_enabled = witch_enabled
	enemy.witch_wander_speed = witch_wander_speed
	enemy.witch_stim_radius = witch_stim_radius
	enemy.witch_stim_speed = witch_stim_speed
	enemy.witch_enrage_speed_mult = witch_enrage_speed_mult
	if witch_scream_sound != null:
		enemy.witch_scream_sound = witch_scream_sound
	if witch_scream_sound_pitch > 0.0:
		enemy.witch_scream_sound_pitch = witch_scream_sound_pitch
	# 攻击挥击音效（空 = 沿用敌人自身 attack_sound）
	if attack_sound != null:
		enemy.attack_sound = attack_sound
	if attack_sound_pitch > 0.0:
		enemy.attack_sound_pitch = attack_sound_pitch
	# 击中目标音效（空 = 沿用敌人自身 hit_target_sound）
	if hit_target_sound != null:
		enemy.hit_target_sound = hit_target_sound
	if hit_target_sound_pitch > 0.0:
		enemy.hit_target_sound_pitch = hit_target_sound_pitch
	# 死亡音效（空 = 沿用敌人自身 death_sound）
	if death_sound != null:
		enemy.death_sound = death_sound
	if death_sound_pitch > 0.0:
		enemy.death_sound_pitch = death_sound_pitch
	# 首狩り起跳/突进音效（空 = 沿用敌人自身 pounce_sound，再回退 attack_sound）
	if pounce_sound != null:
		enemy.pounce_sound = pounce_sound
	if pounce_sound_pitch > 0.0:
		enemy.pounce_sound_pitch = pounce_sound_pitch
	# 丸呑み（ハンターγ）
	enemy.swallow_enabled = swallow_enabled
	enemy.swallow_trigger_range = swallow_trigger_range
	enemy.swallow_chance = swallow_chance
	enemy.swallow_chew_cycles = swallow_chew_cycles
	enemy.swallow_chew_interval = swallow_chew_interval
	enemy.swallow_recover_seconds = swallow_recover_seconds
	enemy.swallow_char_sequence = swallow_char_sequence
	enemy.swallow_is_lethal = swallow_is_lethal
	enemy.swallow_weapon_attrition = swallow_weapon_attrition
	if swallow_texture != null:
		enemy.swallow_texture = swallow_texture
	if discover_sound != null:
		enemy.discover_sound = discover_sound
	if discover_sound_pitch > 0.0:
		enemy.discover_sound_pitch = discover_sound_pitch
	if hurt_sound != null:
		enemy.hurt_sound = hurt_sound
	if hurt_sound_pitch > 0.0:
		enemy.hurt_sound_pitch = hurt_sound_pitch
