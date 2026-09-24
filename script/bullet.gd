extends Node2D

## ── 架构定位 ──
## 系统：子弹 ｜ 层：玩法（Node2D）
## 联机：Host 权威伤害，Client 仅轨迹
## 职责：子弹运行时对象：分帧精灵渲染、飞行与碰撞、命中结算、暴击判定与章节统计。
## 依赖：BulletData、敌人伤害接口、ChapterStats、NetworkWorld（联机 ID 白名单）

## 子弹运行时对象：移动、碰撞和伤害由单机本地或联机 Host 权威执行。
## Client 的同名节点只负责轨迹表现，不能再次对敌人结算伤害；网络传输使用白名单 ID 和索引。
## 子弹实体 — 由远程武器射击生成

signal finished(network_entity_id: int)
## 爆炸发生（仅单机/Host 的权威子弹会触发）。NetworkWorld 用它把爆心坐标广播给 Client：
## 客户端镜像子弹关闭了碰撞与扫掠（network_visual_only），只能靠本事件在**爆心**位置
## 播爆炸表现 —— 否则爆炸特效只能落在镜像子弹的射程尽头，与真正命中点差出几十像素。
signal exploded(network_entity_id: int, position: Vector2)
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
var _critical_damage: float = 2.0          ## 暴击伤害倍率（来自 WeaponData.critical_damage）
var element: int = 0                       ## 属性（WeaponData.Element），命中时传给敌人抗性结算

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

# 覚醒「集中射撃」附带：即死・怯み（命中时结算；tank_enemies 组 Boss 免疫即死 → 伤害×1.5+怯み）
var _instant_kill: bool = false

# 爆炸（グレネードランチャー等爆発物）：命中/到射程/撞墙时原地爆炸
var _explosion_radius: float = 0.0
var _explosion_hurts_players: bool = true
var _explosion_player_radius: float = 0.0   ## 对玩家的自爆半径（2026-09-15）。0=同 _explosion_radius
var _breaks_blast_wall: bool = false        ## 能否炸开可爆破墙（2026-09-16）：默认 false，只有炸药类配 true
var _explode_effect_anim: PackedScene = null
var _explode_sound: AudioStream = null
var _exploded: bool = false

# 伤害源 ID：自增序列（2026-09-15）。原先用 get_instance_id()——对象释放后 ID 会被
# 回收复用，快速连射时新子弹撞上旧 ID → 玩家 take_damage 的 1s 去重窗口把自爆伤害
# 静默吞掉（表现为「离爆炸很近却不受伤」）。自增序列全局唯一，去重只按真实重复命中生效。
static var _next_source_id: int = 1
var _source_id: int = 0

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
var _spawn_offset: float = 0.0      ## 生成点前方偏移（扫掠起点回溯用，2026-09-16）
var _swept_once: bool = false       ## 首帧扫掠已执行（回溯到枪口）


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
			# 玩家弹组（2026-09-17）：敌方酸弹靠它识别并相消（layer_7「玩家弹」同用途）。
			_area.add_to_group("player_bullets")
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
	_critical_damage = params.get("critical_damage", 2.0)
	element = int(params.get("element", 0))
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
	_instant_kill = bool(params.get("instant_kill", false))
	_explosion_radius = float(params.get("explosion_radius", 0.0))
	_explosion_hurts_players = bool(params.get("explosion_hurts_players", true))
	_explosion_player_radius = float(params.get("explosion_player_radius", 0.0))
	_breaks_blast_wall = bool(params.get("breaks_blast_wall", false))
	_spawn_offset = float(params.get("spawn_offset", 0.0))
	_explode_effect_anim = params.get("explode_effect_anim", null)
	_explode_sound = params.get("explode_sound", null)
	_hit_effect_anim = params.get("hit_effect_anim", null)
	_hit_effect_follow = params.get("hit_effect_follow", false)
	_hit_effect_offset_override = params.get("hit_effect_offset_override", Vector2.ZERO)
	_hit_sound = params.get("hit_sound", null)
	_shooter = params.get("shooter", null)
	_source_id = _next_source_id
	_next_source_id += 1
	_apply_collision_shape()
	_refresh_sprite()
	_update_area_rotation()


func _process(_delta: float) -> void:
	if Global.debug_visuals:
		queue_redraw()


