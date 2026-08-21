extends CharacterBody2D
## 敵人 — CharacterBody2D + AI 状态机
##
## VX Ace 精灵渲染（与玩家相同逻辑）

# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
const WALK_SEQUENCE: Array[int] = [1, 0, 1, 2]
const STAND_FRAME: int = 1
const DIR_ROWS: Array[int] = [0, 1, 2, 3]
const DAMAGE_SOURCE_COOLDOWN_MSEC: int = 1000  ## 同一伤害源对当前敌人的重复命中冷却（毫秒）

enum FaceDir { DOWN = 0, LEFT = 1, RIGHT = 2, UP = 3 }

# ═══════════════════════════════════════
# 导出参数
# ═══════════════════════════════════════
@export_group("属性")
@export var max_hp: float = 100.0
@export var move_speed: float = 120.0
@export var attack_damage: float = 10.0
@export var attack_range: Vector2 = Vector2(80, 64)  ## 攻击触发矩形（宽×高），跟随朝向旋转，玩家进入则攻击
@export var attack_range_forward_offset: float = 20.0     ## 攻击触发矩形前方偏移
@export var attack_hit_range: Vector2 = Vector2(48, 32)  ## 攻击判定矩形（宽×高）
@export var attack_hit_forward_offset: float = 28.0       ## 攻击判定前方偏移
@export var attack_cooldown_frames: int = 30              ## 攻击后摇帧数（≈0.5秒@60fps）

@export_group("受击碰撞体")
@export var hurtbox_size: Vector2 = Vector2(28, 44)  ## 受击碰撞体尺寸
@export var hurtbox_offset: Vector2 = Vector2(0, -8)  ## 受击碰撞体偏移（相对角色原点）

@export_group("外观")
@export var walk_texture: Texture2D            ## 精灵表
@export var walk_char_index: int = 0           ## 角色索引
@export var walk_frame_duration: float = 0.18
@export var initial_facing: int = FaceDir.DOWN

@export_group("视野")
@export var vision_angle: float = 90.0         ## 视野角度（度）
@export var vision_range: float = 200.0        ## 视野距离（像素）

@export_group("友军伤害")
@export var can_damage_enemies: bool = false       ## 是否可对其他敌人造成伤害（默认关闭）

@export_group("受击反馈")
## 受击反馈模式：0=闪（瞬间变色→逐渐恢复），1=渐隐（变色→渐渐消失）
@export var hit_feedback_mode: int = 0
## 受击反馈持续时间（秒）
@export var hit_feedback_duration: float = 0.5

@export_group("攻击动画")
@export var attack_char_sequence: Array[int] = [1, 2, 3, 1, 0]  ## 攻击动画序列
## 攻击动画每帧持续时间（秒），长度应与 attack_char_sequence 一致
## 为空时使用默认 0.1 秒
@export var attack_frame_durations: Array[float] = []
@export var hit_at_sequence_idx: int = 2       ## 在此序列索引处判定伤害（该帧时长拉长=停顿）

@export_group("死亡")
@export var death_char_index: int = 4          ## 普通死亡角色索引
@export var headshot_char_index_1: int = 5     ## 爆头死亡帧1
@export var headshot_char_index_2: int = 6     ## 爆头死亡帧2（最终保持）
@export var headshot_pause_frames: int = 20    ## 爆头动画暂停帧数

@export_group("音效")
@export var hurt_sound: AudioStream = null
@export var death_sound: AudioStream = null
@export var headshot_sound: AudioStream = null
@export var headshot_fall_sound: AudioStream = null
@export var attack_sound: AudioStream = null
@export var discover_sound: AudioStream = null

@export_group("动画特效")
## 攻击命中时的特效场景，拖入 anim/ 目录下的 .tscn 文件
@export var attack_effect_anim: PackedScene = null
## 攻击特效是否跟随玩家实体移动（开启后特效每帧跟随玩家位置）
@export var attack_effect_follow: bool = false
## 攻击特效位置偏移覆盖（非零时替换 .tscn 内置的 position_offset）
@export var attack_effect_offset_override: Vector2 = Vector2.ZERO

