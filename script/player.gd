extends CharacterBody2D
## 玩家角色 — CharacterBody2D + 状态机
##
## 状态机负责：移动输入、状态切换、物理速度
## 本脚本负责：精灵表/动画、外观更新、对外接口
##
## 状态列表：
##   Idle  → 站立不动
##   Walk  → 行走（按住 Ctrl）
##   Run   → 跑步（默认）
##   Pistol / Knife → 武器举起状态
##   PistolAttack / KnifeAttack → 攻击状态
##
## VX Ace 角色精灵布局（576×512, 4×2共8角色, 每角色3帧×4方向）

# ═══════════════════════════════════════
# 角色参数（行走图/HP/音效 → 由 CharacterData 驱动）
# ═══════════════════════════════════════
@export var current_character: CharacterData  ## 当前角色参数资源
## 以下变量由 _apply_character_data() 从 CharacterData 读取，不再 @export
var walk_texture: Texture2D = null
var walk_char_index: int = 0
var walk_frame_duration: float = 0.18
var run_texture: Texture2D = null
var run_char_index: int = 1
var run_frame_duration: float = 0.10
var max_hp: float = 200.0
var death_texture: Texture2D = null
var death_char_index: int = 6
var hurt_sound: AudioStream = null
var death_sound: AudioStream = null

# ═══════════════════════════════════════
# 移动参数
# ═══════════════════════════════════════
@export var walk_speed: float = 150.0
@export var run_speed: float = 250.0

# ═══════════════════════════════════════
# 战斗参数
# ═══════════════════════════════════════
@export_group("受击碰撞体")
@export var hurtbox_size: Vector2 = Vector2(28, 44)  ## 受击碰撞体尺寸
@export var hurtbox_offset: Vector2 = Vector2(0, -8)  ## 受击碰撞体偏移（相对角色原点）

@export_group("受击反馈")
## 受击反馈模式：0=闪（瞬间变色→逐渐恢复），1=渐隐（变色→渐渐消失）
@export var hit_feedback_mode: int = 0
## 受击反馈持续时间（秒）
@export var hit_feedback_duration: float = 0.5

# ═══════════════════════════════════════
# 死亡（黑屏时长参数见 Global 单例：death_fade_duration / death_black_hold）
# ═══════════════════════════════════════

# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48   ## 576 / 12
const FRAME_H: int = 64   ## 512 / 8
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

## VX Ace 帧序列: frame1 → frame0 → frame1 → frame2 → frame1（循环）
const WALK_SEQUENCE: Array[int] = [1, 0, 1, 2]
const STAND_FRAME: int = 1

## 方向 → 行偏移（VX Ace: 下/左/右/上）
const DIR_ROWS: Array[int] = [0, 1, 2, 3]
const DAMAGE_SOURCE_COOLDOWN_MSEC: int = 1000  ## 同一伤害源重复命中冷却（毫秒）

enum FaceDir { DOWN = 0, LEFT = 1, RIGHT = 2, UP = 3 }

# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════
@onready var sprite: Sprite2D = $Sprite2D
@onready var animation_timer: Timer = $AnimationTimer
@onready var hurt_area: Area2D = _setup_hurt_area()

# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var _facing: int = FaceDir.DOWN
var _facing_locked: bool = false
var _locked_facing: int = FaceDir.DOWN
var _anim_step: int = 0
var _moving: bool = false
var _is_walking: bool = false   ## 当前外观是行走(true)还是跑步(false)
var _weapon_mode: bool = false  ## 是否处于武器举起模式
var _weapon_data: WeaponData = null
var _current_weapon_char_idx: int = 0  ## 当前武器模式下使用的角色索引
var player_in_weapon_state: bool = false  ## 供 menu_controller 检查菜单屏蔽
var _throwable_mode: bool = false           ## 是否处于投掷物举起模式（使用投掷物行走图）
var _throwable_texture: Texture2D = null    ## 投掷物举起行走图精灵表
var _throwable_char_idx: int = 0            ## 投掷物举起行走图角色索引
var _near_pickup: bool = false            ## 玩家是否在武器拾取物范围内（由 weapon_pickup 设置）
var _switch_on_death_attempted: bool = false  ## 是否已尝试死亡切换
var current_hp: float = 200.0
var _tp_regen_timer: float = 0.0

