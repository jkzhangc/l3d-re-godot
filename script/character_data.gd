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

@export_group("武器行走图")
## 每个武器状态名 → 该角色在此武器下的行走图精灵表
## 键=weapon_state_name（如 "Pistol"/"Knife"），值=Texture2D
## 若某武器的键不存在，渲染时回退到 WeaponData.weapon_walk_texture
@export var weapon_walk_textures: Dictionary = {}

@export_group("武器限制")
## 允许使用的主武器 item_id 列表。空数组=所有主武器允许
@export var allowed_primary_weapons: Array[String] = []
## 允许使用的副武器 item_id 列表。空数组=所有副武器允许
@export var allowed_secondary_weapons: Array[String] = []

@export_group("选择界面")
## 角色选择界面使用的小头像（如未设置则用 portrait）
@export var select_portrait: Texture2D

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


## 获取该角色的武器行走图纹理
## weapon_state_name: WeaponData.weapon_state_name（如 "Pistol"/"Knife"/"Rifle"）
## 返回 Texture2D 或 null（null 表示回退到 WeaponData 的 weapon_walk_texture）
func get_weapon_walk_texture(weapon_state_name: String) -> Texture2D:
	if weapon_walk_textures.has(weapon_state_name):
		return weapon_walk_textures[weapon_state_name] as Texture2D
	return null


## 检查该角色是否可以使用指定武器
## wd: WeaponData 资源
func can_use_weapon(wd: WeaponData) -> bool:
	if not wd:
		return false
	var restrictions: Array[String]
	if wd.weapon_slot == WeaponData.WeaponSlot.PRIMARY:
		restrictions = allowed_primary_weapons
	else:
		restrictions = allowed_secondary_weapons
	if restrictions.is_empty():
		return true
	return restrictions.has(wd.item_id)


## 序列化为字典（供存档系统使用）
func to_dict() -> Dictionary:
	return {
		"resource_path": resource_path,
		"character_name": character_name,
		"level": level,
		"current_hp": current_hp,
	}