# ═══════════════════════════════════════
# 运行时状态
# ═══════════════════════════════════════
var current_hp: float = 100.0
var _facing: int = FaceDir.DOWN
var _anim_step: int = 0
var _moving: bool = false
var _player_ref: CharacterBody2D = null       ## 发现的玩家引用
var _player_in_sight: bool = false
var _is_dead: bool = false                     ## 是否已死亡
var _knockback_dir: Vector2 = Vector2.ZERO     ## 击退方向（由 take_damage 设置）
var _knockback_force: float = 0.0              ## 击退力度
var _knockback_stun: float = 0.0               ## 击退硬直时长
var _hitstun_duration: float = 0.0             ## 命中硬直时长（无击退位移）
var _recent_damage_sources: Dictionary = {}    ## source_id → hit_time_msec（防同一源头重复判定）

## 联机表现层：Host 保持 AI 与伤害权威；Client 只接收并渲染快照。
var network_entity_id: int = 0
var network_presentation_only: bool = false
var _network_target_position: Vector2 = Vector2.ZERO
var _network_has_target: bool = false
var _network_headshot_death: bool = false
var _current_char_index: int = 0

# ═══════════════════════════════════════
# A* 调试字段（由 EnemyChaseState 写入，_draw() 读取）
# ═══════════════════════════════════════
var _debug_path: Array = []
var _debug_path_found: bool = false
var _debug_start_grid: Vector2i = Vector2i.ZERO
var _debug_end_grid: Vector2i = Vector2i.ZERO
var _debug_start_walkable: bool = false
var _debug_end_walkable: bool = false
var _debug_astar_iters: int = 0
var _debug_walk_cache: Dictionary = {}
var _debug_path_idx: int = 0
var _debug_cell_size: float = 32.0  ## 由 EnemyChaseState 在 enter() 中设置

# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════
@onready var sprite: Sprite2D = $Sprite2D
@onready var animation_timer: Timer = $AnimationTimer
@onready var vision_area: Area2D = $VisionArea
@onready var discover_label: Label = $DiscoverLabel
@onready var hurt_area: Area2D = _setup_hurt_area()


func _ready() -> void:
	current_hp = max_hp
	_facing = initial_facing
	# 俯视角：浮动模式，所有碰撞都是墙壁
	motion_mode = MOTION_MODE_FLOATING
	# 敌人之间正常碰撞（move_and_collide 滑墙会自然推开）
	_update_facing_sprite()

	# 加入敌人组（用于友军伤害等场景查找）
	add_to_group("enemy")

	if animation_timer:
		animation_timer.wait_time = walk_frame_duration
		animation_timer.timeout.connect(_on_animation_timer_timeout)
		animation_timer.start()

	if discover_label:
		discover_label.hide()

	_refresh_sprite()
	if network_presentation_only:
		_disable_network_simulation()


func _process(delta: float) -> void:
	if network_presentation_only:
		if _network_has_target:
			global_position = global_position.lerp(_network_target_position, minf(delta * 16.0, 1.0))
		if Global.debug_visuals:
			queue_redraw()
		return
	if Global.debug_visuals:
		queue_redraw()


# ═══════════════════════════════════════
# 联机表现接口（由 NetworkWorld 调用）
# ═══════════════════════════════════════

## entity_id 为 Host 分配的稳定实体 ID。presentation_only=true 时关闭本地 AI/判定。
func configure_network_entity(entity_id: int, presentation_only: bool) -> void:
	network_entity_id = entity_id
	network_presentation_only = presentation_only
	velocity = Vector2.ZERO
	if network_presentation_only and is_node_ready():
		_disable_network_simulation()


