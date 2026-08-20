extends Node2D
## 子弹实体 — 由远程武器射击生成

signal finished(network_entity_id: int)
##
## 使用单张水平帧条图片渲染：
##   图片被均分为 bullet_anim_frames 列，每帧宽 = 图宽 / 帧数，高 = 图高
##   精灵旋转跟随飞行方向（图片默认朝向为 DOWN，rotation = angle - PI/2）

# ═══════════════════════════════════════
# 公开参数（由武器/生成者设置）
# ═══════════════════════════════════════
var direction: Vector2 = Vector2.RIGHT
var speed: float = 300.0
var max_range: float = 300.0
var damage: float = 0.0
var destroy_on_hit: bool = true
var penetration: int = 0
var critical_rate: float = 0.0             ## 暴击率 (0-100)

# 外观 — 动画帧条
var _bullet_texture: Texture2D = null
var _bullet_anim_frames: int = 1            ## 水平帧数
var _bullet_frame_duration: int = 1         ## 每帧持续物理帧数
var _anim_counter: int = 0                  ## 物理帧计数（达到 frame_duration 时切帧）
var _current_frame: int = 0                 ## 当前动画帧索引

# 击退（可由 BulletData 设置）
var _knockback_force: float = 0.0
var _knockback_stun: float = 0.0

# 硬直（可由 BulletData 设置）
var _hitstun_duration: float = 0.0

# 碰撞体（可由 BulletData 覆盖）
var _collision_size: Vector2 = Vector2(24, 28)
var _collision_offset: Vector2 = Vector2.ZERO

# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var network_entity_id: int = 0
var network_visual_only: bool = false
var _finished: bool = false
var _distance_traveled: float = 0.0
var _hits: int = 0
var _hit_targets: Dictionary = {}   ## instance_id → true（永久标记，防止重复命中同一目标）
var _shooter: Node2D = null         ## 发射者引用（防止击中自己）


var _hit_effect_anim: PackedScene = null  ## 命中时播放的特效场景
var _hit_effect_follow: bool = false  ## 命中特效是否跟随目标
var _hit_effect_offset_override: Vector2 = Vector2.ZERO  ## 命中特效偏移覆盖
var _hit_sound: AudioStream = null  ## 命中时播放的音效
# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════
@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D


func _ready() -> void:
	if _area:
		if network_visual_only:
			# Client 只外推视觉子弹，绝不参与共享碰撞或伤害判定。
			_area.monitoring = false
			_area.monitorable = false
			_area.collision_layer = 0
			_area.collision_mask = 0
		else:
			_area.area_entered.connect(_on_area_entered)
			_area.body_entered.connect(_on_body_entered)
	_refresh_sprite()
	_update_area_rotation()


func setup(params: Dictionary) -> void:
	## 从字典批量设置参数（由武器生成代码调用）
	direction = params.get("direction", Vector2.RIGHT)
	speed = params.get("speed", 300.0)
	max_range = params.get("max_range", 300.0)
	damage = params.get("damage", 0.0)
	destroy_on_hit = params.get("destroy_on_hit", true)
	penetration = params.get("penetration", 0)
	critical_rate = params.get("critical_rate", 0.0)
	network_entity_id = int(params.get("network_entity_id", 0))
	network_visual_only = bool(params.get("network_visual_only", false))
	_bullet_texture = params.get("texture", null)
	_bullet_anim_frames = params.get("anim_frames", 1)
	_bullet_frame_duration = params.get("frame_duration", 1)
	# 碰撞体（>0 则覆盖默认值）
	var cs: Vector2 = params.get("collision_size", Vector2.ZERO)
	if cs != Vector2.ZERO:
		_collision_size = cs
	_collision_offset = params.get("collision_offset", Vector2.ZERO)
	_knockback_force = params.get("knockback_force", 0.0)
	_knockback_stun = params.get("knockback_stun", 0.0)
	_hitstun_duration = params.get("hitstun_duration", 0.0)
	_hit_effect_anim = params.get("hit_effect_anim", null)
	_hit_effect_follow = params.get("hit_effect_follow", false)
	_hit_effect_offset_override = params.get("hit_effect_offset_override", Vector2.ZERO)
	_hit_sound = params.get("hit_sound", null)
	_shooter = params.get("shooter", null)
	_apply_collision_shape()
	_refresh_sprite()
	_update_area_rotation()