## 搓招方向输入缓冲
const MOTION_DIRS: Array[String] = ["上", "下", "左", "右"]
const MOTION_BUFFER_MAX: int = 8
var _motion_buffer: Array[String] = []

## 推击相关
var _shove_mode: bool = false           ## 是否处于推击模式（使用推击行走图）
var _shove_texture: Texture2D = null    ## 当前推击行走图（角色优先，回退武器）

## 推击疲劳（L4D2 风格：连续推击 N 次→冷却 2 秒）
var _shove_fatigue_count: int = 0       ## 连续推击计数
var _shove_cooldown_timer: float = 0.0  ## 冷却倒计时（>0=冷却中）
var _shove_idle_timer: float = 0.0      ## 自上次推击以来的空闲时间

## 死亡相关
var _is_dying: bool = false
var _recent_damage_sources: Dictionary = {}    ## source_id → hit_time_msec（防同一源头重复判定）
var _death_fade_timer: float = 0.0
var _death_phase: int = 0  ## 0=死亡动画, 1=渐黑, 2=全黑等待, 3=重载
var _death_fade_overlay: ColorRect = null

## 暴露朝向（供攻击状态计算子弹方向和近战偏移）
var facing: int:
	get:
		return _facing


func _ready() -> void:
	add_to_group("player")
	# 从 CharacterData 资源读取外观/HP 参数（覆盖本地 @export 默认值）
	_apply_character_data()

	if walk_texture == null:
		walk_texture = load("res://art/Characters/のび太セット.png") as Texture2D
	if run_texture == null:
		run_texture = load("res://art/Characters/のび太歩行セット.png") as Texture2D

	# 俯视角：浮动模式，所有碰撞都是墙壁
	motion_mode = MOTION_MODE_FLOATING

	animation_timer.wait_time = walk_frame_duration
	animation_timer.timeout.connect(_on_animation_timer_timeout)
	animation_timer.start()
	_refresh_sprite()

	# 从 Global 恢复 HP（用于存档加载后）
	if Global.player_hp > 0.0:
		current_hp = Global.player_hp
	else:
		current_hp = max_hp


func _setup_hurt_area() -> Area2D:
	## 创建受击碰撞体（Area2D + RectangleShape2D），位于独立的 hurtbox 层
	var area := Area2D.new()
	area.name = "HurtArea"
	area.collision_layer = 16   ## Layer 5 — hurtbox 层
	area.collision_mask = 0     ## 不需要检测任何东西

	var shape := CollisionShape2D.new()
	shape.name = "HurtShape"
	var rect := RectangleShape2D.new()
	rect.size = hurtbox_size
	shape.shape = rect
	shape.position = hurtbox_offset
	area.add_child(shape)

	add_child(area)
	return area


func _process(delta: float) -> void:
	if _is_dying:
		_process_death(delta)
	_update_shove_fatigue(delta)
	_update_tp_regen(delta)
	_update_motion_input()


func _on_animation_timer_timeout() -> void:
	if _moving:
		_anim_step = (_anim_step + 1) % WALK_SEQUENCE.size()
	_refresh_sprite()


# ═══════════════════════════════════════
# 供 State 调用的公开方法
# ═══════════════════════════════════════

## 更新外观：移动状态 + 行走/跑步模式
func update_appearance(moving: bool, is_walking: bool) -> void:
	var changed: bool = (_moving != moving) or (_is_walking != is_walking)
	_moving = moving
	_is_walking = is_walking

	if changed:
		_anim_step = 0
		if animation_timer:
			animation_timer.wait_time = walk_frame_duration if is_walking else run_frame_duration
			animation_timer.start()   ## 重启 timer，新间隔立即生效

	_refresh_sprite()


