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
@export var _facing: int = FaceDir.DOWN:    ## @export 以暴露给 MultiplayerSynchronizer
	set(v):
		if _facing != v:
			_facing = v
			if not _is_dying:
				_refresh_sprite()
var _facing_locked: bool = false
var _locked_facing: int = FaceDir.DOWN
var _anim_step: int = 0
@export var _moving: bool = false:           ## @export 以暴露给 MultiplayerSynchronizer
	set(v):
		if _moving != v:
			_moving = v
			if animation_timer:
				if _moving:
					animation_timer.start()
				else:
					animation_timer.stop()
					_anim_step = 0
					_refresh_sprite()
var _is_walking: bool = false:   ## 当前外观是行走(true)还是跑步(false)，setter 供 puppet 同步
	set(v):
		if _is_walking != v:
			_is_walking = v
			if not _is_dying:
				_refresh_sprite()
## 当前状态枚举（供联机 puppet 推断动画）
## 0=Idle 1=Walk 2=Run 3=Weapon 4=Attack 5=Reload 6=Downed
@export var state_enum: int = 0:
	set(v):
		if state_enum != v:
			state_enum = v
			# Puppet 模式：根据状态切换武器外观
			if not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
				if get_multiplayer_authority() != multiplayer.get_unique_id():
					match v:
						3:  # Weapon → 播放举起动画
							_puppet_anim_playing = false
							if not _weapon_mode and _puppet_weapon_data:
								enter_weapon_mode(_puppet_weapon_data)
								_start_puppet_raise_anim()
						5:  # Reload → 显示武器就绪帧（跳过动画）
							_puppet_anim_playing = false
							if not _weapon_mode and _puppet_weapon_data:
								enter_weapon_mode(_puppet_weapon_data)
							set_weapon_ready_frame()
						4:  # Attack → 开始攻击动画
							if not _weapon_mode and _puppet_weapon_data:
								enter_weapon_mode(_puppet_weapon_data)
							_start_puppet_attack_anim()
						0, 1, 2, 6:  # Idle / Walk / Run / Downed → 播放放下动画
							_puppet_anim_playing = false
							if _weapon_mode and _puppet_weapon_data:
								_start_puppet_lower_anim()
							else:
								exit_weapon_mode()
							if _weapon_mode:
								exit_weapon_mode()
var _weapon_mode: bool = false  ## 是否处于武器举起模式
var _weapon_data: WeaponData = null
var _current_weapon_char_idx: int = 0  ## 当前武器模式下使用的角色索引
var player_in_weapon_state: bool = false  ## 供 menu_controller 检查菜单屏蔽
var _near_pickup: bool = false            ## 玩家是否在武器拾取物范围内（由 weapon_pickup 设置）
var _switch_on_death_attempted: bool = false  ## 是否已尝试死亡切换
var current_hp: float = 200.0

## 玩家数据容器（联机准备：从 Global 分离玩家状态）
## 类型实际为 PlayerData，不标注类型以避免 Godot 4.6 跨文件 class_name 解析顺序问题
var player_data = null
## 网络归属 ID：1 = 本地玩家/Host，其他值 = 远程 peer ID
var owner_id: int = 1

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

	# 判断运行模式
	var is_puppet: bool = false
	if not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		# 联机模式：检查 authority
		if get_multiplayer_authority() != multiplayer.get_unique_id():
			is_puppet = true

	if is_puppet:
		_init_puppet()
	else:
		_init_singleplayer()