## Client 专用：应用 Host 快照；位置在 _process 中平滑，攻击/死亡帧由 Host 当前角色索引驱动。
func apply_network_presentation(new_position: Vector2, new_facing: int, moving: bool, hp: float, visual_char_index: int, is_dead: bool, is_headshot: bool, snap: bool = false) -> void:
	if not network_presentation_only:
		return
	current_hp = clampf(hp, 0.0, max_hp)
	_facing = clampi(new_facing, FaceDir.DOWN, FaceDir.UP)
	_network_headshot_death = is_headshot
	if snap:
		global_position = new_position
		_network_target_position = new_position
		_network_has_target = false
	else:
		if not _network_has_target:
			global_position = new_position
		_network_target_position = new_position
		_network_has_target = true

	if is_dead:
		_is_dead = true
		_moving = false
		_disable_network_simulation()
		_refresh_sprite_with_index(visual_char_index if visual_char_index >= 0 else (headshot_char_index_2 if is_headshot else death_char_index))
		return

	_is_dead = false
	update_moving(moving)
	if visual_char_index >= 0 and visual_char_index != walk_char_index:
		_refresh_sprite_with_index(visual_char_index)


func get_network_facing() -> int:
	return _facing


func is_moving_for_network() -> bool:
	return _moving


func get_network_ai_state() -> String:
	if _is_dead:
		return "HeadshotDeath" if _network_headshot_death else "Death"
	var sm: Node = get_node_or_null("StateMachine")
	return sm.current_state.name if sm and sm.current_state else ""


func get_network_visual_char_index() -> int:
	return _current_char_index


func is_network_dead() -> bool:
	return _is_dead


func is_network_headshot_dead() -> bool:
	return _network_headshot_death


## Host 专用：断线玩家释放前清除追击目标，避免状态机读取已释放节点。
func clear_target_if_matches(target: Node) -> void:
	if _player_ref != target:
		return
	_player_ref = null
	_player_in_sight = false
	velocity = Vector2.ZERO
	if _is_dead:
		return
	var sm: Node = get_node_or_null("StateMachine")
	if sm and sm.get_node_or_null("Idle"):
		sm._on_transition_requested("Idle")


func _disable_network_simulation() -> void:
	velocity = Vector2.ZERO
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", true)
	if vision_area:
		vision_area.set_deferred("monitoring", false)
		vision_area.set_deferred("monitorable", false)
	if hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)
	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		sm.process_mode = Node.PROCESS_MODE_DISABLED
	if discover_label:
		discover_label.hide()


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


func guard_dead() -> bool:
	# 检查是否已死亡（HP<=0），如果未标记死亡则触发死亡流程
	# 返回 true 表示敌人已死亡，调用者应立即 return
	if _is_dead:
		return true
	if current_hp <= 0.0:
		_die(false)
		return true
	return false


func _on_animation_timer_timeout() -> void:
	if _moving:
		_anim_step = (_anim_step + 1) % WALK_SEQUENCE.size()
	_refresh_sprite()


# ═══════════════════════════════════════
# 外观
# ═══════════════════════════════════════

func update_facing_from_direction(move_dir: Vector2) -> void:
	if move_dir == Vector2.ZERO:
		return
	var new_facing: int
	if abs(move_dir.x) > abs(move_dir.y):
		new_facing = FaceDir.RIGHT if move_dir.x > 0 else FaceDir.LEFT
	else:
		new_facing = FaceDir.DOWN if move_dir.y > 0 else FaceDir.UP
	if new_facing != _facing:
		_facing = new_facing
		_refresh_sprite()


func set_facing(f: int) -> void:
	_facing = f
	_update_facing_sprite()


func _update_facing_sprite() -> void:
	_refresh_sprite()


func update_moving(moving: bool) -> void:
	_moving = moving
	if not moving:
		_anim_step = 0
	_refresh_sprite()


func get_facing_vector() -> Vector2:
	match _facing:
		FaceDir.DOWN:  return Vector2(0, 1)
		FaceDir.UP:    return Vector2(0, -1)
		FaceDir.LEFT:  return Vector2(-1, 0)
		FaceDir.RIGHT: return Vector2(1, 0)
	return Vector2(0, 1)