func _process(_delta: float) -> void:
	if Global.debug_visuals:
		queue_redraw()


func _physics_process(delta: float) -> void:
	var step: float = speed * delta
	position += direction * step
	_distance_traveled += step

	# 动画帧更新
	if _bullet_anim_frames > 1:
		_anim_counter += 1
		if _anim_counter >= _bullet_frame_duration:
			_anim_counter = 0
			_current_frame = (_current_frame + 1) % _bullet_anim_frames
			_refresh_sprite()

	if _distance_traveled >= max_range:
		_finish()


func _on_area_entered(area: Area2D) -> void:
	print("[子弹] area_entered: %s (parent=%s)" % [area.name, area.get_parent().name if area.get_parent() else "null"])
	_hit(area.get_parent() if area.get_parent() else area)


func _on_body_entered(body: Node2D) -> void:
	print("[子弹] body_entered: %s" % body.name)
	_hit(body)


func _hit(target: Node2D) -> void:
	## 击中目标的默认处理 — 子类或外部可覆写
	if target == null:
		return

	# 解析真正的可伤害目标（如果传入的是受击碰撞体 Area2D，取其父节点）
	var damageable: Node2D = target
	if not target.has_method("take_damage") and target.get_parent() and target.get_parent().has_method("take_damage"):
		damageable = target.get_parent()

	if not damageable.has_method("take_damage"):
		return

	# 防止击中发射者自己
	if _shooter and damageable == _shooter:
		return

	# 去重：永久标记已命中目标，绝不对同一目标重复判定
	var tid: int = damageable.get_instance_id()
	if tid in _hit_targets:
		print("[子弹] *** 去重拦截！tid=%d name=%s ***" % [tid, damageable.name])
		return
	_hit_targets[tid] = true
	print("[子弹] 去重记录: tid=%d name=%s (累计=%d)" % [tid, damageable.name, _hit_targets.size()])

	# 跳过已死亡的目标（尸体不挡子弹、不消耗穿透）
	if damageable.get("_is_dead") == true or damageable.get("_is_dying") == true:
		return

	_hits += 1

	# 掷骰判定暴击（爆头）
	var is_headshot: bool = _roll_critical()

	# 尝试对目标造成伤害
	# 传递击退参数 + 硬直时长 + 源头ID（供目标侧去重）
	print("[子弹] >>> 造成伤害！tid=%d name=%s damage=%d <<<" % [tid, damageable.name, int(damage)])
	var hp_before: float = float(damageable.get("current_hp")) if damageable.get("current_hp") != null else 0.0
	damageable.take_damage(damage, _knockback_force, direction, is_headshot, _knockback_stun, _hitstun_duration, get_instance_id())
	var hp_after: float = float(damageable.get("current_hp")) if damageable.get("current_hp") != null else hp_before
	_record_chapter_damage(hp_before, hp_after, is_headshot)

	# 播放命中特效
	if _hit_effect_anim:
		var bf: Node2D = damageable if _hit_effect_follow else null
		VXAnimSprite.play_scene(_hit_effect_anim, damageable.global_position, get_tree().current_scene, 10.0, bf, _hit_effect_offset_override)
	# 播放命中音效
	if _hit_sound:
		Global.play_sfx_managed(_hit_sound, get_tree().current_scene)

	print("[子弹] 击中: %s | 伤害=%d | 爆头=%s | 穿透剩余=%d" % [damageable.name, int(damage), str(is_headshot), penetration - _hits + 1])

	if destroy_on_hit and _hits > penetration:
		_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	finished.emit(network_entity_id)
	queue_free()