func _physics_process(delta: float) -> void:
	if _finished:
		return
	var step: float = speed * delta
	## 扫掠判定（2026-09-16）：Area2D 只在物理帧边界采样重叠，而子弹每帧位移 16~20px，
	## 首个采样点 = spawn_offset(24) + 一帧位移 → 贴脸目标（受击盒中心 <30px）整帧被跳过。
	## 实测：马格南贴脸 12px 必漏判；手枪/霰弹只有 1px 余量（"有时候打不到"）。
	## 改为每帧从上一位置扫到新位置；首帧起点回溯到枪口（生成点 - 朝向×spawn_offset），
	## 把"子弹生成时已在敌人身后"的贴脸情形一并盖住。命中仍走同一条 _hit()（去重/穿透通用）。
	var sweep_from: Vector2 = position
	var muzzle_escape: bool = false
	if not _swept_once and _spawn_offset > 0.0:
		sweep_from = position - direction * _spawn_offset
		## 枪口脱困（2026-09-16 用户复现）：玩家贴着墙（墙在身侧/头顶）朝平行方向开枪时，
		## 枪口点本身落在墙格里 → 起点点查询撞到墙 → 子弹一出膛就被自己脚下的墙吃掉。
		## 首帧允许忽略"包住枪口的墙"，让它先飞出格再照常判定（下一格墙仍然会挡）。
		muzzle_escape = true
	_swept_once = true
	var sweep_to: Vector2 = position + direction * step
	## 先就位再扫掠：命中/爆炸（_explode 用 global_position 作爆心）落在本帧实际位置，
	## 与旧实现（Area2D 在移动后的位置结算重叠）保持一致。
	position = sweep_to
	_sweep(sweep_from, sweep_to, muzzle_escape)
	if _finished:
		return
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


## 线段扫掠：从 from 到 to 依次取最近碰撞体，交给 _hit 结算（可穿透）。
## 只认 HurtArea（受击盒）与可伤害体；图块墙按原规则挡下并触发爆炸。
## muzzle_escape = 首帧从枪口起扫，且允许忽略"把枪口包在里面的那堵墙"（贴墙开枪脱困）。
func _sweep(from: Vector2, to: Vector2, muzzle_escape: bool = false) -> void:
	if network_visual_only or _finished:
		return
	if not _area or _area.collision_mask == 0:
		return
	## 尊重"人为关掉碰撞"的约定（network_visual_only 之外，测试/harness 也会用
	## monitoring=false 屏蔽某颗子弹的自动命中）——扫掠不能绕过它。
	if not _area.monitoring:
		return
	if from.is_equal_approx(to):
		return
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	if space == null:
		return
	var start: Vector2 = from
	var exclude: Array[RID] = []
	if _shooter is CollisionObject2D:
		exclude.append((_shooter as CollisionObject2D).get_rid())

	## ① 起点已在碰撞体内（贴脸：生成点/枪口落在敌人身上）——
	##    Godot 的 intersect_ray 不报"射线起点位于形状内部"的命中，
	##    必须先用点查询补这一格，否则贴脸依旧漏判（实测 12px 马格南）。
	var point_query := PhysicsPointQueryParameters2D.new()
	point_query.position = from
	point_query.collision_mask = _area.collision_mask
	point_query.collide_with_areas = true
	point_query.collide_with_bodies = true
	point_query.exclude = exclude
	for info: Dictionary in space.intersect_point(point_query, 16):
		if _finished:
			return
		var hit_col: Object = info.get("collider")
		exclude.append(info.get("rid") as RID)
		if hit_col is Node2D:
			## 枪口脱困：起点落在"不可伤害的墙"里 → 忽略这堵墙（继续扫掠），
			## 否则贴墙开枪时子弹一出膛就被脚下的墙吃掉（用户 2026-09-16 复现）。
			if muzzle_escape and not _is_damageable(hit_col):
				continue
			if not _handle_swept_collider(hit_col):
				return
	if _finished:
		return

	## ② 沿线扫掠：最多取 8 个碰撞体（穿透上限远小于此值），避免异常情况下死循环
	for _i: int in 8:
		var query := PhysicsRayQueryParameters2D.create(start, to)
		query.collision_mask = _area.collision_mask
		query.collide_with_areas = true
		query.collide_with_bodies = true
		query.exclude = exclude
		var hit_info: Dictionary = space.intersect_ray(query)
		if hit_info.is_empty():
			return
		exclude.append(hit_info.get("rid") as RID)
		var collider: Object = hit_info.get("collider")
		if not _handle_swept_collider(collider):
			return
		if _finished:
			return
		start = (hit_info.get("position") as Vector2) + direction * 1.0


## 该碰撞体是否"可伤害"（自身或其父节点有 take_damage）——墙/静态障碍为 false。
func _is_damageable(collider: Object) -> bool:
	if not (collider is Node2D):
		return false
	var node: Node2D = collider as Node2D
	if node.has_method("take_damage"):
		return true
	var parent: Node = node.get_parent()
	return parent != null and parent.has_method("take_damage")


