class_name ThrowableData extends ItemData

## ── 架构定位 ──
## 系统：投掷物数据 ｜ 层：数据（Resource）
## 联机：终点/伤害由 Host 复核
## 职责：投掷物配置：投掷距离、抛物线表现、爆炸半径与伤害、燃烧半径/时长/跳伤间隔、持物行走图。
## 依赖：继承 ItemData

## 投掷物数据 — 继承 ItemData，增加投掷/爆炸/燃烧参数

@export_group("投掷")
@export var throw_range_max: int = 8        ## 最大投掷格数（默认 3 格）
@export var projectile_texture: Texture2D   ## 飞行中的投掷物精灵（可选，回退 pickup_texture/icon）

@export_group("举起显示")
## 举起投掷物时的角色行走图精灵表（包含各角色的持物外观）。留空则不显示持物外观
@export var held_walk_texture: Texture2D

@export_group("飞行表现")
## 飞行抛物线最高点（像素，0=直线飞行）
@export var arc_height: float = 36.0
## 飞行旋转速度（弧度/秒，0=不旋转）
@export var spin_speed: float = 12.0

@export_group("爆炸（手雷）")
@export var explosion_radius: int = 0       ## 爆炸半径（格，0=不爆炸）
@export var damage: float = 50.0            ## 伤害（爆炸瞬间 / 火焰灼烧）
## 属性（原作 §4.5）：炎=命中燃烧、雷=感电、氷=冻结、酸=仅伤害+削り。对应原作投掷物：
## 火炎瓶=炎、ボルトグレネード=雷、液体窒素=氷、ディモ酢瓶=酸。
@export var element: int = 0                ## WeaponData.Element（0=NONE 1=炎 2=雷 3=氷 4=酸）
## 爆炸特效动画（VXAnimSprite 场景，留空不播放）
@export var explode_effect_anim: PackedScene = null
## 能否炸开可爆破墙（BlastWall）。默认 false —— 只有炸药配 true；手雷等炸不开
## （2026-09-16 用户定稿：矿洞墙体只认炸药，配合 place_required_flag 放置路线）。
@export var breaks_blast_wall: bool = false

@export_group("燃烧（燃烧瓶）")
@export var fire_radius: int = 0            ## 燃烧范围（格，0=不燃烧）
@export var fire_duration: float = 5.0      ## 燃烧持续时间（秒）
## 灼烧 tick 间隔（秒，默认 0.33 ≈ 20 帧）
@export var fire_tick_interval: float = 0.33
## 火精灵在行走图中的角色索引（天罰キャラチップ.png 为 4×2 共 8 角色）
@export var fire_char_idx: int = 0
## 火海环境音（循环播放，留空不播放）
@export var fire_ambient_sound: AudioStream = null

@export_group("音效")
@export var throw_sound: AudioStream = null
## 投出音效音调（<=0 = 原调）。2026-09-15 用户定稿：手雷/炸药/燃烧瓶回避2 = 1.4（写在各 tres）。
@export_range(0.0, 4.0, 0.1) var throw_sound_pitch: float = 1.0
@export var explode_sound: AudioStream = null

@export_group("闪光（閃光手榴弾 / Night Hunter）")
## 闪光半径（格，0=非闪光弹）。>0 时落地：范围内敌人长时间硬直（致盲/怯み），
## 夜间视界下短暂照亮全场，玩家侧白屏。
@export var flash_radius: int = 0
## 敌人硬直时长（秒）。0 伤害，只给 hitstun —— 对应原作「怯み効果」。
@export var flash_stun_duration: float = 3.0
## 夜间视界照亮时长（秒）。NightOverlay.flash 的 duration。
@export var flash_light_duration: float = 1.2
## 玩家白屏时长（秒）。0=不白屏（联机 Client 也吃这个表现）。
@export var flash_screen_duration: float = 0.35
