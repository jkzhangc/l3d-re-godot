class_name WeaponData extends ItemData

## ── 架构定位 ──
## 系统：武器数据 ｜ 层：数据（Resource）
## 联机：ID/路径白名单，禁止远端传 Resource
## 职责：武器配置：伤害/射速/射程、主副槽位、开火模式、装填模式、举枪/攻击/装填/后坐力动画序列、枪声惊动范围。
## 依赖：继承 ItemData；被 BulletData 列表与玩家武器状态读取

## 武器数据 — 继承 ItemData，增加战斗属性和武器动画

enum WeaponSlot { PRIMARY, SECONDARY }  ## PRIMARY=主武器, SECONDARY=副武器
enum ReloadMode { NORMAL = 0, SHOTGUN = 1 }  ## NORMAL=普通装填（一次装满）, SHOTGUN=霰弹枪装填（逐发装填）
enum FireMode { TAP = 0, HOLD = 1 }  ## TAP=点按（按一次打一发）, HOLD=按住连发（自动步枪/冲锋枪）

## 属性（原作说明书 §4.5）：炎=持续燃烧掉血；雷=感电（攻击不能）；氷=冻结（受 1.5 倍伤）；酸=仅大伤害（抗性持有者最少，最泛用）。
## 武器/投掷物带属性时，命中敌人按其抗性表结算（enemy.gd 的 resist_*）。
enum Element { NONE = 0, FIRE = 1, LIGHTNING = 2, ICE = 3, ACID = 4 }


@export_group("战斗属性")
@export var attack_power: int = 10            ## 基础攻击力
@export var attack_speed: float = 1.0         ## 攻击速度倍率
@export var attack_range: float = 48.0        ## 攻击范围（像素）
@export var weapon_sprite: Texture2D          ## 武器在地图上的精灵（攻击判定用）


@export_group("武器动画")
@export var weapon_state_name: String = ""    ## 对应的状态名（如"Pistol"/"Knife"）
@export var weapon_walk_texture: Texture2D    ## 武器举起后的行走图精灵表

## 武器举起/放下动画：角色索引序列
## 举起时正向播放，放下时反向播放
@export var weapon_raise_char_sequence: Array[int] = [1, 2]
## 武器举起/放下动画：每帧持续时间（秒），长度应与 weapon_raise_char_sequence 一致
@export var weapon_raise_frame_durations: Array[float] = [0.12, 0.12]


@export_group("武器类型")
@export var is_ranged: bool = true            ## true=远程, false=近战
@export var weapon_slot: WeaponSlot = WeaponSlot.PRIMARY  ## 主武器/副武器（决定装备到哪个槽位）
@export var critical_rate: float = 0.0        ## 暴击率（0-100，如 100=100% 爆头，50=50% 几率爆头）
@export var critical_damage: float = 2.0      ## 暴击伤害倍率（暴击时最终伤害 = 基础伤害 × 此值，黄色伤害数字）

@export_group("属性与耐久")
## 属性（原作 §4.5）：NONE/FIRE/LIGHTNING/ICE/ACID。命中敌人时按其抗性表附加状态：
## 炎→持续燃烧、雷→感电（攻击不能）、氷→冻结（受 1.5 倍）、酸→无附加（最泛用）。
## 酸与 Heat 攻击还会触发「削り」——削减玩家武器弹药/耐久。
@export var element: Element = Element.NONE
## 最大耐久（近战武器用）。0 = 无耐久概念（原作"无限耐久武器"，免疫削り）。
## 削り攻击命中持械玩家时，近战武器耐久 -削り量，归零武器损坏（卸下）。
@export var max_durability: float = 0.0


@export_group("攻击输入")
@export var fire_mode: int = FireMode.TAP     ## 攻击按键模式：TAP=点按, HOLD=按住连发
@export var post_press_wait_frames: int = 0   ## 按下后等待帧数（攻击完成后多少帧不检测按键。0=立即响应）