## 根据移动方向更新朝向
func update_facing(move_dir: Vector2) -> void:
	if _facing_locked:
		return
	var new_facing: int
	if abs(move_dir.x) > abs(move_dir.y):
		new_facing = FaceDir.RIGHT if move_dir.x > 0 else FaceDir.LEFT
	else:
		new_facing = FaceDir.DOWN if move_dir.y > 0 else FaceDir.UP
	if new_facing != _facing:
		_facing = new_facing
		_refresh_sprite()


# ═══════════════════════════════════════
# 武器模式
# ═══════════════════════════════════════

func enter_weapon_mode(wd: WeaponData) -> void:
	_weapon_mode = true
	_weapon_data = wd
	_current_weapon_char_idx = wd.get_raise_char_sequence()[0]
	if animation_timer:
		animation_timer.wait_time = walk_frame_duration
		animation_timer.start()
	_refresh_sprite()


func exit_weapon_mode() -> void:
	_weapon_mode = false
	_weapon_data = null
	_current_weapon_char_idx = 0
	_refresh_sprite()


## 设置举起/放下动画帧（使用 weapon_raise_char_sequence 中的索引）
func set_weapon_frame(idx: int) -> void:
	if _weapon_data:
		_current_weapon_char_idx = _weapon_data.get_raise_char_sequence()[idx]
	_refresh_sprite()


## 设置武器就绪帧（举起序列的最后一帧）
func set_weapon_ready_frame() -> void:
	if _weapon_data:
		var seq: Array[int] = _weapon_data.get_raise_char_sequence()
		_current_weapon_char_idx = seq[seq.size() - 1]
	_refresh_sprite()


## 设置攻击动画的角色索引（直接使用 char_idx 值）
func set_attack_char_index(char_idx: int) -> void:
	_current_weapon_char_idx = char_idx
	_refresh_sprite()


func get_weapon_data() -> WeaponData:
	return _weapon_data


## 进入推击模式：切换推击行走图。
## 优先级：角色按武器查找 > 角色通用推击图 > 武器推击图 > 回退普通武器纹理
func enter_shove_mode() -> void:
	_shove_mode = true
	_shove_texture = null
	if current_character and _weapon_data:
		_shove_texture = current_character.get_shove_walk_texture(_weapon_data.weapon_state_name)
	if not _shove_texture and _weapon_data and _weapon_data.shove_walk_texture:
		_shove_texture = _weapon_data.shove_walk_texture
	_refresh_sprite()


## 退出推击模式：恢复武器行走图
func exit_shove_mode() -> void:
	_shove_mode = false
	_shove_texture = null
	_refresh_sprite()


## 进入投掷物举起模式：切换投掷物行走图（完整持物外观，跟随朝向+踏步）
func enter_throwable_mode(td: ThrowableData) -> void:
	_throwable_mode = true
	_throwable_texture = td.held_walk_texture if td else null
	_throwable_char_idx = current_character.throwable_walk_char_idx if current_character else 0
	_refresh_sprite()


## 退出投掷物举起模式：恢复普通行走图
func exit_throwable_mode() -> void:
	_throwable_mode = false
	_throwable_texture = null
	_throwable_char_idx = 0
	_refresh_sprite()


# ═══════════════════════════════════════
# 方向向量工具
# ═══════════════════════════════════════

## 根据当前朝向返回方向向量
func get_facing_vector() -> Vector2:
	match _facing:
		FaceDir.DOWN:  return Vector2(0, 1)
		FaceDir.UP:    return Vector2(0, -1)
		FaceDir.LEFT:  return Vector2(-1, 0)
		FaceDir.RIGHT: return Vector2(1, 0)
	return Vector2(0, 1)


# ═══════════════════════════════════════
# 固定朝向
# ═══════════════════════════════════════

## 锁定朝向到当前方向
func lock_facing() -> void:
	if _facing_locked:
		return
	_locked_facing = _facing
	_facing_locked = true
	print("[玩家] 朝向已锁定: %d" % _facing)


## 解锁朝向
func unlock_facing() -> void:
	if not _facing_locked:
		return
	_facing_locked = false
	print("[玩家] 朝向已解锁")