## 获取攻击动画每帧持续时间（秒）
## 优先使用 attack_frame_durations[seq_idx]，为空则使用默认值
func get_attack_frame_duration(seq_idx: int) -> float:
	if attack_frame_durations.size() > seq_idx:
		return attack_frame_durations[seq_idx]
	return 0.1


# ═══════════════════════════════════════
# 伤害
# ═══════════════════════════════════════

func take_damage(damage: float, knockback_force: float, direction: Vector2, is_headshot: bool = false, knockback_stun: float = 0.0, hitstun_duration: float = 0.0, source_id: int = 0) -> void:
	if _is_dead:
		return

	# 源头去重 + 调试打印
	if source_id != 0:
		var _now: int = Time.get_ticks_msec()
		_clean_expired_damage_sources(_now)
		if source_id in _recent_damage_sources:
			if _now - _recent_damage_sources[source_id] < DAMAGE_SOURCE_COOLDOWN_MSEC:
				print("[敵人] ★★★ 源头去重拦截！source_id=%d 帧=%d ★★★" % [source_id, Engine.get_physics_frames()])
				return
		_recent_damage_sources[source_id] = _now

	# 提前获取当前状态（用于推击闪白判定）
	var sm: Node = get_node_or_null("StateMachine")
	var current_state: String = sm.current_state.name if sm and sm.current_state else ""

	current_hp = maxf(0.0, current_hp - damage)
	if damage > 0.0:
		print("[敵人] 受到伤害: %d | HP: %.0f/%.0f | 爆头=%s | source=%d" % [int(damage), current_hp, max_hp, str(is_headshot), source_id])
		_play_hit_feedback(Color.RED)
	else:
		print("[敵人] 被推击 | HP: %.0f/%.0f" % [current_hp, max_hp])
		# 已在击退/硬直状态中，不重复播放闪白
		if current_state != "Knockback" and current_state != "Hitstun":
			_play_hit_feedback(Color(3, 3, 3, 1), 0.08)

	# 弹出伤害数字（0 伤害如推击不弹出）
	if damage > 0.0:
		var tree := get_tree()
		if tree and tree.current_scene:
			var dmg_color: Color = Color(1.0, 0.85, 0.2) if is_headshot else Color.WHITE
			DamageNumber.spawn(global_position, damage, tree.current_scene, 0, dmg_color)

	# 播放受伤音效（0 伤害不播放）
	if damage > 0.0:
		_play_sound(hurt_sound)

	# 设置击退参数（所有状态统一设置，包括 Idle）
	var has_knockback: bool = knockback_force > 0.0 and knockback_stun > 0.0
	if has_knockback:
		_knockback_dir = direction.normalized()
		_knockback_force = knockback_force
		_knockback_stun = knockback_stun

	# 设置硬直时长（无击退位移的原地冻结，击退优先）
	var has_hitstun: bool = hitstun_duration > 0.0 and not has_knockback
	if has_hitstun:
		_hitstun_duration = hitstun_duration
		_knockback_dir = direction.normalized()  # 仅用于朝向伤害来源

	# 如果处于 Idle 状态（未发现玩家）→ 被发现 + 击退/Discover
	# 注意：Idle 状态下硬直不生效，先进 Discover（"！"发现玩家）
	if current_state == "Idle":
		_try_find_player()
		update_facing_from_direction(-direction)
		_play_sound(discover_sound)

		if current_hp <= 0.0:
			_die(is_headshot)
			return

		if sm:
			if has_knockback and sm.get_node_or_null("Knockback"):
				sm._on_transition_requested("Knockback")
			else:
				sm._on_transition_requested("Discover")
		return

	if current_hp <= 0.0:
		_die(is_headshot)
		return

	# 击退/硬直判定（非 Idle 状态）
	# 硬直仅在追击状态下生效，攻击/发现状态不跳过
	if sm:
		var blocked_states: Array[String] = ["Knockback", "Death", "HeadshotDeath"]
		if has_knockback and not current_state in blocked_states:
			if sm.get_node_or_null("Knockback"):
				sm._on_transition_requested("Knockback")
			else:
				print("[敵人] StateMachine 中未找到 Knockback 状态节点")
		elif has_hitstun and current_state == "Chase":
			if sm.get_node_or_null("Hitstun"):
				sm._on_transition_requested("Hitstun")
			else:
				print("[敵人] StateMachine 中未找到 Hitstun 状态节点")


