class_name ThrowableData extends ItemData
## 投掷物数据 — 继承 ItemData，增加投掷/爆炸/燃烧参数

@export_group("投掷")
@export var throw_range_max: int = 8        ## 最大投掷格数（默认 3 格）
@export var projectile_texture: Texture2D   ## 飞行中的投掷物精灵（可选，回退 pickup_texture/icon）

@export_group("爆炸（手雷）")
@export var explosion_radius: int = 0       ## 爆炸半径（格，0=不爆炸）
@export var damage: float = 50.0            ## 伤害（爆炸瞬间 / 火焰灼烧）

@export_group("燃烧（燃烧瓶）")
@export var fire_radius: int = 0            ## 燃烧范围（格，0=不燃烧）
@export var fire_duration: float = 5.0      ## 燃烧持续时间（秒）

@export_group("音效")
@export var throw_sound: AudioStream = null
@export var explode_sound: AudioStream = null