## 切换朝向锁定状态
func toggle_facing_lock() -> void:
	if _facing_locked:
		unlock_facing()
	else:
		lock_facing()


## 返回当前朝向是否锁定
func is_facing_locked() -> bool:
	return _facing_locked


# ═══════════════════════════════════════
# 推击疲劳系统（L4D2 风格）
# ═══════════════════════════════════════

## 每帧更新推击疲劳计时器
func _update_shove_fatigue(delta: float) -> void:
	var cd: CharacterData = current_character
	if not cd:
		return
	# 疲劳系统禁用（limit=0）
	if cd.shove_fatigue_limit <= 0:
		_shove_fatigue_count = 0
		_shove_cooldown_timer = 0.0
		_shove_idle_timer = 0.0
		return

	# 冷却倒计时
	if _shove_cooldown_timer > 0.0:
		_shove_cooldown_timer -= delta
		if _shove_cooldown_timer <= 0.0:
			_shove_cooldown_timer = 0.0
			print("[推击疲劳] 冷却结束，可以推击了")

	# 空闲计时器（不在推击状态时累加，用于重置疲劳计数）
	if not player_in_weapon_state or not _shove_mode:
		_shove_idle_timer += delta
		if _shove_idle_timer >= cd.shove_fatigue_reset_time and _shove_fatigue_count > 0:
			_shove_fatigue_count = 0
			print("[推击疲劳] 空闲 %.1fs，疲劳计数已重置" % cd.shove_fatigue_reset_time)


## 检查是否可以推击（疲劳冷却检查）
## 返回 true 表示可以推击
func can_shove() -> bool:
	var cd: CharacterData = current_character
	if not cd:
		return true
	# 禁用疲劳系统
	if cd.shove_fatigue_limit <= 0:
		return true
	# 冷却中
	if _shove_cooldown_timer > 0.0:
		print("[推击疲劳] 冷却中！剩余 %.1fs" % _shove_cooldown_timer)
		return false
	return true


## 推击执行后调用：增加疲劳计数，必要时启动冷却
func on_shove_performed() -> void:
	var cd: CharacterData = current_character
	if not cd or cd.shove_fatigue_limit <= 0:
		return

	_shove_idle_timer = 0.0
	_shove_fatigue_count += 1
	print("[推击疲劳] 推击次数: %d / %d" % [_shove_fatigue_count, cd.shove_fatigue_limit])

	if _shove_fatigue_count >= cd.shove_fatigue_limit:
		_shove_cooldown_timer = cd.shove_cooldown_duration
		_shove_fatigue_count = 0
		print("[推击疲劳] 达到上限！冷却 %.1fs" % cd.shove_cooldown_duration)


# ═══════════════════════════════════════
# HP 系统
# ═══════════════════════════════════════

func _init_hp() -> void:
	current_hp = max_hp


## 从 CharacterData 资源读取外观/动画/HP 参数
func _apply_character_data() -> void:
	# 始终从 Global 同步角色数据（切换角色时必须更新 current_character）
	if Global and Global.player_character:
		current_character = Global.player_character as CharacterData
	if not current_character:
		return
	var cd := current_character
	if cd.walk_texture:   walk_texture = cd.walk_texture
	walk_char_index = cd.walk_char_index
	walk_frame_duration = cd.walk_frame_duration
	if cd.run_texture:    run_texture = cd.run_texture
	run_char_index = cd.run_char_index
	run_frame_duration = cd.run_frame_duration
	if cd.death_texture:  death_texture = cd.death_texture
	death_char_index = cd.death_char_index
	max_hp = float(cd.get_effective_max_hp())
	if cd.hurt_sound:     hurt_sound = cd.hurt_sound
	if cd.death_sound:    death_sound = cd.death_sound


## 角色切换后刷新外观/HP/装备/状态（由 CharacterSwitchManager 调用）
func refresh_after_switch() -> void:
	_apply_character_data()
	if not animation_timer:
		return
	animation_timer.wait_time = walk_frame_duration
	animation_timer.start()
	# 保持 Idle 外观（非武器模式），仅记录武器数据引用
	var wd: WeaponData = Global.get_active_weapon()
	_weapon_data = wd if wd and not wd.weapon_state_name.is_empty() else null
	_weapon_mode = false
	current_hp = Global.player_hp
	_moving = false
	_anim_step = 0
	velocity = Vector2.ZERO
	_refresh_sprite()
	print("[玩家] 切换后刷新完成: %s HP=%.0f" % [
		current_character.character_name if current_character else "?",
		current_hp,
	])


