class_name BulletData extends Resource

## ── 架构定位 ──
## 系统：子弹数据 ｜ 层：数据（Resource）
## 联机：纯本机配置
## 职责：单颗子弹配置：外观分帧、弹道（速度/射程/穿透）、方向覆盖与逐朝向额外偏移、击退与硬直参数。
## 依赖：由 WeaponData.bullet_list 引用

## 子弹数据 — 封装单颗子弹的全部配置
##
## 由 WeaponData.bullet_list 引用，每次攻击遍历 bullet_list 发射所有子弹。
## 每颗子弹可独立设置外观、弹道、角度/方向、按朝向的额外偏移。


# ═══════════════════════════════════════
# 外观
# ═══════════════════════════════════════
@export_group("外观")
@export var bullet_texture: Texture2D         ## 子弹精灵图（水平帧条，单帧宽=图宽/动画帧数）
@export var bullet_anim_frames: int = 1       ## 子弹动画帧数（水平排列的总帧数）
@export var bullet_frame_duration: int = 1    ## 每帧持续的物理帧数（>1 = 慢动作，1 = 每物理帧切帧）


# ═══════════════════════════════════════
# 弹道
# ═══════════════════════════════════════
@export_group("弹道")
@export var speed: float = 300.0              ## 子弹飞行速度
@export var max_range: float = 300.0          ## 最大飞行距离（像素）
@export var damage: float = 0.0               ## 子弹伤害（0=使用武器 attack_power）
@export var destroy_on_hit: bool = true       ## 击中后是否消失
@export var penetration: int = 0              ## 穿透数（0=单目标）
@export var spawn_offset: float = 24.0        ## 子弹生成位置的前方偏移（像素）


# ═══════════════════════════════════════
# 方向控制
# ═══════════════════════════════════════
@export_group("方向控制")
## 相对角色朝向的旋转角度（度）。正=顺时针，负=逆时针。
## 例：angle_offset=0 直射，±15° 实现霰弹散射。
@export var angle_offset: float = 0.0
## 绝对方向覆盖（非零时忽略角色朝向和 angle_offset，使用此方向）。
## 例：(0,-1) = 固定朝上发射。
@export var direction_override: Vector2 = Vector2.ZERO


# ═══════════════════════════════════════
# 按方向额外偏移
# ═══════════════════════════════════════
@export_group("方向额外偏移")
@export var offset_down: Vector2 = Vector2.ZERO
@export var offset_up: Vector2 = Vector2.ZERO
@export var offset_left: Vector2 = Vector2(0, -4)
@export var offset_right: Vector2 = Vector2(0, -4)


# ═══════════════════════════════════════
# 即死 / 爆炸
# ═══════════════════════════════════════
@export_group("即死/爆炸")
## 即死効果（原作マグナム/スナイパー系）。命中普通敌人直接拉满伤害即死；
## tank_enemies 组 Boss 免疫即死 → 伤害 ×1.5 + 0.8s 怯み（与覚醒集中射撃同一结算）。
@export var instant_kill: bool = false
## 爆炸半径（像素）。0=普通子弹；>0=命中/到射程/撞墙时在原地爆炸，
## 对半径内敌人造成伤害（超プッシュ按击退参数），并引爆 blast_wall。
## 爆炸模式下不再对直击目标单独结算（伤害由爆炸统一给，避免双倍）。
@export var explosion_radius: float = 0.0
## 爆炸是否波及玩家（原作爆発物「自爆あり」）。M79 炸裂弾=true，Denel-MGL 可关。
@export var explosion_hurts_players: bool = true
## 能否炸开可爆破墙（BlastWall）。默认 false —— 只有显式配置 true 的爆炸源（炸药）
## 才能破坏墙体；火箭筒/榴弹炮等就算炸得再响也炸不开（2026-09-16 用户定稿）。
@export var breaks_blast_wall: bool = false
## 对玩家的自爆半径（像素，2026-09-15）。0 = 同 explosion_radius；
## >0 用更小半径——爆风对敌人范围大、自爆只惩罚贴脸开火（榴弹炮/火箭筒=96，3 格）。
@export var explosion_player_radius: float = 0.0
## 爆炸特效场景（如 anim/anim_effect_爆炸动画.tscn）
@export var explode_effect_anim: PackedScene = null
## 爆炸音效
@export var explode_sound: AudioStream = null