func _init_singleplayer() -> void:
	## 单机 / Authority 模式的完整初始化
	# 从 CharacterData 资源读取外观/HP 参数（覆盖本地 @export 默认值）
	_apply_character_data()

	if walk_texture == null:
		walk_texture = load("res://art/Characters/のび太セット.png") as Texture2D
	if run_texture == null:
		run_texture = load("res://art/Characters/のび太歩行セット.png") as Texture2D

	# 俯视角：浮动模式，所有碰撞都是墙壁
	motion_mode = MOTION_MODE_FLOATING

	animation_timer.wait_time = walk_frame_duration
	var cb: Callable = _on_animation_timer_timeout
	animation_timer.timeout.connect(cb)
	animation_timer.start()
	_refresh_sprite()

	# 初始化 PlayerData 容器（从 Global 同步初始状态）
	_init_player_data()

	# 从 Global 恢复 HP（用于存档加载后）
	if Global.player_hp > 0.0:
		current_hp = Global.player_hp
	else:
		current_hp = max_hp
	# 同步到 PlayerData
	if player_data:
		player_data.current_hp = current_hp


# ═══════════════════════════════════════
# 联机同步（Authority → Puppets）
# ═══════════════════════════════════════
const NET_SYNC_INTERVAL: float = 0.05   ## 20Hz 位置同步
var _net_sync_timer: float = 0.0


func _process(delta: float) -> void:
	if _is_dying:
		_process_death(delta)
		return

	# Puppet 动画驱动（举起/攻击）
	if _puppet_anim_playing:
		_process_puppet_anim(delta)

	# 联机模式：Authority 定时广播状态给其他 peer
	if not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		if get_multiplayer_authority() == multiplayer.get_unique_id():
			_net_sync_timer += delta
			if _net_sync_timer >= NET_SYNC_INTERVAL:
				_net_sync_timer = 0.0
				var weapon_id: String = ""
				var wd := Global.get_active_weapon()
				if wd:
					weapon_id = wd.item_id
				_sync_state.rpc(global_position, _facing, _moving, _is_walking, state_enum, weapon_id)


## Authority 调用 → 远程 puppet 接收位置/朝向/移动/行走状态 + 状态枚举 + 武器ID
@rpc("authority", "unreliable")
func _sync_state(pos: Vector2, facing: int, moving: bool, is_walking: bool, st_enum: int, weapon_id: String) -> void:
	global_position = pos
	_facing = facing        ## setter 自动触发 _refresh_sprite()
	_is_walking = is_walking  ## setter 自动触发 _refresh_sprite()
	_moving = moving        ## setter 自动启停 animation_timer（放最后避免重复刷新）
	# 更新 puppet 武器外观
	_update_puppet_weapon(weapon_id)
	state_enum = st_enum


## Authority 调用 → 远程 puppet 接收 HP 变化（reliable, HP 变化时触发）
@rpc("authority", "reliable")
func _sync_hp(hp: float) -> void:
	current_hp = hp


func _init_puppet() -> void:
	## 远程玩家 puppet 模式 — 禁用逻辑，只做视觉渲染
	print("[Player] Puppet 模式 — peer_id=%d authority=%d" % [multiplayer.get_unique_id(), get_multiplayer_authority()])

	# 禁用状态机
	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)

	# 禁用碰撞
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", true)

	# 禁用受击碰撞体
	if hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)

	# 俯视角模式
	motion_mode = MOTION_MODE_FLOATING

	# 基本外观
	_apply_character_data()
	if walk_texture == null:
		walk_texture = load("res://art/Characters/のび太セット.png") as Texture2D
	if run_texture == null:
		run_texture = load("res://art/Characters/のび太歩行セット.png") as Texture2D

	# 初始化 PlayerData（从 Global 复制初始状态，供 Host 端 _execute_attack 使用）
	_init_player_data()

	# 启动简单动画 timer（只用于 puppet 本地视觉）
	animation_timer.wait_time = walk_frame_duration
	var cb: Callable = _on_animation_timer_timeout
	animation_timer.timeout.connect(cb)
	animation_timer.start()

	# 半透明标记为远程玩家
	if sprite:
		sprite.modulate = Color(1, 1, 1, 0.7)

	print("[Player] Puppet 初始化完成")


## puppet: 根据同步的 weapon_id 更新武器外观
var _puppet_weapon_id: String = ""
var _puppet_weapon_data: WeaponData = null
## puppet: 本地动画驱动（攻击 + 举起/放下）
var _puppet_anim_seq_idx: int = 0
var _puppet_anim_timer: float = 0.0
var _puppet_anim_playing: bool = false
enum PuppetAnimType { NONE, RAISE, ATTACK, LOWER }
var _puppet_anim_type: int = PuppetAnimType.NONE