func take_damage(damage: float, _knockback_force: float, direction: Vector2, _is_headshot: bool = false, _knockback_stun: float = 0.0, _hitstun_duration: float = 0.0, source_id: int = 0) -> void:
	if _is_dying:
		return

	# 源头去重：同一伤害源 1 秒内不会对玩家重复判定
	if source_id != 0:
		var now: int = Time.get_ticks_msec()
		_clean_expired_damage_sources(now)
		if source_id in _recent_damage_sources:
			if now - _recent_damage_sources[source_id] < DAMAGE_SOURCE_COOLDOWN_MSEC:
				print("[玩家] 源头去重：source_id=%d 在冷却期内，跳过伤害" % source_id)
				return
		_recent_damage_sources[source_id] = now

	current_hp = maxf(0.0, current_hp - damage)
	print("[玩家] 受到伤害: %d | HP: %.0f/%.0f | source=%d" % [int(damage), current_hp, max_hp, source_id])
	_play_hit_feedback(Color.RED)

	# 弹出伤害数字（红色调，表示玩家受伤）
	var tree := get_tree()
	if tree and tree.current_scene:
		DamageNumber.spawn(global_position, damage, tree.current_scene, 0, Color(1.0, 0.25, 0.2))

	# 播放受伤音效
	_play_sound(hurt_sound)

	# 同步 HP 到 Global
	Global.player_hp = current_hp
	# 同步到队伍成员数据
	var member := Global.get_current_team_member()
	if not member.is_empty():
		member["current_hp"] = current_hp

	if current_hp <= 0.0:
		_die()


## 播放受击反馈（闪红/渐隐）
func _play_hit_feedback(hit_color: Color = Color.RED, duration: float = -1.0) -> void:
	if duration < 0.0:
		duration = hit_feedback_duration
	if not sprite:
		return
	if has_meta("_hf_tween"):
		var old: Tween = get_meta("_hf_tween")
		if old and old.is_valid():
			old.kill()
	if hit_feedback_mode == 0:
		var tween := create_tween()
		set_meta("_hf_tween", tween)
		tween.tween_property(sprite, "modulate", hit_color, 0.0)
		tween.tween_property(sprite, "modulate", Color.WHITE, duration)
	else:
		sprite.modulate = hit_color
		var tween := create_tween()
		set_meta("_hf_tween", tween)
		tween.tween_property(sprite, "modulate", Color.WHITE, duration)


func heal(amount: float) -> void:
	current_hp = minf(max_hp, current_hp + amount)
	Global.player_hp = current_hp
	# 同步到队伍成员数据
	var member := Global.get_current_team_member()
	if not member.is_empty():
		member["current_hp"] = current_hp
	print("[玩家] 回复 HP: %d | HP: %.0f/%.0f" % [int(amount), current_hp, max_hp])


## 回复 TP（技能点）。供物品使用效果与自动回复共用。
func restore_tp(amount: int) -> void:
	if amount <= 0:
		return
	var max_tp: int = _get_max_tp()
	var before: int = Global.player_tp
	Global.player_tp = mini(max_tp, before + amount)
	if Global.player_tp > before:
		print("[玩家] 回复 TP: +%d | TP: %d/%d" % [Global.player_tp - before, Global.player_tp, max_tp])


## 当前角色的 TP 上限
func _get_max_tp() -> int:
	if current_character:
		return current_character.get_effective_max_tp()
	if Global and Global.player_character:
		return (Global.player_character as CharacterData).get_effective_max_tp()
	return 100


