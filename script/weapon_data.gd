class_name WeaponData extends ItemData
## 武器数据 — 继承 ItemData，增加战斗属性和武器动画

enum WeaponSlot { PRIMARY, SECONDARY }  ## PRIMARY=主武器, SECONDARY=副武器
enum ReloadMode { NORMAL = 0, SHOTGUN = 1 }  ## NORMAL=普通装填（一次装满）, SHOTGUN=霰弹枪装填（逐发装填）
enum FireMode { TAP = 0, HOLD = 1 }  ## TAP=点按（按一次打一发）, HOLD=按住连发（自动步枪/冲锋枪）


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


@export_group("攻击输入")
@export var fire_mode: int = FireMode.TAP     ## 攻击按键模式：TAP=点按, HOLD=按住连发
@export var post_press_wait_frames: int = 0   ## 按下后等待帧数（攻击完成后多少帧不检测按键。0=立即响应）


@export_group("地面显示")
## 武器掉落在地面时的精灵表（用于生成 WeaponPickup）
@export var pickup_texture: Texture2D
## 精灵表中的角色索引
@export var pickup_char_idx: int = 0
## 朝向（0=下, 1=左, 2=右, 3=上）
@export var pickup_direction: int = 0
## 地面踏步帧序列（空=使用 WeaponPickup 默认序列 [1, 0, 1, 2]）
@export var pickup_step_frames: Array[int] = []
## 地面踏步每帧持续时间，秒（0=使用默认 0.25s）
@export var pickup_step_duration: float = 0.0
## 地面是否启用踏步动画
@export var pickup_animated: bool = true


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
@export var reload_sound: AudioStream = null              ## 装填音效

## --- 霰弹枪装填（SHOTGUN 模式）---
@export var shotgun_reload_loop_char_sequence: Array[int] = []     ## 单发装填循环帧序列
@export var shotgun_reload_loop_frame_durations: Array[float] = [] # 循环每帧时长
@export var shotgun_reload_loop_sound: AudioStream = null           ## 单发装填音效
@export var shotgun_reload_end_char_sequence: Array[int] = []      ## 装填结束帧序列（上膛动作）
@export var shotgun_reload_end_frame_durations: Array[float] = []  ## 结束帧每帧时长
@export var shotgun_reload_end_sound: AudioStream = null            ## 装填结束音效（上膛声）

## --- 共用 ---
@export var reload_wait_duration: float = 0.3            ## 装填完成后等待时长（秒）


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


@export_group("远程攻击")
@export var magazine_capacity: int = 0        ## 弹夹容量（0=无需弹药/近战武器）
@export var ammo_item_id: String = ""         ## 对应弹药 ItemData.item_id
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
@export var shove_char_sequence: Array[int] = [3, 2]
## 推击动画每帧持续时间（秒）。所有帧统一时长（与踏步动画模式相同）
@export var shove_frame_duration: float = 0.1
## 推击行走图精灵表。空→回退 CharacterData.shove_walk_texture → 回退 weapon_walk_texture
@export var shove_walk_texture: Texture2D
## 推击判定矩形（宽×高）
@export var shove_range_size: Vector2 = Vector2(48, 32)
## 推击判定前方偏移量（以角色方向为准）
@export var shove_range_forward_offset: float = 24.0
## 在此序列索引创建推击判定区域
@export var shove_hit_at_sequence_idx: int = 1
## 推击击退力度（像素/秒，作为初始推力速度）
@export var shove_knockback_force: float = 400.0
## 推击击退/硬直时长（秒），默认 5 秒
@export var shove_knockback_duration: float = 5.0


func _init() -> void:
	item_type = ItemType.WEAPON


## 获取槽位键名（用于 Global.equipment 字典查找）
func get_slot_key() -> String:
	return "primary" if weapon_slot == WeaponSlot.PRIMARY else "secondary"


## 获取武器基础伤害
func get_effective_damage() -> float:
	return float(attack_power)


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