# ═══════════════════════════════════════
# 击退
# ═══════════════════════════════════════
@export_group("击退")
## 是否启用击退效果（子弹命中时将敌人推入击退/硬直状态）
@export var knockback_enabled: bool = false
## 击退力度（像素/秒）。实际表现为初始推力速度
@export var knockback_force: float = 200.0
## 击退后硬直时长（秒）。硬直结束后自动切回追击状态
@export var knockback_stun_duration: float = 0.5
## 命中后硬直时长（秒），无击退位移的原地冻结。0=无硬直
@export var hitstun_duration: float = 0.0

# ═══════════════════════════════════════
# 碰撞体
# ═══════════════════════════════════════
@export_group("碰撞体")
## 碰撞矩形尺寸（0=使用默认值 24×28）
@export var collision_size: Vector2 = Vector2.ZERO
## 碰撞体相对子弹根节点的偏移
@export var collision_offset: Vector2 = Vector2.ZERO


# ═══════════════════════════════════════
# 方法
# ═══════════════════════════════════════

## 弹丸 setup 参数字典的**唯一构建入口**：键与 bullet.gd::setup() 逐项对应。
##
## 单机（PlayerPistolAttackState._fire_bullet）与联机 Host（NetworkWorld._spawn_host_bullet）
## 必须共用本函数 —— 2026-09-24 用户实测「联机里弓弩射出来不爆炸，榴弹炮/RPG 同样」
## 的根因就是 Host 侧手写字典漏了 explosion_radius / explosion_hurts_players /
## explosion_player_radius / breaks_blast_wall / explode_effect_anim / explode_sound：
## 数据层配置齐全，Host 权威弹却一颗都不炸（既不结算范围伤害也无爆炸特效/音效）。
##
## 调用方只需再补身份字段：direction / shooter /（联机）network_entity_id /
## network_visual_only。damage 与 instant_kill 由调用方按「覚醒倍率 / 数据即死」算好传入。
func build_setup_params(wd: WeaponData, damage: float, instant_kill: bool) -> Dictionary:
	return {
		"speed": speed,
		"max_range": max_range,
		"damage": damage,
		"destroy_on_hit": destroy_on_hit,
		"penetration": penetration,
		"critical_rate": wd.critical_rate if wd else 0.0,
		"critical_damage": wd.critical_damage if wd else 2.0,
		"element": wd.element if wd else 0,
		"instant_kill": instant_kill,
		# 爆炸家族（弓弩/榴弹发射器/火箭筒/属性榴弹共用）
		"explosion_radius": explosion_radius,
		"explosion_hurts_players": explosion_hurts_players,
		"explosion_player_radius": explosion_player_radius,
		"breaks_blast_wall": breaks_blast_wall,
		"explode_effect_anim": explode_effect_anim,
		"explode_sound": explode_sound,
		# 命中表现
		"hit_effect_anim": wd.hit_effect_anim if wd else null,
		"hit_effect_follow": wd.hit_effect_follow if wd else false,
		"hit_effect_offset_override": wd.hit_effect_offset_override if wd else Vector2.ZERO,
		"hit_sound": wd.hit_sound if wd else null,
		# 外观与碰撞
		"texture": bullet_texture,
		"anim_frames": bullet_anim_frames,
		"frame_duration": bullet_frame_duration,
		"collision_size": collision_size,
		"collision_offset": collision_offset,
		"spawn_offset": spawn_offset,
		# 击退/硬直
		"knockback_force": knockback_force if knockback_enabled else 0.0,
		"knockback_stun": knockback_stun_duration if knockback_enabled else 0.0,
		"hitstun_duration": hitstun_duration if hitstun_duration > 0.0 else (wd.hitstun_duration if wd else 0.0),
	}


## 获取有效伤害（子弹伤害优先，否则用武器攻击力）
func get_effective_damage(attack_power: float) -> float:
	return damage if damage > 0.0 else attack_power


## 根据角色朝向获取子弹的额外偏移
func get_extra_offset(facing: int) -> Vector2:
	match facing:
		0: return offset_down    ## FaceDir.DOWN
		1: return offset_left    ## FaceDir.LEFT
		2: return offset_right   ## FaceDir.RIGHT
		3: return offset_up      ## FaceDir.UP
	return Vector2.ZERO


## 计算最终发射方向
## - direction_override 非零 → 使用绝对方向（忽略 base_dir 和 angle_offset）
## - angle_offset 非零 → base_dir 旋转 angle_offset 度
## - 否则 → 直接返回 base_dir
func get_fire_direction(base_dir: Vector2) -> Vector2:
	if direction_override != Vector2.ZERO:
		return direction_override.normalized()
	if angle_offset != 0.0:
		return base_dir.rotated(deg_to_rad(angle_offset))
	return base_dir