func _update_puppet_weapon(weapon_id: String) -> void:
	if weapon_id.is_empty():
		return
	if weapon_id == _puppet_weapon_id:
		return
	_puppet_weapon_id = weapon_id
	# 查找 WeaponData 资源（遍历 Global.equipment 和已知武器路径）
	var wd: WeaponData = null
	# 尝试从 Global 查找（Host 端 puppet 有完整装备数据）
	for slot: String in ["primary", "secondary"]:
		var eq: WeaponData = Global.get_equipped_weapon(slot) as WeaponData
		if eq and eq.item_id == weapon_id:
			wd = eq
			break
	if not wd:
		# 回退：尝试加载已知武器资源
		var known_weapons: Array[String] = [
			"res://object/weapon_pistol.tres",
			"res://object/weapon_knife.tres",
			"res://object/weapon_shotgun.tres",
			"res://object/weapon_rifle.tres",
			"res://object/weapon_smg.tres",
		]
		for path: String in known_weapons:
			if ResourceLoader.exists(path):
				var res: WeaponData = load(path) as WeaponData
				if res and res.item_id == weapon_id:
					wd = res
					break
	if wd:
		_puppet_weapon_data = wd
		print("[Player] Puppet 武器缓存: %s" % weapon_id)
		# 如果当前已处于武器状态，立即切换武器外观
		if _weapon_mode:
			exit_weapon_mode()
			enter_weapon_mode(wd)


## puppet: 启动举起动画
func _start_puppet_raise_anim() -> void:
	if not _puppet_weapon_data:
		return
	var seq: Array[int] = _puppet_weapon_data.get_raise_char_sequence()
	if seq.is_empty():
		set_weapon_ready_frame()
		return
	_puppet_anim_type = PuppetAnimType.RAISE
	_puppet_anim_seq_idx = 0
	_puppet_anim_timer = _puppet_weapon_data.get_raise_frame_duration(0)
	_puppet_anim_playing = true
	_current_weapon_char_idx = seq[0]
	_refresh_sprite()


## puppet: 启动攻击动画
func _start_puppet_attack_anim() -> void:
	if not _puppet_weapon_data:
		return
	var seq: Array[int] = _puppet_weapon_data.attack_char_sequence
	if seq.is_empty():
		return
	_puppet_anim_type = PuppetAnimType.ATTACK
	_puppet_anim_seq_idx = 0
	_puppet_anim_timer = _puppet_weapon_data.get_attack_frame_duration(0)
	_puppet_anim_playing = true
	_current_weapon_char_idx = seq[0]
	_refresh_sprite()


## puppet: 启动放下动画（举起序列反向播放）
func _start_puppet_lower_anim() -> void:
	if not _puppet_weapon_data:
		return
	var seq: Array[int] = _puppet_weapon_data.get_raise_char_sequence().duplicate()
	seq.reverse()
	if seq.is_empty():
		exit_weapon_mode()
		return
	_puppet_anim_type = PuppetAnimType.LOWER
	_puppet_anim_seq_idx = 0
	# 反向动画的时长：原序列的反向帧时长
	_puppet_anim_timer = _puppet_weapon_data.get_raise_frame_duration(seq.size() - 1 - 0)
	_puppet_anim_playing = true
	_current_weapon_char_idx = seq[0]
	_refresh_sprite()