## 每帧更新 TP 自动回复（恢复量/间隔由 CharacterData 决定）
func _update_tp_regen(delta: float) -> void:
	if _is_dying or not current_character:
		return
	var interval: float = current_character.tp_regen_interval
	if interval <= 0.0:
		return
	if Global.player_tp >= _get_max_tp():
		_tp_regen_timer = 0.0
		return
	_tp_regen_timer += delta
	if _tp_regen_timer >= interval:
		_tp_regen_timer -= interval
		restore_tp(current_character.tp_regen_amount)


## 按搓招触发键释放技能（空壳子：只扣 TP，实际效果待技能系统设计）
## trigger: 触发键的输入动作名（如 "确定键"/"取消键"），匹配 SkillData.command_trigger
func use_skill(trigger: String = "") -> void:
	if not current_character:
		return
	var skills: Array[SkillData] = current_character.skills
	if skills.is_empty():
		print("[技能] 当前角色没有技能")
		return
	var skill: SkillData = _find_skill_by_trigger(skills, trigger)
	if not skill:
		print("[技能] 没有绑定触发键 %s 的技能" % trigger)
		return
	if not _match_motion(skill.command_motion):
		print("[技能] 搓招失败：%s 需要方向指令 [%s]" % [skill.skill_name, skill.command_motion])
		return
	if skill.tp_cost > 0 and Global.player_tp < skill.tp_cost:
		print("[技能] TP 不足: 需要 %d, 当前 %d" % [skill.tp_cost, Global.player_tp])
		return
	Global.player_tp -= skill.tp_cost
	print("[技能] 释放 %s | 消耗 TP %d | 剩余 %d" % [skill.skill_name, skill.tp_cost, Global.player_tp])
	# TODO: 实际技能效果（伤害/治疗/增益/切换形态/召唤等），并接入 cooldown


## 按触发键查找技能（command_trigger 匹配；无匹配时回退到第一个未绑定触发键的技能）
func _find_skill_by_trigger(skills: Array[SkillData], trigger: String) -> SkillData:
	for s: SkillData in skills:
		if s.command_trigger == trigger:
			return s
	for s: SkillData in skills:
		if s.command_trigger.is_empty():
			return s
	return null


## 每帧记录方向键输入到搓招缓冲
func _update_motion_input() -> void:
	for d: String in MOTION_DIRS:
		if Input.is_action_just_pressed(d):
			_record_motion(d)


func _record_motion(direction: String) -> void:
	_motion_buffer.append(direction)
	if _motion_buffer.size() > MOTION_BUFFER_MAX:
		_motion_buffer.pop_front()


## 检查最近方向输入是否以指定指令序列结尾（如 "下右"）
func _match_motion(motion: String) -> bool:
	if motion.is_empty():
		return true
	var n: int = motion.length()
	if n > _motion_buffer.size():
		return false
	var start: int = _motion_buffer.size() - n
	for i: int in range(n):
		if _motion_buffer[start + i] != motion[i]:
			return false
	return true


# ═══════════════════════════════════════
# 死亡系统
# ═══════════════════════════════════════


## 尝试在死亡时切换到其他存活队员
func _try_switch_on_death() -> bool:
	if _switch_on_death_attempted:
		return false
	_switch_on_death_attempted = true
	Global._save_global_to_team_member(Global.current_team_index)
	var mgr: Node = null
	var tree := get_tree()
	if tree:
		var nodes: Array[Node] = tree.get_nodes_in_group("character_switch_manager")
		if nodes.size() > 0:
			mgr = nodes[0]
	if not mgr:
		return false
	# 把当前队员标记为死亡
	var member := Global.get_current_team_member()
	if not member.is_empty():
		member["current_hp"] = 0.0
	# 尝试切换
	var switched: bool = mgr.switch_after_death()
	if switched:
		print("[玩家] 死亡→切换到下一队员")
	return switched


func _clean_expired_damage_sources(now: int) -> void:
	## 清理超过冷却时间的伤害源记录，防止字典无限增长
	var to_erase: Array[int] = []
	for sid: int in _recent_damage_sources:
		if now - _recent_damage_sources[sid] >= DAMAGE_SOURCE_COOLDOWN_MSEC:
			to_erase.append(sid)
	for sid: int in to_erase:
		_recent_damage_sources.erase(sid)