## 扫掠命中分派：返回 true 表示继续扫掠（穿透/无关触发区），false 表示停止。
func _handle_swept_collider(collider: Object) -> bool:
	if collider is Area2D:
		## 与 _on_area_entered 同规则：只认 HurtArea，其余触发区（视野/事件/拾取）忽略
		if (collider as Area2D).name != "HurtArea":
			return true
	elif not _is_damageable(collider):
		_finish()   ## 图块墙/静态障碍：挡下子弹（爆炸物在此引爆）
		return false
	_hit(collider as Node2D)
	return not _finished


func _on_area_entered(area: Area2D) -> void:
	# 只认受击盒（HurtArea，layer5=16）。mask 含子弹阻挡层(32)后，路上会扫过各系统的
	# 触发区（敌人 VisionArea 半径 200 圈、BossEncounter 检测区等）——它们的父节点
	# 也可能是敌人，不过滤就是"隔空伤害"（用户 2026-09-13 回归：背后/远处的敌人被打）。
	if area.name != "HurtArea":
		return
	print("[子弹] area_entered: %s (parent=%s)" % [area.name, area.get_parent().name if area.get_parent() else "null"])
	_hit(area.get_parent() if area.get_parent() else area)


func _on_body_entered(body: Node2D) -> void:
	print("[子弹] body_entered: %s" % body.name)
	# 图块墙/静态障碍（无 take_damage 链）→ 子弹被墙挡下，穿透无效（2026-09-13 用户回归：
	# 玩家子弹穿图块墙。mask = 敌人|受击盒|子弹阻挡(32)：图块只有在 TileSet 里**标记过
	# 「子弹阻挡」层**才挡子弹（2026-09-16 用户定稿：标记的挡、没标记的穿）。
	if not body.has_method("take_damage") \
			and not (body.get_parent() and body.get_parent().has_method("take_damage")):
		_finish()
		return
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

	# 防止击中发射者自己，以及联机队友互相伤害。必须早于命中去重/穿透计数。
	if _shooter and damageable == _shooter:
		return
	if _shooter and _shooter.is_in_group("player") and damageable.is_in_group("player"):
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

	# 爆発物（Gランチャー等）：不对直击目标单独结算 —— 伤害/击退由 _finish()
	# 里的爆炸对半径内统一给，避免直击+爆炸双倍计伤。
	if _explosion_radius > 0.0:
		_finish()
		return

	_hits += 1

	# 掷骰判定暴击（爆头）；暴击时伤害按倍率放大（数值与黄色数字一致）
	var is_headshot: bool = _roll_critical()
	var final_damage: float = damage * _critical_damage if is_headshot else damage

	# 覚醒「集中射撃」的即死・怯み：
	# 普通敌人 → 伤害拉满即死（走正常死亡路径，尸体/死亡表照常）；
	# tank_enemies 组 Boss → 免疫即死（原作：即死系对 Boss 无效）→ 伤害 ×1.5 + 怯み。
	var hitstun: float = _hitstun_duration
	if _instant_kill:
		if damageable.is_in_group("tank_enemies") or bool(damageable.get("instant_kill_immune")):
			final_damage *= 1.5
			hitstun = maxf(hitstun, 0.8)
		else:
			final_damage = maxf(final_damage, 99999.0)
			hitstun = maxf(hitstun, 0.1)

	# 尝试对目标造成伤害
	# 传递击退参数 + 硬直时长 + 源头ID（供目标侧去重）
	print("[子弹] >>> 造成伤害！tid=%d name=%s damage=%d <<<" % [tid, damageable.name, int(final_damage)])
	var hp_before: float = float(damageable.get("current_hp")) if damageable.get("current_hp") != null else 0.0
	damageable.take_damage(final_damage, _knockback_force, direction, is_headshot, _knockback_stun, hitstun, _source_id, element)
	var hp_after: float = float(damageable.get("current_hp")) if damageable.get("current_hp") != null else hp_before
	_record_chapter_damage(hp_before, hp_after, is_headshot)

	# 播放命中特效
	if _hit_effect_anim:
		var bf: Node2D = damageable if _hit_effect_follow else null
		## 偏移优先级：武器覆盖 > 目标自身 hurt_effect_offset（大体型敌人抬到躯干，2026-09-15）
		var fx_offset := _hit_effect_offset_override
		if fx_offset == Vector2.ZERO and "hurt_effect_offset" in damageable:
			fx_offset = damageable.hurt_effect_offset
		VXAnimSprite.play_scene(_hit_effect_anim, damageable.global_position, get_tree().current_scene, 10.0, bf, fx_offset)
	# 播放命中音效
	if _hit_sound:
		Global.play_sfx_managed(_hit_sound, get_tree().current_scene)

	print("[子弹] 击中: %s | 伤害=%d | 爆头=%s | 穿透剩余=%d" % [damageable.name, int(final_damage), str(is_headshot), penetration - _hits + 1])

	if destroy_on_hit and _hits > penetration:
		_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	# 爆発物：命中 / 撞墙 / 飞到射程尽头都在当前位置爆炸（原作 Gランチャー语义）
	if _explosion_radius > 0.0 and not _exploded:
		_explode()
	finished.emit(network_entity_id)
	queue_free()