## puppet: 统一动画驱动（_process 中调用）
func _process_puppet_anim(delta: float) -> void:
	if not _puppet_anim_playing or not _puppet_weapon_data:
		return
	_puppet_anim_timer -= delta
	if _puppet_anim_timer <= 0.0:
		_puppet_anim_seq_idx += 1
		var seq: Array[int] = []
		var dur: float = 0.1
		var orig_size: int = _puppet_weapon_data.get_raise_char_sequence().size()
		match _puppet_anim_type:
			PuppetAnimType.RAISE:
				seq = _puppet_weapon_data.get_raise_char_sequence()
			PuppetAnimType.LOWER:
				seq = _puppet_weapon_data.get_raise_char_sequence().duplicate()
				seq.reverse()
			PuppetAnimType.ATTACK:
				seq = _puppet_weapon_data.attack_char_sequence
		if _puppet_anim_seq_idx >= seq.size():
			_puppet_anim_playing = false
			var finished_type: int = _puppet_anim_type
			_puppet_anim_type = PuppetAnimType.NONE
			match finished_type:
				PuppetAnimType.LOWER:
					exit_weapon_mode()
				_:
					set_weapon_ready_frame()
			return
		# 获取当前帧时长
		match _puppet_anim_type:
			PuppetAnimType.RAISE:
				dur = _puppet_weapon_data.get_raise_frame_duration(_puppet_anim_seq_idx)
			PuppetAnimType.LOWER:
				dur = _puppet_weapon_data.get_raise_frame_duration(orig_size - 1 - _puppet_anim_seq_idx)
			PuppetAnimType.ATTACK:
				dur = _puppet_weapon_data.get_attack_frame_duration(_puppet_anim_seq_idx)
		_puppet_anim_timer = dur
		_current_weapon_char_idx = seq[_puppet_anim_seq_idx]
		_refresh_sprite()


func _init_player_data() -> void:
	## 创建 PlayerData 并从 Global 同步初始状态
	var pd_script: Script = load("res://script/player_data.gd") as Script
	player_data = pd_script.new()
	player_data.character = Global.player_character as CharacterData
	player_data.current_hp = current_hp
	player_data.equipment = Global.equipment.duplicate()
	player_data.weapon_magazines = Global.weapon_magazines.duplicate()
	player_data.active_weapon_slot = Global.active_weapon_slot
	player_data.healing_item = Global.healing_item
	player_data.support_item = Global.support_item
	player_data.inventory = Global.inventory.duplicate()
	player_data.gold = Global.gold


## 将 PlayerData 同步回 Global（保持向后兼容）
func _sync_player_data_to_global() -> void:
	if not player_data:
		return
	Global.player_hp = player_data.current_hp
	Global.player_character = player_data.character
	Global.equipment = player_data.equipment.duplicate()
	Global.weapon_magazines = player_data.weapon_magazines.duplicate()
	Global.active_weapon_slot = player_data.active_weapon_slot
	Global.healing_item = player_data.healing_item
	Global.support_item = player_data.support_item
	Global.inventory = player_data.inventory.duplicate()
	Global.gold = player_data.gold


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
# 输入抽象层（联机准备）
# ═══════════════════════════════════════

## 获取移动输入向量。当前代理到 Input 单例；联机时改为读取网络输入。
func get_input_vector() -> Vector2:
	return Input.get_vector("左", "右", "上", "下")


## 检查指定动作是否被按下。当前代理到 Input 单例；联机时改为读取网络输入。
func is_input_action_pressed(action: String) -> bool:
	return Input.is_action_pressed(action)


## 检查指定动作是否刚被按下（单次触发）。
func is_input_action_just_pressed(action: String) -> bool:
	return Input.is_action_just_pressed(action)


# ═══════════════════════════════════════
# HP 系统
# ═══════════════════════════════════════

func _init_hp() -> void:
	current_hp = max_hp


## 从 CharacterData 资源读取外观/动画/HP 参数
func _apply_character_data() -> void:
	if not current_character:
		if Global and Global.player_character:
			current_character = Global.player_character as CharacterData
		else:
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
	# 切换到 idle 状态（放下武器）
	var wd: WeaponData = Global.get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		# 直接进入武器 ready 帧（跳过举起动画）
		enter_weapon_mode(wd)
		set_weapon_ready_frame()
	else:
		exit_weapon_mode()
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

	# 联机模式：只有 Host 处理伤害
	if Lobby.is_online() and not multiplayer.is_server():
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

	# 联机模式：广播 HP 变化给所有 peer
	if Lobby.is_online() and multiplayer.is_server():
		_sync_hp.rpc(current_hp)

	if current_hp <= 0.0:
		_die()