func _die() -> void:
	# 有其他存活队员 → 切换而非死亡
	if _try_switch_on_death():
		return
	print("[玩家] 死亡！")
	_is_dying = true
	_death_phase = 0

	# 播放死亡音效
	_play_sound(death_sound)

	# 更新 Global HP
	Global.player_hp = 0.0

	# 停止状态机
	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)

	# 停止移动 & 动画（防止 timer 回调 _refresh_sprite 覆盖死亡帧）
	_moving = false
	player_in_weapon_state = false
	velocity = Vector2.ZERO
	_weapon_mode = false
	_shove_mode = false
	_shove_texture = null
	if animation_timer:
		animation_timer.stop()

	# 显示死亡精灵
	var tex: Texture2D = death_texture if death_texture else walk_texture
	if tex:
		sprite.texture = tex
		var char_col: int = death_char_index % CHARS_PER_ROW
		var char_row: int = death_char_index / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_facing]
		var x: int = char_col * (FRAME_W * 3) + STAND_FRAME * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)

	# 禁用碰撞
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", true)
	# 禁用受击碰撞体
	if hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)

	# 播放死亡音乐
	if not Global.death_music_path.is_empty():
		var music: AudioStream = load(Global.death_music_path) as AudioStream
		if music:
			_play_music(music)

	# 创建黑屏遮罩
	_create_fade_overlay()


func _create_fade_overlay() -> void:
	# CanvasLayer 确保 Control 节点能在 2D 场景之上渲染
	var cl := CanvasLayer.new()
	cl.name = "DeathFadeCanvas"
	cl.layer = 128  # 最顶层

	_death_fade_overlay = ColorRect.new()
	_death_fade_overlay.name = "DeathFadeOverlay"
	_death_fade_overlay.color = Color(0, 0, 0, 0)  # 初始透明
	_death_fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_fade_overlay.size = get_viewport().get_visible_rect().size

	cl.add_child(_death_fade_overlay)

	var tree: SceneTree = get_tree()
	if tree and tree.current_scene:
		tree.current_scene.add_child(cl)
		_death_fade_timer = 0.0
		_death_phase = 1


func _process_death(delta: float) -> void:
	match _death_phase:
		1:  # 渐黑
			_death_fade_timer += delta
			var progress: float = clampf(_death_fade_timer / Global.death_fade_duration, 0.0, 1.0)
			if _death_fade_overlay:
				_death_fade_overlay.color = Color(0, 0, 0, progress)
			if progress >= 1.0:
				_death_fade_timer = 0.0
				_death_phase = 2
				print("[玩家] 黑屏完成，等待重载...")

		2:  # 全黑等待
			_death_fade_timer += delta
			if _death_fade_timer >= Global.death_black_hold:
				_death_phase = 3
				_reload_from_save()

		3:  # 已触发重载，等待
			pass


func _reload_from_save() -> void:
	# 死亡后从 checkpoint 恢复所有状态（HP/装备/弹药/队伍），再清空 checkpoint 回到安全屋
	print("[玩家] 死亡，从 checkpoint 恢复...")
	var safehouse: String = Global.get_checkpoint_scene()
	Global.restore_checkpoint()
	Global.checkpoint.clear()
	var tree: SceneTree = get_tree()
	if not tree:
		return
	if not safehouse.is_empty() and safehouse != tree.current_scene.scene_file_path:
		# 不在安全屋 → 切回安全屋场景
		var err := tree.change_scene_to_file(safehouse)
		if err != OK:
			printerr("[玩家] 无法切回安全屋: %s (err=%d)" % [safehouse, err])
			tree.reload_current_scene()
	else:
		# 已在安全屋死亡 → 直接重载
		tree.reload_current_scene()


# ═══════════════════════════════════════
# 音效工具
# ═══════════════════════════════════════

func _play_sound(stream: AudioStream) -> void:
	if not stream:
		return
	Global.play_sfx_managed(stream, self)