func _clean_expired_damage_sources(now: int) -> void:
	## 清理超过冷却时间的伤害源记录，防止字典无限增长
	var to_erase: Array[int] = []
	for sid: int in _recent_damage_sources:
		if now - _recent_damage_sources[sid] >= DAMAGE_SOURCE_COOLDOWN_MSEC:
			to_erase.append(sid)
	for sid: int in to_erase:
		_recent_damage_sources.erase(sid)

## 播放受击反馈（闪红/渐隐/闪白）
## hit_color: 变色目标颜色（受击=红，推击=亮白）
## duration: 持续时间（秒），<0 则使用节点默认 hit_feedback_duration
func _play_hit_feedback(hit_color: Color = Color.RED, duration: float = -1.0) -> void:
	if duration < 0.0:
		duration = hit_feedback_duration
	if not sprite:
		return
	# 终止已有的反馈 tween
	if has_meta("_hf_tween"):
		var old: Tween = get_meta("_hf_tween")
		if old and old.is_valid():
			old.kill()
	if hit_feedback_mode == 0:
		# 闪模式：瞬间变色 → 渐变恢复
		var tween := create_tween()
		set_meta("_hf_tween", tween)
		tween.tween_property(sprite, "modulate", hit_color, 0.0)
		tween.tween_property(sprite, "modulate", Color.WHITE, duration)
	else:
		# 渐隐模式：变色 → 颜色渐渐消失
		sprite.modulate = hit_color
		var tween := create_tween()
		set_meta("_hf_tween", tween)
		tween.tween_property(sprite, "modulate", Color.WHITE, duration)
	print("[受击反馈] color=%s duration=%.2fs mode=%d" % [hit_color, duration, hit_feedback_mode])


func _die(is_headshot: bool) -> void:
	_is_dead = true
	_network_headshot_death = is_headshot
	print("[敵人] 死亡！类型=%s" % ("爆头" if is_headshot else "普通"))

	if is_headshot:
		_play_sound(headshot_sound)
	else:
		_play_sound(death_sound)

	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		var death_state_name: String = "HeadshotDeath" if is_headshot else "Death"
		if sm.get_node_or_null(death_state_name):
			sm._on_transition_requested(death_state_name)
		else:
			_become_corpse(is_headshot)


func _become_corpse(is_headshot: bool) -> void:
	_network_headshot_death = is_headshot
	_disable_for_corpse()

	if is_headshot:
		_refresh_sprite_with_index(headshot_char_index_1)
		_play_sound(headshot_fall_sound)
		var delay_timer: Timer = Timer.new()
		delay_timer.wait_time = headshot_pause_frames / 60.0
		delay_timer.one_shot = true
		delay_timer.timeout.connect(_on_headshot_delay_done.bind(delay_timer))
		add_child(delay_timer)
		delay_timer.start()
	else:
		_refresh_sprite_with_index(death_char_index)

	_register_corpse()


func _on_headshot_delay_done(timer: Timer) -> void:
	_refresh_sprite_with_index(headshot_char_index_2)
	timer.queue_free()


func _disable_for_corpse() -> void:
	if $CollisionShape2D:
		$CollisionShape2D.set_deferred("disabled", true)
	if vision_area:
		vision_area.set_deferred("monitoring", false)
		vision_area.set_deferred("monitorable", false)
	if hurt_area:
		hurt_area.set_deferred("monitoring", false)
		hurt_area.set_deferred("monitorable", false)
	var sm: Node = get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)
	if animation_timer:
		animation_timer.stop()
	if discover_label:
		discover_label.hide()
	_moving = false
	velocity = Vector2.ZERO


