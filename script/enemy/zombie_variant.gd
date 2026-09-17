class_name ZombieVariant
extends Resource
## ── 架构定位 ──
## 系统：敌人系统 ｜ 层：数据（Resource，.tres）
## 联机：数据只读；Host 在 spawn_enemy 时选种并注入敌人实体，Client 由快照驱动表现
## 职责：定义一种僵尸的「外观 + 属性 + 狂暴形态」：
##       · normal_texture —— 普通状态行走图（ゾンビ 系列）
##       · rage_texture   —— 狂暴状态行走图（クリムゾンヘッド 系列；null = 该外观没有狂暴形态）
##       · 数值           —— 普通/狂暴的移动速度与攻击伤害
##       · rage_discover_sound —— 狂暴状态下的发现/吼叫音效（默认 クリム_叫び）
##       · 力竭           —— 狂暴态累计奔跑约 rage_exhaust_seconds 秒后倒地
##         （rage_exhaust_down_seconds 秒，起身变回普通形态；原作说明书依据见 enemy.gd）
## 依赖：无（纯数据）。消费方：Director（选种+注入）、enemy.gd（set_rage 切换）。
##
## 【设计（2026-09-10 与用户确认）】
##   · 刷哪种 = 按关卡固定池（DirectorConfig.zombie_pool）内按 weight 随机；
##   · 狂暴不是独立敌人，而是同一只僵尸的形态切换：尸潮（peak 阶段）触发时
##     行走图切换为对应的クリムゾンヘッド并加速加攻，尸潮结束恢复普通形态；
##   · タイラント/ハンター/キメラ等大型特殊敌不属于本机制，后续单独添加。
##   原作（E:/15.L3D）的クリムゾン是「按概率刷出的独立类型」（#576 街レベルクリムゾン
##   → 発生ＢＯＷ番号=40）；本设计按用户要求改为形态切换，数值可在此逐变体调整。

@export_group("标识")
@export var id: StringName = &""
## 关卡池内被随机选中的权重（0 = 不会被选中）。
@export var weight: float = 1.0

@export_group("贴图")
## 普通状态行走图（ゾンビ）。
@export var normal_texture: Texture2D = null
## 狂暴状态行走图（クリムゾンヘッド）。null = 该外观不会狂暴（set_rage 直接 no-op）。
## ⚠ 两种图必须是同一转换器产出的同布局图（本项目全部为 576×512、角色帧索引一致），
## 否则攻击/死亡/爆头帧会错位。
@export var rage_texture: Texture2D = null

@export_group("数值")
## 最大生命值。0 = 沿用敌人默认（enemy.gd 的 max_hp=100）。
@export var max_hp: float = 0.0
## 普通移动速度（px/s）。
@export var move_speed: float = 160.0
## 狂暴移动速度（px/s）。默认 1.5×普通。
@export var rage_move_speed: float = 240.0
## 普通攻击伤害。
@export var attack_damage: float = 10.0
## 狂暴攻击伤害。默认 1.6×普通。
@export var rage_attack_damage: float = 16.0
## 狂暴力竭阈值（秒）：狂暴态累计移动达到该值 → 力竭倒地（EnemyExhaustedState）。
## 原作说明书：クリムゾンヘッド「１０秒ほど走り回されると倒れてしまう」。
## 0 = 该变体禁用力竭。
@export var rage_exhaust_seconds: float = 10.0
## 力竭倒地时长（秒）。倒地期间不能行动，起身时变回普通形态。
@export var rage_exhaust_down_seconds: float = 3.5

@export_group("音效")
## 普通状态的发现/低吼音效。留空则沿用敌人自身 discover_sound。
## 素材：sound/ゾンビ声*.wav（男系）、sound/女ゾンビ声*.wav（女系）。
@export var discover_sound: AudioStream = null
## 受伤音效。留空则沿用敌人自身 hurt_sound。
@export var hurt_sound: AudioStream = null
## 攻击挥击音效（EnemyAttackState 起手播放）。留空则沿用敌人自身 attack_sound。
@export var attack_sound: AudioStream = null
## 狂暴状态下的发现/吼叫音效（変異レベルの叫び）。留空则沿用敌人自身 discover_sound。
@export var rage_discover_sound: AudioStream = preload("res://sound/クリム_叫び.ogg")
## 死亡音效（普通死亡 EnemyDeathState）。留空则沿用敌人自身 death_sound（ゾンビ声6）。
@export var death_sound: AudioStream = null
## 爆头命中音效（EnemyHeadshotDeathState 入场）。留空则沿用敌人自身 headshot_sound。
@export var headshot_sound: AudioStream = null
## 爆头倒地音效（爆头最终保持帧）。留空则沿用敌人自身 headshot_fall_sound。
@export var headshot_fall_sound: AudioStream = null
## 击中目标音效（攻击命中玩家且实际掉血时播放）。留空则沿用敌人自身 hit_target_sound。
@export var hit_target_sound: AudioStream = null

## ── 音效音调（2026-09-15）：每个音效可独立设置；0 = 沿用敌人自身默认音调 ──
@export var discover_sound_pitch: float = 0.0
@export var hurt_sound_pitch: float = 0.0
@export var attack_sound_pitch: float = 0.0
@export var rage_discover_sound_pitch: float = 0.0
@export var death_sound_pitch: float = 0.0
@export var headshot_sound_pitch: float = 0.0
@export var headshot_fall_sound_pitch: float = 0.0
@export var hit_target_sound_pitch: float = 0.0

@export_group("数值扩展（0 / 零值 = 沿用敌人默认）")
## 攻击后摇帧数（enemy.gd attack_cooldown_frames，30≈0.5s@60fps）。0 = 沿用。
@export var attack_cooldown_frames: int = 0
## 攻击元素属性（与 enemy.attack_element 同码表；0 = 无属性，沿用）。
@export var attack_element: int = 0
## 视野角度（度）。0 = 沿用（90°）。
@export var vision_angle: float = 0.0
## 视野距离（像素）。0 = 沿用（200）。
@export var vision_range: float = 0.0
## 行走动画帧时长（秒）。0 = 沿用（0.18）。
@export var walk_frame_duration: float = 0.0
## 受击碰撞体尺寸。ZERO = 沿用（28×44）。
@export var hurtbox_size: Vector2 = Vector2.ZERO
## 受击碰撞体偏移。ZERO = 沿用（0, -8）。
@export var hurtbox_offset: Vector2 = Vector2.ZERO