@export_group("音效")
@export var attack_sound: AudioStream = null    ## 攻击音效（远程/近战共用）
@export var empty_fire_sound: AudioStream = null  ## 空弹音效（弹夹为空时播放）
@export var raise_sound: AudioStream = null      ## 举起武器音效
@export var lower_sound: AudioStream = null      ## 放下武器音效
@export var hit_sound: AudioStream = null        ## 击中目标音效（子弹/近战命中时播放）
@export var gunshot_range: float = 500.0         ## 枪声传播范围（像素）。0=静音武器（近战），>0=开火时范围内敌人会被惊动
@export var shove_sound: AudioStream = null     ## 推击音效


@export_group("装填/装弹")
@export var reload_mode: int = ReloadMode.NORMAL  ## 装填模式：NORMAL=一次装满, SHOTGUN=逐发装填

## --- 普通装填（NORMAL 模式）---
@export var reload_char_sequence: Array[int] = []        ## 装填动画帧序列（空=使用默认 [3, 4, 3, 2]）
@export var reload_frame_durations: Array[float] = []    ## 装填动画每帧时长（空=默认 0.1s）
@export var reload_sound: AudioStream = preload("res://sound/チャキッ.ogg")  ## 装填音效（2026-09-17 用户指定默认；tres 可逐武器覆盖）

## --- 霰弹枪装填（SHOTGUN 模式）---
@export var shotgun_reload_loop_char_sequence: Array[int] = []     ## 单发装填循环帧序列
@export var shotgun_reload_loop_frame_durations: Array[float] = [] # 循环每帧时长
@export var shotgun_reload_loop_sound: AudioStream = null           ## 单发装填音效
@export var shotgun_reload_end_char_sequence: Array[int] = []      ## 装填结束帧序列（上膛动作）
@export var shotgun_reload_end_frame_durations: Array[float] = []  ## 结束帧每帧时长
@export var shotgun_reload_end_sound: AudioStream = null            ## 装填结束音效（上膛声）

## --- 共用 ---
@export var reload_wait_duration: float = 0.3            ## 装填完成后等待时长（秒）

## 从地图/随机掉落物初次拾取本武器时给予的备弹数量（对应 ammo_item_id 的弹药）。
## 0 = 不给备弹。掉落物上转移来的旧武器备弹（weapon_pickup.pickup_reserve_ammo）优先于本值。
@export var initial_reserve_ammo: int = 0


@export_group("攻击后动画")
## 攻击动画播放完毕后、切回举起状态前的过渡动画帧序列。空则无攻击后动画。
@export var post_attack_char_sequence: Array[int] = []
## 攻击后动画每帧持续时间（秒），空则默认 0.1s
@export var post_attack_frame_durations: Array[float] = []
## 攻击后动画音效
@export var post_attack_sound: AudioStream = null


@export_group("动画特效")
## 向下攻击特效场景（FaceDir.DOWN=0），拖入 anim/ 目录下的 .tscn 文件
@export var attack_effect_anim_down: PackedScene = null
## 向左攻击特效场景（FaceDir.LEFT=1）
@export var attack_effect_anim_left: PackedScene = null
## 向右攻击特效场景（FaceDir.RIGHT=2）
@export var attack_effect_anim_right: PackedScene = null
## 向上攻击特效场景（FaceDir.UP=3）
@export var attack_effect_anim_up: PackedScene = null
## 攻击特效是否跟随角色实体移动（开启后特效每帧跟随角色位置）
@export var attack_effect_follow: bool = false
## 攻击特效位置偏移覆盖（非零时替换 .tscn 内置的 position_offset）
@export var attack_effect_offset_override: Vector2 = Vector2.ZERO
## 击中目标时的特效场景，拖入 anim/ 目录下的 .tscn 文件
@export var hit_effect_anim: PackedScene = null
## 命中特效是否跟随目标实体移动（开启后特效每帧跟随目标位置）
@export var hit_effect_follow: bool = false
## 命中特效位置偏移覆盖（非零时替换 .tscn 内置的 position_offset）
@export var hit_effect_offset_override: Vector2 = Vector2.ZERO