func _register_corpse() -> void:
	if not Global:
		return
	Global.register_corpse(self)


# ═══════════════════════════════════════
# 玩家查找
# ═══════════════════════════════════════

## 判断目标是否为玩家（仅玩家拥有 get_weapon_data 方法）
func _is_player_body(body: Node) -> bool:
	if not body is CharacterBody2D:
		return false
	return body.has_method("get_weapon_data") and body != self


func _try_find_player() -> void:
	if vision_area:
		var bodies: Array[Node2D] = vision_area.get_overlapping_bodies()
		for body: Node2D in bodies:
			if _is_player_body(body):
				_player_ref = body
				_player_in_sight = true
				print("[敵人] 从 VisionArea 找到玩家: %s" % body.name)
				return

	_player_ref = _find_player_in_scene()
	if _player_ref:
		_player_in_sight = true
		print("[敵人] 从场景树找到玩家: %s" % _player_ref.name)


func _find_player_in_scene() -> CharacterBody2D:
	return Players.nearest_entity_to(global_position) as CharacterBody2D


## 被枪声惊动（由玩家开火时调用）。
## 仅影响尚未发现玩家的敌人（Idle 状态）。
func alert_by_gunshot(shooter: Node2D) -> void:
	if _is_dead:
		return
	if _player_ref != null:
		return  # 已经发现玩家，不需要重复惊动
	_player_ref = shooter as CharacterBody2D
	var sm := get_node_or_null("StateMachine") as StateMachine
	if sm and sm.current_state and sm.current_state.name == "Idle":
		print("[敌人] %s 被枪声惊动！" % name)
		sm._on_transition_requested("Discover")

# ═══════════════════════════════════════
# 视野检测
# ═══════════════════════════════════════

func _on_vision_area_body_entered(body: Node2D) -> void:
	if _is_dead:
		return
	if _is_player_body(body):
		if _is_in_vision_cone(body):
			_player_in_sight = true
			_player_ref = body


func _on_vision_area_body_exited(body: Node2D) -> void:
	if body == _player_ref:
		_player_in_sight = false


func _is_in_vision_cone(target: Node2D) -> bool:
	var dir_to: Vector2 = target.global_position - global_position
	var dist: float = dir_to.length()
	if dist > vision_range:
		return false
	var forward: Vector2 = get_facing_vector()
	var angle: float = rad_to_deg(dir_to.normalized().angle_to(forward))
	return abs(angle) < vision_angle / 2.0


# ═══════════════════════════════════════
# 精灵渲染
# ═══════════════════════════════════════

func set_attack_char_index(char_idx: int) -> void:
	_anim_step = 0
	_refresh_sprite_with_index(char_idx)


func _refresh_sprite() -> void:
	if not sprite or not walk_texture:
		return
	if _is_dead:
		return
	sprite.texture = walk_texture
	var frame: int = STAND_FRAME if not _moving else WALK_SEQUENCE[_anim_step]
	_current_char_index = walk_char_index
	_draw_sprite_rect(walk_char_index, frame)


func _refresh_sprite_with_index(char_idx: int) -> void:
	if not sprite or not walk_texture:
		return
	sprite.texture = walk_texture
	_current_char_index = char_idx
	_draw_sprite_rect(char_idx, STAND_FRAME)


func _draw_sprite_rect(char_idx: int, frame: int) -> void:
	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var dir_row: int = DIR_ROWS[_facing]
	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


# ═══════════════════════════════════════
# 音效工具
# ═══════════════════════════════════════

func _play_sound(stream: AudioStream) -> void:
	if not stream:
		return
	Global.play_sfx_managed(stream, self)


# ═══════════════════════════════════════
# Debug 可视化
# ═══════════════════════════════════════