## 被敌方酸弹相消（2026-09-17 ブレインディモス）：直接销毁、不触发爆炸/finished 之外的副作用。
## 原作 enemy.html ブレインディモス条：「正面から撃ち合いをすると酸で銃弾を相殺してしまう」。
func cancel_by_enemy_acid() -> void:
	if _finished:
		return
	_finished = true
	queue_free()


func _explode() -> void:
	## 原地爆炸：半径内敌人统一结算（超プッシュ按子弹击退参数），
	## 可波及玩家（自爆，explosion_hurts_players），并引爆 blast_wall。
	## 仅单机/Host 的权威子弹会走到这里（Client 镜像子弹 monitoring 已关，不会命中）。
	_exploded = true
	var center: Vector2 = global_position
	if _explode_effect_anim:
		VXAnimSprite.play_scene(_explode_effect_anim, center, get_tree().current_scene)
	if _explode_sound:
		Global.play_sfx_managed(_explode_sound, get_tree().current_scene)
	# 联机：把爆心与弹丸标识交给 NetworkWorld 广播（Client 用它播同一套爆炸表现）。
	exploded.emit(network_entity_id, center)

	var applied_force: float = _knockback_force if _knockback_force > 0.0 else 300.0
	for e: Node in get_tree().get_nodes_in_group("enemy"):
		if e is not Node2D or not is_instance_valid(e):
			continue
		var enemy := e as Node2D
		if enemy.global_position.distance_to(center) > _explosion_radius:
			continue
		if not enemy.has_method("take_damage"):
			continue
		if enemy.get("_is_dead") == true or enemy.get("_is_dying") == true:
			continue
		var dir: Vector2 = (enemy.global_position - center).normalized() if enemy.global_position != center else Vector2.UP
		# 即死効果在爆炸路径同样生效（2026-09-15 火箭筒）：普通敌人拉满即死；
		# tank_enemies 组 Boss 免疫即死 → 伤害 ×1.5 + 0.8s 怯み（与直击路径同一结算）。
		var blast_damage: float = damage
		var blast_hitstun: float = 0.2
		if _instant_kill:
			if enemy.is_in_group("tank_enemies") or enemy.get("instant_kill_immune") == true:
				blast_damage *= 1.5
				blast_hitstun = 0.8
			else:
				blast_damage = maxf(blast_damage, 99999.0)
				blast_hitstun = 0.1
		var hp_before: float = float(enemy.get("current_hp")) if enemy.get("current_hp") != null else 0.0
		enemy.take_damage(blast_damage, applied_force, dir, false, 0.3, blast_hitstun, _source_id, element)
		var hp_after: float = float(enemy.get("current_hp")) if enemy.get("current_hp") != null else hp_before
		_record_chapter_damage(hp_before, hp_after, false)

	if _explosion_hurts_players:
		# 对玩家的自爆半径独立可调（2026-09-15）：0=同爆炸半径；>0 用小半径——
		# 爆风对敌人范围大，但自爆只惩罚贴脸开火，远处误伤观感由该值控制。
		var player_radius: float = _explosion_player_radius if _explosion_player_radius > 0.0 else _explosion_radius
		for p: Node in get_tree().get_nodes_in_group("player"):
			if p is not Node2D or not is_instance_valid(p):
				continue
			var pl := p as Node2D
			if pl.global_position.distance_to(center) > player_radius:
				continue
			if not pl.has_method("take_damage"):
				continue
			if pl.get("_is_dying") == true:
				continue
			var pdir: Vector2 = (pl.global_position - center).normalized() if pl.global_position != center else Vector2.UP
			# 自爆：发射者自己也在半径内照伤（原作爆発物「自爆あり」）
			pl.take_damage(damage, applied_force, pdir, false, 0.3, 0.2, _source_id, element)

	## 可爆破墙体（blast_wall）：与投掷物爆炸同一入口
	for w: Node in get_tree().get_nodes_in_group("blast_wall"):
		if w is Node2D and (w as Node2D).has_method("apply_explosion"):
			(w as Node2D).call("apply_explosion", center, _explosion_radius, _breaks_blast_wall)


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
