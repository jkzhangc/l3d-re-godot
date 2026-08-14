class_name ThrowableData extends ItemData
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
## 爆炸特效动画（VXAnimSprite 场景，留空不播放）
@export var explode_effect_anim: PackedScene = null

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
@export var explode_sound: AudioStream = null