@export_group("子弹发射点（按角色 × 方向）")
## 每个角色的枪口额外偏移。键 = CharacterData.character_id（如 "nobita"；留空回退 tres 文件名），
## 值 = WeaponEffectOffsets（四方向 Vector2）。
## 最终生成点 = 角色位置 + 朝向 × BulletData.spawn_offset + 本偏移。
## **配置了条目的角色，其偏移替换 BulletData 的 offset_down/up/left/right**；
## 未配置的角色完全沿用旧行为（逐子弹的 offset_*），因此留空字典 = 无行为变化。
## 何时需要：同一把枪在不同角色手里，枪口像素位置不同（行走图各异），
## 贴脸射击时会有"子弹从身体里冒出来"的观感 —— 用本表按角色/朝向精修。
@export var bullet_spawn_offsets: Dictionary = {}


## 该角色是否配置了枪口偏移条目（键存在且值为 WeaponEffectOffsets）。
## 配置判定与「值是否为零」解耦：显式 (0,0) = 角色中心线，不再触发回退。
func has_bullet_spawn_offset(cd: CharacterData) -> bool:
	if cd == null or bullet_spawn_offsets.is_empty():
		return false
	var key: String = cd.get_character_key()
	if key.is_empty() or not bullet_spawn_offsets.has(key):
		return false
	return bullet_spawn_offsets[key] is WeaponEffectOffsets


## 取某角色在该武器下的枪口额外偏移（四方向）。
## 无条目 / 空键 / 值类型不对 → 返回 Vector2.ZERO，调用方回退 BulletData 的逐方向偏移。
## ⚠ 判定"是否配置"请用 has_bullet_spawn_offset（零值是合法配置，≠未配置）。
func get_bullet_spawn_offset(cd: CharacterData, facing: int) -> Vector2:
	if cd == null or bullet_spawn_offsets.is_empty():
		return Vector2.ZERO
	var key: String = cd.get_character_key()
	if key.is_empty() or not bullet_spawn_offsets.has(key):
		return Vector2.ZERO
	var offs: WeaponEffectOffsets = bullet_spawn_offsets[key] as WeaponEffectOffsets
	if offs == null:
		return Vector2.ZERO
	return offs.get_offset(facing)


@export_group("攻击特效位置（按角色 × 方向）")
## 每个角色的攻击特效额外偏移。键 = CharacterData.character_id（如 "nobita"；留空回退 tres 文件名），
## 值 = WeaponEffectOffsets（四方向 Vector2）。与 bullet_spawn_offsets 完全同构。
##
## **配置了条目的角色 → 该角色拿这把武器时的特效位置用本偏移**；未配置 → 回退
## attack_effect_offset_override（武器级兜底，默认 (0,0) = 特效 .tscn 内置位置）。
## 何时需要：同一把枪在不同角色手里，行走图枪口像素位置不同，攻击特效会偏。
##
## 2026-09-23 用户定稿：原先在 CharacterData.attack_effect_offsets（键为武器 state 名），
## 现全部迁到武器数据（键为角色 id），与子弹偏移统一「以后都在武器数据里设置」。
@export var attack_effect_offsets: Dictionary = {}


## 该角色是否配置了特效偏移条目（键存在且值为 WeaponEffectOffsets）。
## 判定与「值是否为零」解耦：显式 (0,0) = 无额外偏移，不再触发回退。
func has_attack_effect_offset(cd: CharacterData) -> bool:
	if cd == null or attack_effect_offsets.is_empty():
		return false
	var key: String = cd.get_character_key()
	if key.is_empty() or not attack_effect_offsets.has(key):
		return false
	return attack_effect_offsets[key] is WeaponEffectOffsets