func _play_music(stream: AudioStream) -> void:
	## 播放全局音乐（替换当前音乐）
	if not stream:
		return
	# 停止已有的音乐
	for child: Node in get_children():
		if child is AudioStreamPlayer and child.name == "DeathMusicPlayer":
			child.stop()
			child.queue_free()

	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.name = "DeathMusicPlayer"
	player.stream = stream
	player.bus = "Music"
	player.volume_db = Global.death_music_volume_db
	player.autoplay = true
	add_child(player)


# ═══════════════════════════════════════
# Debug 可视化（TAB 切换）
# ═══════════════════════════════════════

func _draw() -> void:
	if not Global.debug_visuals:
		return
	# 绘制玩家碰撞体
	var cs: CollisionShape2D = $CollisionShape2D
	var shape: Shape2D = cs.shape
	if shape is RectangleShape2D:
		var rect: RectangleShape2D = shape as RectangleShape2D
		var color: Color = Color.GRAY if _is_dying else Color.GREEN
		var pos: Vector2 = cs.position
		draw_rect(Rect2(pos - rect.size / 2, rect.size), color, false, 1.0)
	# 绘制 HP 条
	var bar_w: float = 48.0
	var bar_h: float = 4.0
	var bar_y: float = -40.0
	var ratio: float = current_hp / max_hp
	draw_rect(Rect2(-bar_w/2, bar_y, bar_w, bar_h), Color.RED, false, 1.0)
	draw_rect(Rect2(-bar_w/2, bar_y, bar_w * ratio, bar_h), Color.GREEN if not _is_dying else Color.GRAY, true)

	# 绘制受击碰撞体（黄色虚线）
	if hurt_area:
		var hshape_node: CollisionShape2D = hurt_area.get_node_or_null("HurtShape")
		if hshape_node and hshape_node.shape is RectangleShape2D:
			var hs: Vector2 = (hshape_node.shape as RectangleShape2D).size
			var ho: Vector2 = hshape_node.position
			draw_rect(Rect2(ho - hs / 2, hs), Color.YELLOW, false, 1.0)


# ═══════════════════════════════════════
# 内部
# ═══════════════════════════════════════

func _refresh_sprite() -> void:
	if not sprite:
		return
	if _is_dying:   ## 死亡后拒绝一切刷新，防止覆盖 _die() 设置的死亡帧
		return

	# 投掷物举起模式：使用投掷物行走图（跟随朝向+踏步）
	if _throwable_mode and _throwable_texture:
		sprite.texture = _throwable_texture
		var char_idx: int = _throwable_char_idx
		var frame: int = STAND_FRAME if not _moving else WALK_SEQUENCE[_anim_step]
		var char_col: int = char_idx % CHARS_PER_ROW
		var char_row: int = char_idx / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_facing]
		var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
		return

	# 武器模式下使用武器纹理和角色索引
	if _weapon_mode and _weapon_data:
		# 推击模式：优先推击行走图（运行时设置 > 武器字段 > 角色字段 > 回退普通武器纹理）
		if _shove_mode and _shove_texture:
			sprite.texture = _shove_texture
		else:
			var tex: Texture2D = null
			# 角色专属武器行走图
			if current_character:
				tex = current_character.get_weapon_walk_texture(_weapon_data.weapon_state_name)
			# 回退到武器默认行走图
			if not tex:
				tex = _weapon_data.weapon_walk_texture
			if not tex:
				return
			sprite.texture = tex
		var char_idx: int = _current_weapon_char_idx
		var frame: int = STAND_FRAME if not _moving else WALK_SEQUENCE[_anim_step]

		var char_col: int = char_idx % CHARS_PER_ROW
		var char_row: int = char_idx / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_facing]

		var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
		return

	# 普通模式
	if not walk_texture or not run_texture:
		return
	var use_run_tex: bool = _moving and not _is_walking
	sprite.texture = run_texture if use_run_tex else walk_texture

	var char_idx: int = run_char_index if use_run_tex else walk_char_index
	var frame: int = STAND_FRAME if not _moving else WALK_SEQUENCE[_anim_step]

	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var dir_row: int = DIR_ROWS[_facing]

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H

	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