func _draw() -> void:
	if not Global.debug_visuals:
		return

	var cs: CollisionShape2D = $CollisionShape2D
	var color: Color = Color.GRAY if _is_dead else Color.RED
	var shape: Shape2D = cs.shape
	if shape is RectangleShape2D:
		var rect: RectangleShape2D = shape as RectangleShape2D
		var pos: Vector2 = cs.position
		draw_rect(Rect2(pos - rect.size / 2, rect.size), color, false, 1.0)

	if _is_dead:
		var bar_w: float = 48.0
		var bar_h: float = 4.0
		var bar_y: float = -40.0
		draw_rect(Rect2(-bar_w / 2, bar_y, bar_w, bar_h), Color.GRAY, true)
		return

	var forward: Vector2 = get_facing_vector()
	var half_angle: float = deg_to_rad(vision_angle / 2.0)
	var segments: int = 16
	var points: PackedVector2Array = PackedVector2Array()
	points.append(Vector2.ZERO)
	for i: int in range(segments + 1):
		var a: float = -half_angle + (2.0 * half_angle) * float(i) / float(segments)
		points.append(forward.rotated(a) * vision_range)
	draw_polygon(points, PackedColorArray([Color(1, 1, 0, 0.1)]))

	var left_edge: Vector2 = forward.rotated(-half_angle) * vision_range
	var right_edge: Vector2 = forward.rotated(half_angle) * vision_range
	draw_line(Vector2.ZERO, left_edge, Color(1, 1, 0, 0.3))
	draw_line(Vector2.ZERO, right_edge, Color(1, 1, 0, 0.3))
	draw_arc(Vector2.ZERO, vision_range, -half_angle, half_angle, 16, Color(1, 1, 0, 0.3))

	# 攻击命中矩形（attack_hit_range）—— 橙紅，跟随朝向旋转
	var hit_offset: Vector2 = forward * attack_hit_forward_offset
	var hw: float = attack_hit_range.x / 2.0
	var hh: float = attack_hit_range.y / 2.0
	var hit_side: Vector2 = Vector2(-forward.y, forward.x)
	var hit_corners: PackedVector2Array = PackedVector2Array([
			hit_offset + forward * hh + hit_side * hw,
			hit_offset + forward * hh - hit_side * hw,
			hit_offset - forward * hh - hit_side * hw,
			hit_offset - forward * hh + hit_side * hw,
	])
	hit_corners.append(hit_corners[0])
	draw_polyline(hit_corners, Color.ORANGE_RED, 1.0)

	# 攻击触发矩形（attack_range）—— 青色，与判定矩形相同旋转逻辑
	var tr_offset: Vector2 = forward * attack_range_forward_offset
	var tr_hw: float = attack_range.x / 2.0
	var tr_hh: float = attack_range.y / 2.0
	var tr_corners: PackedVector2Array
	if abs(forward.x) > abs(forward.y):
		var side: Vector2 = Vector2(-forward.y, forward.x)
		tr_corners = PackedVector2Array([
			tr_offset + forward * tr_hh + side * tr_hw,
			tr_offset + forward * tr_hh - side * tr_hw,
			tr_offset - forward * tr_hh - side * tr_hw,
			tr_offset - forward * tr_hh + side * tr_hw,
		])
	else:
		tr_corners = PackedVector2Array([
			tr_offset + Vector2(-tr_hw, -tr_hh),
			tr_offset + Vector2( tr_hw, -tr_hh),
			tr_offset + Vector2( tr_hw,  tr_hh),
			tr_offset + Vector2(-tr_hw,  tr_hh),
		])
	tr_corners.append(tr_corners[0])
	draw_polyline(tr_corners, Color.CYAN, 1.0)

	var bar_w: float = 48.0
	var bar_h: float = 4.0
	var bar_y: float = -40.0
	var ratio: float = current_hp / max_hp
	draw_rect(Rect2(-bar_w / 2, bar_y, bar_w, bar_h), Color.RED, false, 1.0)
	draw_rect(Rect2(-bar_w / 2, bar_y, bar_w * ratio, bar_h), Color.RED, true)

	# 绘制受击碰撞体（黄色）
	if hurt_area:
		var hshape_node: CollisionShape2D = hurt_area.get_node_or_null("HurtShape")
		if hshape_node and hshape_node.shape is RectangleShape2D:
			var hs: Vector2 = (hshape_node.shape as RectangleShape2D).size
			var ho: Vector2 = hshape_node.position
			draw_rect(Rect2(ho - hs / 2, hs), Color.YELLOW, false, 1.0)

	# ── A* 调试：绘制路径 ──
	_draw_debug_path()

	# ── A* 调试：绘制可行走网格 ──
	_draw_debug_walk_grid()