func heal(amount: float) -> void:
	# 联机模式：只有 Host 处理治疗
	if Lobby.is_online() and not multiplayer.is_server():
		return
	current_hp = minf(max_hp, current_hp + amount)
	Global.player_hp = current_hp
	# 同步到队伍成员数据
	var member := Global.get_current_team_member()
	if not member.is_empty():
		member["current_hp"] = current_hp
	print("[玩家] 回复 HP: %d | HP: %.0f/%.0f" % [int(amount), current_hp, max_hp])
	# 联机模式：广播 HP 变化
	if Lobby.is_online() and multiplayer.is_server():
		_sync_hp.rpc(current_hp)


# ═══════════════════════════════════════
# 联机战斗方法（由 NetworkSyncManager RPC 调用）
# ═══════════════════════════════════════

## Host 收到 Client 的攻击请求后调用，生成子弹实体
## weapon_item_id: Client 当前使用的武器 ID（不是 Host 的武器）
## 弹药 = player_data（独立弹药池，首次自动初始化）
func _execute_attack(weapon_item_id: String = "") -> void:
	var wd: WeaponData = null
	# 根据 weapon_item_id 查找 WeaponData
	if not weapon_item_id.is_empty():
		# 先查 Global.equipment（Host 本地装备）
		for slot: String in ["primary", "secondary"]:
			var eq: WeaponData = Global.get_equipped_weapon(slot) as WeaponData
			if eq and eq.item_id == weapon_item_id:
				wd = eq
				break
		# 回退：加载已知武器资源
		if not wd:
			var known: Array[String] = [
				"res://object/weapon_pistol.tres",
				"res://object/weapon_knife.tres",
				"res://object/weapon_shotgun.tres",
				"res://object/weapon_rifle.tres",
				"res://object/weapon_smg.tres",
			]
			for path: String in known:
				if ResourceLoader.exists(path):
					var res: WeaponData = load(path) as WeaponData
					if res and res.item_id == weapon_item_id:
						wd = res
						break
	if not wd:
		wd = Global.get_active_weapon()  # 最终回退
	if not wd or not wd.is_ranged:
		return

	# 弹药：使用 player_data 独立管理（每个玩家的 puppet 有独立弹药池）
	var current: int = 0
	if player_data:
		current = player_data.get_magazine_ammo(wd.item_id)
		if current <= 0:
			# 首次攻击：自动初始化为满弹夹
			current = wd.magazine_capacity
			player_data.set_magazine_ammo(wd.item_id, current)
	else:
		current = Global.get_magazine_ammo(wd.item_id)

	if current <= 0:
		if wd.empty_fire_sound:
			Global.play_sfx_managed(wd.empty_fire_sound, get_tree().current_scene)
		return

	# 消耗弹药
	if player_data:
		player_data.set_magazine_ammo(wd.item_id, current - 1)
	else:
		Global.set_magazine_ammo(wd.item_id, current - 1)
	var bullet_count: int = wd.bullet_list.size()
	print("[Player] _execute_attack: 弹夹剩余 %d/%d | 子弹数 %d | 数据源=%s" % [current - 1, wd.magazine_capacity, bullet_count, "player_data" if player_data else "Global"])

	var bullet_scene: PackedScene = load("res://object/bullet.tscn") as PackedScene
	if not bullet_scene:
		return

	var base_dir: Vector2 = get_facing_vector()
	var base_pos: Vector2 = global_position

	for bd: BulletData in wd.bullet_list:
		var bullet: Node2D = bullet_scene.instantiate()
		var dir_vec: Vector2 = bd.get_fire_direction(base_dir)
		var damage: float = bd.get_effective_damage(wd.attack_power)

		if bullet.has_method("setup"):
			bullet.setup({
				"direction": dir_vec,
				"speed": bd.speed,
				"max_range": bd.max_range,
				"damage": damage,
				"destroy_on_hit": bd.destroy_on_hit,
				"penetration": bd.penetration,
				"critical_rate": wd.critical_rate,
				"hit_effect_anim": wd.hit_effect_anim,
				"hit_effect_follow": wd.hit_effect_follow,
				"hit_effect_offset_override": wd.hit_effect_offset_override,
				"hit_sound": wd.hit_sound,
				"texture": bd.bullet_texture,
				"anim_frames": bd.bullet_anim_frames,
				"frame_duration": bd.bullet_frame_duration,
				"collision_size": bd.collision_size,
				"collision_offset": bd.collision_offset,
				"knockback_force": bd.knockback_force if bd.knockback_enabled else 0.0,
				"knockback_stun": bd.knockback_stun_duration if bd.knockback_enabled else 0.0,
				"hitstun_duration": bd.hitstun_duration if bd.hitstun_duration > 0.0 else wd.hitstun_duration,
				"shooter": self,
			})

		var extra: Vector2 = bd.get_extra_offset(facing)
		bullet.position = base_pos + dir_vec * bd.spawn_offset + extra
		get_tree().current_scene.add_child(bullet)

	# 播放攻击特效和音效
	var effect_scene: PackedScene = wd.get_attack_effect_anim(facing)
	if effect_scene:
		var follow: Node2D = self if wd.attack_effect_follow else null
		VXAnimSprite.play_scene(effect_scene, global_position, get_tree().current_scene, 10.0, follow, wd.attack_effect_offset_override)
	if wd.attack_sound:
		Global.play_sfx_managed(wd.attack_sound, get_tree().current_scene)

	# 枪声惊敌
	if wd.gunshot_range > 0.0:
		_alert_enemies_by_gunshot(wd.gunshot_range)


