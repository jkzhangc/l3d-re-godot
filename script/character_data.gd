class_name CharacterData extends Resource
## 角色参数数据 — 可在检查器中可视化编辑

@export_group("基础属性")
@export var character_name: String = "のび太"
@export var level: int = 1
@export var max_hp: int = 100
@export var max_mp: int = 50
@export var max_tp: int = 100                  ## TP（技能点/气力，后续技能系统使用）

@export_group("TP 回复")
@export var tp_regen_amount: int = 1           ## 每次自动回复的 TP 量
@export var tp_regen_interval: float = 5.0     ## 每隔多少秒自动回复一次（0=不自动回复）

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

@export_group("投掷物行走图")
## 该角色在投掷物举起行走图（ThrowableData.held_walk_texture）中的角色索引
@export var throwable_walk_char_idx: int = 0

@export_group("武器限制")
## 允许使用的主武器 item_id 列表。空数组=所有主武器允许
@export var allowed_primary_weapons: Array[String] = []
## 允许使用的副武器 item_id 列表。空数组=所有副武器允许
@export var allowed_secondary_weapons: Array[String] = []

@export_group("推击行走图")
## 角色通用的推击行走图精灵表（武器 shove_walk_texture 和 shove_walk_textures 都为空时回退到这里）
@export var shove_walk_texture: Texture2D
## 每个武器状态名 → 该角色在此武器下的推击行走图精灵表
## 键=weapon_state_name（如 "Pistol"/"Knife"），值=Texture2D
## 若某武器的键不存在，回退到 shove_walk_texture
@export var shove_walk_textures: Dictionary = {}

@export_group("推击疲劳")
## 连续推击多少次后进入冷却（0=禁用疲劳系统）
@export var shove_fatigue_limit: int = 3
## 疲劳冷却时长（秒）
@export var shove_cooldown_duration: float = 2.0
## 停止推击多久后重置疲劳计数（秒）
@export var shove_fatigue_reset_time: float = 3.0

@export_group("选择界面")
## 角色选择界面使用的小头像（如未设置则用 portrait）
@export var select_portrait: Texture2D

@export_group("特效偏移")
## 攻击特效偏移（按武器 × 方向）。键=weapon_state_name（如 "Pistol"/"Shotgun"），值=WeaponEffectOffsets 资源。
## 某武器在此字典中没有条目时，回退到 WeaponData.attack_effect_offset_override。
@export var attack_effect_offsets: Dictionary = {}

@export_group("音效")
@export var hurt_sound: AudioStream = null   ## 受伤音效
@export var death_sound: AudioStream = null  ## 死亡音效

@export_group("安全屋台词")
## 到达安全屋后的随机台词。章节总结会显示当前操作角色的一句。
@export var safehouse_lines: Array[String] = []

@export_group("技能")
## 角色拥有的技能列表（SkillData 资源）
@export var skills: Array[SkillData] = []

# ═══════════════════════════════════════
# 运行时 HP（不保存到 .tres，由存档系统管理）
# ═══════════════════════════════════════
var current_hp: float = 0.0
var current_tp: int = 0


## 初始化运行时 HP 为最大 HP
func init_runtime_hp() -> void:
	current_hp = float(get_effective_max_hp())


## 初始化运行时 TP 为最大 TP
func init_runtime_tp() -> void:
	current_tp = get_effective_max_tp()


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


func get_effective_max_tp() -> int:
	return max_tp


## 获取该角色的武器行走图纹理
## weapon_state_name: WeaponData.weapon_state_name（如 "Pistol"/"Knife"/"Rifle"）
## 返回 Texture2D 或 null（null 表示回退到 WeaponData 的 weapon_walk_texture）
func get_weapon_walk_texture(weapon_state_name: String) -> Texture2D:
	if weapon_walk_textures.has(weapon_state_name):
		return weapon_walk_textures[weapon_state_name] as Texture2D
	return null


## 获取该角色的推击行走图纹理（按武器状态名查找，回退到通用推击图）
func get_shove_walk_texture(weapon_state_name: String) -> Texture2D:
	if shove_walk_textures.has(weapon_state_name):
		return shove_walk_textures[weapon_state_name] as Texture2D
	return shove_walk_texture


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


## 获取指定武器 + 朝向的攻击特效偏移。
## 角色字典有此武器 → 从 WeaponEffectOffsets 按朝向取值；否则返回 fallback。
func get_attack_effect_offset(weapon_state_name: String, facing: int, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if attack_effect_offsets.has(weapon_state_name):
		var off: WeaponEffectOffsets = attack_effect_offsets[weapon_state_name] as WeaponEffectOffsets
		if off:
			return off.get_offset(facing)
	return fallback