func _draw_debug_path() -> void:
	if _debug_path.is_empty():
		return

	# 路径线 — 绿色
	if _debug_path.size() >= 2:
		for i in range(_debug_path.size() - 1):
			var a: Vector2 = _debug_path[i] - global_position
			var b: Vector2 = _debug_path[i + 1] - global_position
			draw_line(a, b, Color.GREEN, 2.0)

	# 路径点 — 绿色小圈
	for wp: Vector2 in _debug_path:
		var lp: Vector2 = wp - global_position
		draw_circle(lp, 3.0, Color.GREEN)
		draw_circle(lp, 4.0, Color.DARK_GREEN, false, 1.0)

	# 下一个目标路径点 — 亮黄色
	if _debug_path_idx < _debug_path.size():
		var target: Vector2 = _debug_path[_debug_path_idx] - global_position
		draw_circle(target, 6.0, Color.YELLOW, false, 2.0)

	# 起点/终点标记（格子坐标 → 世界坐标）
	var cell_half: float = _debug_cell_size / 2.0
	var start_wp: Vector2 = Vector2(_debug_start_grid.x * _debug_cell_size + cell_half, _debug_start_grid.y * _debug_cell_size + cell_half) - global_position
	var end_wp: Vector2 = Vector2(_debug_end_grid.x * _debug_cell_size + cell_half, _debug_end_grid.y * _debug_cell_size + cell_half) - global_position
	draw_rect(Rect2(start_wp - Vector2(6, 6), Vector2(12, 12)), Color.BLUE, false, 2.0)
	draw_rect(Rect2(end_wp - Vector2(6, 6), Vector2(12, 12)), Color.RED, false, 2.0)

	# 路径状态文字
	var status: String = "OK:%d" % _debug_path.size() if _debug_path_found else "FAIL(iters:%d)" % _debug_astar_iters
	draw_string(ThemeDB.fallback_font, Vector2(20, -50), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.GREEN if _debug_path_found else Color.RED)


func _draw_debug_walk_grid() -> void:
	if _debug_walk_cache.is_empty():
		return

	var cell_half: float = _debug_cell_size / 2.0
	var cs: float = _debug_cell_size

	# 性能优化：按可见范围计算网格坐标遍历，而非遍历整个缓存字典
	# 预构建后缓存可能包含全图数万格子，遍历字典每帧极卡
	var view_range: int = 6  ## 格子数（约 192px @ 32px/cell）
	var center_gp: Vector2i = Vector2i(floori(global_position.x / cs), floori(global_position.y / cs))

	for dx in range(-view_range, view_range + 1):
		for dy in range(-view_range, view_range + 1):
			var gp: Vector2i = Vector2i(center_gp.x + dx, center_gp.y + dy)
			if not _debug_walk_cache.has(gp):
				continue
			var world: Vector2 = Vector2(gp.x * cs + cell_half, gp.y * cs + cell_half)
			var local: Vector2 = world - global_position

			var walkable: bool = _debug_walk_cache[gp]
			if walkable:
				draw_rect(Rect2(local - Vector2(cell_half, cell_half), Vector2(cs, cs)), Color(0, 1, 0, 0.08), true)
			else:
				draw_rect(Rect2(local - Vector2(cell_half, cell_half), Vector2(cs, cs)), Color(1, 0, 0, 0.15), true)
				draw_line(local + Vector2(-4, -4), local + Vector2(4, 4), Color.RED, 1.0)
				draw_line(local + Vector2(-4, 4), local + Vector2(4, -4), Color.RED, 1.0)