## Host 收到 Client 的近战请求后调用，执行近战判定
func _execute_melee() -> void:
	var wd := Global.get_active_weapon()
	if not wd or wd.is_ranged:
		return

	var is_headshot: bool = false
	if wd.critical_rate > 0.0:
		is_headshot = randf() * 100.0 < wd.critical_rate

	# 创建近战判定区域
	var hitbox := Area2D.new()
	hitbox.collision_layer = 0
	hitbox.collision_mask = 24  # 层4+5

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = wd.melee_range_size
	shape.shape = rect
	hitbox.add_child(shape)

	var offset: Vector2 = get_facing_vector() * wd.melee_range_forward_offset
	hitbox.global_position = global_position + offset
	get_tree().current_scene.add_child(hitbox)

	# 检测命中
	var bodies: Array[Node2D] = hitbox.get_overlapping_bodies()
	var areas: Array[Area2D] = hitbox.get_overlapping_areas()
	var damage: float = wd.get_effective_damage()
	var hit_ids: Array[int] = []

	for body: Node2D in bodies:
		if body == self: continue
		if body.get("_is_dead") == true or body.get("_is_dying") == true: continue
		if body.has_method("take_damage"):
			var bid: int = body.get_instance_id()
			if bid in hit_ids: continue
			hit_ids.append(bid)
			body.take_damage(damage, 0.0, get_facing_vector(), is_headshot, 0.0, wd.hitstun_duration)
			if wd.hit_effect_anim:
				VXAnimSprite.play_scene(wd.hit_effect_anim, body.global_position, get_tree().current_scene)
			if wd.hit_sound:
				Global.play_sfx_managed(wd.hit_sound, get_tree().current_scene)

	for area: Area2D in areas:
		var parent: Node = area.get_parent()
		if parent == self: continue
		if parent.get("_is_dead") == true or parent.get("_is_dying") == true: continue
		if parent and parent.has_method("take_damage"):
			var pid: int = parent.get_instance_id()
			if pid in hit_ids: continue
			hit_ids.append(pid)
			parent.take_damage(damage, 0.0, get_facing_vector(), is_headshot, 0.0, wd.hitstun_duration)
			if wd.hit_effect_anim:
				VXAnimSprite.play_scene(wd.hit_effect_anim, parent.global_position, get_tree().current_scene)
			if wd.hit_sound:
				Global.play_sfx_managed(wd.hit_sound, get_tree().current_scene)

	hitbox.queue_free()

	# 播放攻击特效
	var effect_scene: PackedScene = wd.get_attack_effect_anim(facing)
	if effect_scene:
		VXAnimSprite.play_scene(effect_scene, global_position, get_tree().current_scene)
	if wd.attack_sound:
		Global.play_sfx_managed(wd.attack_sound, get_tree().current_scene)


