class_name CharacterData extends Resource
## 角色参数数据 — 可在检查器中可视化编辑

@export_group("基础属性")
@export var character_name: String = "のび太"
@export var level: int = 1
@export var max_hp: int = 100
@export var max_mp: int = 50

@export_group("战斗属性")
@export var base_attack: int = 15
@export var base_defense: int = 5
@export var base_speed: float = 1.0
@export var critical_rate: float = 0.05    ## 暴击率 (0~1)
@export var critical_damage: float = 1.5    ## 暴击倍率

@export_group("成长率")
@export var hp_growth: int = 10
@export var mp_growth: int = 5
@export var atk_growth: int = 3
@export var def_growth: int = 2

@export_group("外观")
@export var portrait: Texture2D              ## 角色立绘/头像
@export var walk_texture: Texture2D          ## 行走图精灵表
@export var walk_char_index: int = 0         ## 行走图角色索引
@export var walk_frame_duration: float = 0.18
@export var run_texture: Texture2D           ## 跑步图精灵表
@export var run_char_index: int = 1          ## 跑步图角色索引
@export var run_frame_duration: float = 0.10
@export var death_texture: Texture2D         ## 死亡图精灵表（留空回退 walk_texture）
@export var death_char_index: int = 7        ## 死亡角色索引

@export_group("音效")
@export var hurt_sound: AudioStream = null   ## 受伤音效
@export var death_sound: AudioStream = null  ## 死亡音效

# ═══════════════════════════════════════
# 运行时 HP（不保存到 .tres，由存档系统管理）
# ═══════════════════════════════════════
var current_hp: float = 0.0


## 初始化运行时 HP 为最大 HP
func init_runtime_hp() -> void:
	current_hp = float(get_effective_max_hp())


## 受到伤害，返回是否死亡
func take_damage(damage: float) -> bool:
	current_hp = maxf(0.0, current_hp - damage)
	return current_hp <= 0.0


## 恢复 HP
func heal(amount: float) -> void:
	current_hp = minf(float(get_effective_max_hp()), current_hp + amount)


## 计算当前等级的实际属性
func get_effective_attack() -> int:
	return base_attack + (level - 1) * atk_growth


func get_effective_defense() -> int:
	return base_defense + (level - 1) * def_growth


func get_effective_max_hp() -> int:
	return max_hp + (level - 1) * hp_growth


func get_effective_max_mp() -> int:
	return max_mp + (level - 1) * mp_growth
