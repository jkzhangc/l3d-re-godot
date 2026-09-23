class_name CharacterData extends Resource

## ── 架构定位 ──
## 系统：角色数据 ｜ 层：数据（Resource）
## 联机：角色表须 Host 校验后广播
## 职责：角色配置：基础属性与成长率、初始装备、行走/跑步/死亡精灵表、逐武器行走图、武器槽限制、枪口与特效偏移。
## 依赖：被 Player、CharacterCatalog、玩家状态读取

## 角色参数数据 — 可在检查器中可视化编辑

@export_group("基础属性")
@export var character_name: String = "のび太"
## 稳定数据键（如 "nobita"）。武器侧的「按角色子弹发射点偏移」等按角色配置的数据用它做键；
## 留空则回退 tres 文件名（character_nobita.tres → nobita）。
@export var character_id: String = ""
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

@export_group("初始装备")
## 角色出生自带的主武器。未配置时 PlayerState 统一发放手枪，
## 保证单机与联机每个角色出场都有一把可举起的武器。
@export var initial_weapon: WeaponData = null

@export_group("成长率")
@export var hp_growth: int = 10
@export var mp_growth: int = 5
@export var atk_growth: int = 3
@export var def_growth: int = 2

@export_group("外观")
@export var portrait: Texture2D              ## 角色立绘/头像
@export var walk_texture: Texture2D          ## 行走图精灵表
@export var walk_char_index: int = 0         ## 行走图角色索引
## 步行动画帧时长（秒）。0 = 按全局基准与 walk_speed 自动算（2026-09-15：
## duration = 0.18 × 150 / walk_speed，默认即 0.18）；>0 = 手动固定。
@export var walk_frame_duration: float = 0.0
@export var run_texture: Texture2D           ## 跑步图精灵表
@export var run_char_index: int = 1          ## 跑步图角色索引
## 跑步动画帧时长（秒）。0 = 按全局基准与 run_speed 自动算（默认 250 速 → 0.108s）；>0 = 手动固定。
@export var run_frame_duration: float = 0.0
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
## 选择界面图标行走图（未设置时界面回退到默认图标表）
@export var select_icon_sheet: Texture2D
## 图标行走图中的角色索引（横向第几组三帧，0~3）
@export var select_icon_index: int = 0
## 图标行走图的朝向行（0=下 1=左 2=右 3=上；这张表不同朝向行指向不同角色）
@export var select_icon_direction: int = 0

@export_group("音效")
@export var hurt_sound: AudioStream = null   ## 受伤音效
@export var death_sound: AudioStream = null  ## 死亡音效

@export_group("安全屋台词")
## 到达安全屋后的随机台词。章节总结会显示当前操作角色的一句。
@export var safehouse_lines: Array[String] = []

@export_group("技能")
## 角色拥有的技能列表（SkillData 资源）。SA 主动技 = command_trigger 填 "SA键" 的条目。
@export var skills: Array[SkillData] = []

@export_group("说明书设定（L3D 原作 §6）")
## 反击类型：见切成功后触发的反击招式（原作每角色专属）。
## punch=拳打（のび太/スネ夫）、heavy=强打（ジャイアン/聖奈）、issen=一闪·超Push+即死（静香/出木杉/健治）。
## 见切/反击系统尚未实装，此字段先作为角色设定数据保存。
@export_enum("none", "punch", "heavy", "issen") var counter_type: String = "none"
## 反击音效（见切成功触发反击时播放，如 静香_カウンター１）。留空=不播放。
@export var counter_sound: AudioStream = null

@export_group("见切动画（见切成功时播放，配置方式同举枪动画）")
## 见切时切换到的行走图精灵表（576×512 同布局；空 = 回退推击图/反撃套）。
@export var mukiri_walk_texture: Texture2D
## 见切动画的角色索引序列（char_idx，图上第几组姿态；空=不播动画）。
@export var mukiri_char_sequence: Array[int] = []
## 每帧持续时间（秒）；条目不足时用默认 0.08。
@export var mukiri_frame_durations: Array[float] = []
## 看护：自己使用治疗品时，全队玩家同时回复相同 HP。
@export var nursing: bool = false
## スプレー+1：急救喷雾携带上限 +1 并开局自带一瓶（喷雾库存系统接入后生效）。
@export var spray_plus_one: bool = false
## コマンドー：机枪/散弹/马格南攻击后无硬直（跳过攻击后动画）。
@export var commando: bool = false
## デモリション：投掷爆炸类无发射硬直（投掷状态接入后生效）。
@export var demolition: bool = false
## 怪力（かいりき）：近战武器攻击后无硬直（跳过攻击后动画）。
@export var kairiki: bool = false

## ── 覚醒コマンド（原作：構え中 Z+X）──
## 觉醒类型。none = 该角色没有觉醒（原作我方四人只有のび太有）。
## concentrated_fire = 集中射撃（のび太）：发动中 TP 缓慢消耗，射击威力上升，
## 子弹附带即死・怯み（对 tank_enemies 组 Boss 无效 → 伤害 ×1.5 + 怯み）。
@export_enum("none", "concentrated_fire") var awaken_type: String = "none"

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


## 稳定数据键：优先 character_id，留空回退 tres 文件名（character_nobita.tres → nobita）。
## 供「按角色」配置的资源做字典键（如 WeaponData.bullet_spawn_offsets / attack_effect_offsets）。
func get_character_key() -> String:
	if not character_id.is_empty():
		return character_id
	if resource_path and not resource_path.is_empty():
		return resource_path.get_file().get_basename()
	return character_name