## Host 收到 Client 的装填请求后调用，执行装填
func _execute_reload() -> void:
	var pd = player_data
	var wd: WeaponData = null
	if pd:
		wd = pd.get_active_weapon()
	if not wd:
		wd = Global.get_active_weapon()
	if not wd or not wd.is_ranged or wd.magazine_capacity <= 0:
		return

	var current: int = pd.get_magazine_ammo(wd.item_id) if pd else Global.get_magazine_ammo(wd.item_id)
	if current >= wd.magazine_capacity:
		return

	var need: int = wd.magazine_capacity - current
	var available: int = pd.count_ammo_item(wd.ammo_item_id) if pd else Global.count_ammo_item(wd.ammo_item_id)
	if available <= 0:
		return

	var to_load: int = mini(need, available)
	var consumed: int = pd.consume_ammo_item(wd.ammo_item_id, to_load) if pd else Global.consume_ammo_item(wd.ammo_item_id, to_load)
	if consumed > 0:
		if pd:
			pd.set_magazine_ammo(wd.item_id, current + consumed)
		else:
			Global.set_magazine_ammo(wd.item_id, current + consumed)
		print("[Player] _execute_reload: %d → %d / %d" % [current, current + consumed, wd.magazine_capacity])

	if wd.reload_sound:
		Global.play_sfx_managed(wd.reload_sound, get_tree().current_scene)


## 枪声惊动范围内敌人（由 _execute_attack 调用）
func _alert_enemies_by_gunshot(gunshot_range: float) -> void:
	var tree := get_tree()
	if not tree: return
	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	var shoot_pos: Vector2 = global_position
	var count: int = 0
	for enemy: Node in enemies:
		if not is_instance_valid(enemy): continue
		if enemy.global_position.distance_to(shoot_pos) > gunshot_range: continue
		# 联机模式下由 Host 直接调用 enemy.alert_by_gunshot
		if enemy.has_method("alert_by_gunshot"):
			enemy.alert_by_gunshot(self)
			count += 1
	if count > 0:
		print("[枪声] 惊动 %d 个敌人（范围 %.0fpx）" % [count, gunshot_range])


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
	# L4D2 风格：死亡后回到安全屋，武器清空（安全屋地上会刷新）
	print("[玩家] 死亡，回到安全屋——武器清空...")
	var safehouse: String = Global.get_checkpoint_scene()
	# 清空 checkpoint 标记 + 装备，让安全屋场景以全新状态启动
	Global.checkpoint.clear()
	Global.equipment["primary"] = null
	Global.equipment["secondary"] = null
	Global.weapon_magazines.clear()
	Global.player_hp = 200.0
	Global.inventory.clear()
	Global.healing_item = null
	Global.support_item = null
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

	# 武器模式下使用武器纹理和角色索引
	if _weapon_mode and _weapon_data:
		# 优先使用角色专属武器行走图，回退到武器默认行走图
		var char_walk_tex: Texture2D = null
		if current_character and _weapon_data:
			char_walk_tex = current_character.get_weapon_walk_texture(_weapon_data.weapon_state_name)
		if not char_walk_tex and not _weapon_data.weapon_walk_texture:
			return  # 无任何武器纹理可用
		sprite.texture = char_walk_tex if char_walk_tex else _weapon_data.weapon_walk_texture
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