func _record_chapter_damage(hp_before: float, hp_after: float, is_headshot: bool) -> void:
	if not _shooter:
		return
	var shooter_state: PlayerState = Players.get_state_for_entity(_shooter)
	if not shooter_state:
		return
	var chapter_stats: Node = get_node_or_null("/root/ChapterStats")
	if not chapter_stats:
		return
	var actual_damage: float = maxf(0.0, hp_before - hp_after)
	if chapter_stats.has_method("record_damage_dealt"):
		chapter_stats.record_damage_dealt(shooter_state.seat_index, actual_damage)
	if hp_before > 0.0 and hp_after <= 0.0 and chapter_stats.has_method("record_kill"):
		chapter_stats.record_kill(shooter_state.seat_index, is_headshot)


func _refresh_sprite() -> void:
	## 水平帧条渲染：图片均分为 bullet_anim_frames 列
	## 精灵朝向 = 飞行方向（图片默认朝 RIGHT，即 0°）
	if not _sprite or not _bullet_texture:
		return

	_sprite.texture = _bullet_texture
	_sprite.region_enabled = true

	var tex_w: float = _bullet_texture.get_width()
	var tex_h: float = _bullet_texture.get_height()
	var frame_w: float = tex_w / float(_bullet_anim_frames)

	_sprite.region_rect = Rect2(_current_frame * frame_w, 0, frame_w, tex_h)
	# 旋转精灵指向飞行方向（图片默认朝向为 DOWN，需 -PI/2 补偿）
	_sprite.rotation = direction.angle() - PI / 2.0


func _update_area_rotation() -> void:
	## 让 Area2D 碰撞体跟随子弹方向旋转（参考敌人攻击矩形旋转）
	## 优先用 _area 缓存引用，若未初始化则用 $ 路径（setup 在 add_child 前调用）
	var area: Area2D = _area if _area else $Area2D
	if area:
		area.rotation = direction.angle()


func _apply_collision_shape() -> void:
	## 应用碰撞体尺寸和偏移（由 setup() 在 _update_area_rotation 之前调用）
	## 注意：setup() 在 add_child() 之前调用，此时 @onready 未初始化，
	##       必须用 $ 路径而非 _area 缓存引用。
	var shape_node: CollisionShape2D = $Area2D/CollisionShape2D
	if not shape_node:
		return
	var shape: Shape2D = shape_node.shape
	if shape is RectangleShape2D:
		(shape as RectangleShape2D).size = _collision_size
		print("[子弹] 碰撞体尺寸已更新: %s | 偏移: %s" % [_collision_size, _collision_offset])
	else:
		print("[子弹] _apply_collision_shape: shape 不是 RectangleShape2D, 类型=%s" % shape.get_class())
	shape_node.position = Vector2.ZERO
	# 将 Area2D 节点移到精灵中心，避免 offset 随 Area2D 旋转偏移
	var _area_node: Area2D = $Area2D
	if _area_node:
		_area_node.position = _collision_offset


func _draw() -> void:
	## 调试可视化：绘制子弹碰撞体（跟随 Area2D 旋转 + 偏移）
	if not Global.debug_visuals:
		return
	if not _area:
		return

	var shape_node: CollisionShape2D = $Area2D/CollisionShape2D
	var shape: Shape2D = shape_node.shape
	if shape is RectangleShape2D:
		var s: Vector2 = (shape as RectangleShape2D).size
		var offset: Vector2 = _area.position
		draw_set_transform(offset, _area.rotation)
		draw_rect(Rect2(-s / 2, s), Color.CYAN, false, 1.0)
		draw_set_transform(Vector2.ZERO, 0.0)


func _roll_critical() -> bool:
	## 掷骰判定是否暴击（爆头）
	if critical_rate <= 0.0:
		return false
	if critical_rate >= 100.0:
		return true
	return randf() * 100.0 < critical_rate
