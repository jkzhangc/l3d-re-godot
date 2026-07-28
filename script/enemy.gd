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


func _process(_delta: float) -> void:
	if Global.debug_visuals:
		queue_redraw()


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

func take_damage(damage: float, knockback_force: float, direction: Vector2, is_headshot: bool = false, knockback_stun: float = 0.0, hitstun_duration: float = 0.0) -> void:
	if _is_dead:
		return

	current_hp = maxf(0.0, current_hp - damage)
	print("[敵人] 受到伤害: %d | HP: %.0f/%.0f | 爆头=%s" % [int(damage), current_hp, max_hp, str(is_headshot)])

	# 弹出伤害数字（白/金色调，爆头用亮黄色）
	var tree := get_tree()
	if tree and tree.current_scene:
		var dmg_color: Color = Color(1.0, 0.85, 0.2) if is_headshot else Color.WHITE
		DamageNumber.spawn(global_position, damage, tree.current_scene, 0, dmg_color)

	# 播放受伤音效
	_play_sound(hurt_sound)

	var sm: Node = get_node_or_null("StateMachine")
	var current_state: String = sm.current_state.name if sm and sm.current_state else ""

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


func _die(is_headshot: bool) -> void:
	_is_dead = true
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
	var tree: SceneTree = get_tree()
	if not tree:
		return null
	var root: Window = tree.root
	if not root:
		return null
	return _find_player_recursive(root)


func _find_player_recursive(node: Node) -> CharacterBody2D:
	if _is_player_body(node):
		if node.collision_layer & 4:
			return node
	for child: Node in node.get_children():
		var found: CharacterBody2D = _find_player_recursive(child)
		if found:
			return found
	return null

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
	_draw_sprite_rect(walk_char_index, frame)


func _refresh_sprite_with_index(char_idx: int) -> void:
	if not sprite or not walk_texture:
		return
	sprite.texture = walk_texture
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