## 取某角色在该武器下的攻击特效偏移（按朝向）。无条目 / 值类型不对 → 返回 fallback，
## 调用方传 attack_effect_offset_override（武器级兜底）。
func get_attack_effect_offset(cd: CharacterData, facing: int, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if cd == null or attack_effect_offsets.is_empty():
		return fallback
	var key: String = cd.get_character_key()
	if key.is_empty() or not attack_effect_offsets.has(key):
		return fallback
	var offs: WeaponEffectOffsets = attack_effect_offsets[key] as WeaponEffectOffsets
	if offs == null:
		return fallback
	return offs.get_offset(facing)


@export_group("远程攻击")
@export var magazine_capacity: int = 0        ## 弹夹容量（0=无需弹药/近战武器）
@export var ammo_item_id: String = ""         ## 对应弹药 ItemData.item_id
@export var ammo_is_infinite: bool = false     ## true=此武器的备弹无限；弹夹仍会耗尽，耗尽后仍需换弹
## 攻击动画：角色索引序列（在 weapon_walk_texture 上的 char_idx）
@export var attack_char_sequence: Array[int] = [3, 4, 3, 2]
## 攻击动画每帧持续时间（秒），长度应与 attack_char_sequence 一致
@export var attack_frame_durations: Array[float] = []
@export var fire_at_sequence_idx: int = 1     ## 在此序列索引发射子弹（远程）
## 每次攻击发射的子弹列表。每颗子弹可独立配置外观、弹道、角度/方向、偏移。
@export var bullet_list: Array[BulletData] = []


@export_group("硬直")
## 命中后敌人硬直时长（秒），无击退位移的原地冻结。0=无硬直
@export var hitstun_duration: float = 0.0


@export_group("近战攻击")
## 近战攻击动画：角色索引序列。为空则回退到 attack_char_sequence
@export var melee_attack_char_sequence: Array[int] = []
## 近战攻击动画每帧持续时间（秒）。为空则回退到 attack_frame_durations
@export var melee_attack_frame_durations: Array[float] = []
@export var melee_range_size: Vector2 = Vector2(48, 32)  ## 近战判定矩形（宽×高）
@export var melee_range_forward_offset: float = 24.0      ## 以角色方向为准的前方偏移量
@export var melee_hit_at_sequence_idx: int = 1  ## 在此序列索引创建近战判定区域


@export_group("近战推击")
## 推击动画：角色索引序列（在推击行走图上的 char_idx）
@export var shove_char_sequence: Array[int] = [0, 1, 1]
## 推击动画每帧持续时间（秒）。所有帧统一时长（与踏步动画模式相同）
@export var shove_frame_duration: float = 0.05
## 推击行走图精灵表。空→回退 CharacterData.shove_walk_texture → 回退 weapon_walk_texture
@export var shove_walk_texture: Texture2D
## 推击判定矩形（宽×高）
@export var shove_range_size: Vector2 = Vector2(48, 32)
## 推击判定前方偏移量（以角色方向为准）
@export var shove_range_forward_offset: float = 24.0
## 在此序列索引创建推击判定区域
@export var shove_hit_at_sequence_idx: int = 1
## 推击击退力度（像素/秒，作为初始推力速度）
@export var shove_knockback_force: float = 300.0
## 推击击退/硬直时长（秒）
@export var shove_knockback_duration: float = 2.0
## 推击溅射半径（像素）。推中敌人时，此范围内的其他敌人也会被击退。0=仅命中目标
@export var shove_splash_radius: float = 64.0


func _init() -> void:
	item_type = ItemType.WEAPON


## 获取槽位键名（用于 PlayerState.equipment 字典查找）
func get_slot_key() -> String:
	return "primary" if weapon_slot == WeaponSlot.PRIMARY else "secondary"


## 获取武器基础伤害
func get_effective_damage() -> float:
	return float(attack_power)


func has_infinite_ammo() -> bool:
	return ammo_is_infinite


## 获取举起动画每帧持续时间（秒）
func get_raise_frame_duration(seq_idx: int) -> float:
	if weapon_raise_frame_durations.size() > seq_idx:
		return weapon_raise_frame_durations[seq_idx]
	return 0.12


## 获取攻击动画每帧持续时间（秒）
func get_attack_frame_duration(seq_idx: int) -> float:
	if attack_frame_durations.size() > seq_idx:
		return attack_frame_durations[seq_idx]
	return 0.1


## 获取举起动画的角色序列
func get_raise_char_sequence() -> Array[int]:
	if weapon_raise_char_sequence.size() > 0:
		return weapon_raise_char_sequence
	return [1, 2]


## 根据朝向获取攻击特效场景
## facing: FaceDir 枚举值（DOWN=0, LEFT=1, RIGHT=2, UP=3）
func get_attack_effect_anim(facing: int) -> PackedScene:
	var dir_anims: Array[PackedScene] = [
		attack_effect_anim_down,
		attack_effect_anim_left,
		attack_effect_anim_right,
		attack_effect_anim_up,
	]
	if facing >= 0 and facing < dir_anims.size():
		return dir_anims[facing]
	return null


## 获取近战攻击动画的角色序列（优先近战字段，空则回退远程字段）
func get_melee_attack_char_sequence() -> Array[int]:
	if melee_attack_char_sequence.size() > 0:
		return melee_attack_char_sequence
	return attack_char_sequence


## 获取近战攻击动画每帧持续时间（优先近战字段，空则回退远程字段）
func get_melee_attack_frame_duration(seq_idx: int) -> float:
	if melee_attack_frame_durations.size() > seq_idx:
		return melee_attack_frame_durations[seq_idx]
	return get_attack_frame_duration(seq_idx)


## 获取推击动画的角色序列
func get_shove_char_sequence() -> Array[int]:
	if shove_char_sequence.size() > 0:
		return shove_char_sequence
	return [3, 2]


## 获取装填动画每帧持续时间（秒）
func get_reload_frame_duration(seq_idx: int) -> float:
	if reload_frame_durations.size() > seq_idx:
		return reload_frame_durations[seq_idx]
	return 0.1


## 获取霰弹枪装填循环每帧持续时间（秒）
func get_shotgun_loop_frame_duration(seq_idx: int) -> float:
	if shotgun_reload_loop_frame_durations.size() > seq_idx:
		return shotgun_reload_loop_frame_durations[seq_idx]
	return 0.1


## 获取霰弹枪装填结束每帧持续时间（秒）
func get_shotgun_end_frame_duration(seq_idx: int) -> float:
	if shotgun_reload_end_frame_durations.size() > seq_idx:
		return shotgun_reload_end_frame_durations[seq_idx]
	return 0.1


## 获取装填动画帧序列（NORMAL 模式，空则返回默认序列）
func get_reload_char_sequence() -> Array[int]:
	if reload_char_sequence.size() > 0:
		return reload_char_sequence
	return [3, 4, 3, 2]


## 获取霰弹枪装填循环帧序列（空则返回默认序列）
func get_shotgun_loop_char_sequence() -> Array[int]:
	if shotgun_reload_loop_char_sequence.size() > 0:
		return shotgun_reload_loop_char_sequence
	return [3, 4, 3, 2]


## 获取霰弹枪装填结束帧序列（空则返回默认序列）
func get_shotgun_end_char_sequence() -> Array[int]:
	if shotgun_reload_end_char_sequence.size() > 0:
		return shotgun_reload_end_char_sequence
	return [3, 4, 3, 2]


## 获取攻击后动画帧序列（空则跳过攻击后动画）
func get_post_attack_char_sequence() -> Array[int]:
	return post_attack_char_sequence


## 获取攻击后动画每帧持续时间（秒）
func get_post_attack_frame_duration(seq_idx: int) -> float:
	if post_attack_frame_durations.size() > seq_idx:
		return post_attack_frame_durations[seq_idx]
	return 0.1
