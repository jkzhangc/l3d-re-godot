@tool
extends Node2D

## ── 架构定位 ──
## 系统：可交互场景精灵 ｜ 层：玩法（Node2D，地图机关）
## 联机：Host 权威（被子弹/爆炸命中后由 Host 判定消失），Client 侧在当前实现下
##       仍由同一条子弹/爆炸路径命中 —— 远程客户端不结算伤害，机关保持可见。
## 职责：带行走图 + 踏步动画的「可被武器/投掷物打掉」的机关精灵。
##       默认用于死亡岛的火堆：被灭火器喷溅（hit_tag）或液体窒素（氷属性）命中后
##       播放粒子并消失，同时撤掉挡路的碰撞。
## 依赖：vx_walk_sheet（行走图取帧）、VXAnimSprite（可选自定义粒子）、Global（音效）
##
## 【为什么独立于 enemy / 投掷物】
##   放进 enemy 组会被寻路、背刺、仇恨、导演系统当成敌人；而它只是一块可破坏场景物。
##   所以用独立组 `interactive_prop` + 独立方法 `on_hit_tag / on_throwable_hit`，
##   由子弹 / 投掷物在**原有伤害流程之后**额外通知，不改变任何既有结算。

const WALK := preload("res://script/vx_walk_sheet.gd")

## 被命中后算作「已熄灭 / 已破坏」的子弹 tag（由 BulletData.hit_tag 传入）。
@export var consume_tags: Array[String] = ["extinguish"]
## 被命中后算作「已熄灭」的投掷物属性（3 = 氷，见 WeaponData.Element）。
@export var consume_on_ice: bool = true
## 允许**近战武器**触发熄灭的 item_id 列表（2026-11-25）。
## ⚠ 默认空 = 近战不可触发；想用某把近战武器打掉这个机关，必须显式把它的 id 写进来。
@export var melee_trigger_ids: Array[String] = []
@export_group("外观（行走图）")
@export var walk_texture: Texture2D:
	set(v):
		walk_texture = v
		_refresh_sprite()
@export_range(0, 7, 1) var char_index: int = 0:
	set(v):
		char_index = v
		_refresh_sprite()
@export_range(0, 3, 1) var direction: int = 0:
	set(v):
		direction = v
		_refresh_sprite()
@export var sprite_offset: Vector2 = Vector2.ZERO
@export_group("踏步动画")
@export var step_frames: Array[int] = [1, 0, 1, 2]
@export_range(0.02, 5.0, 0.01) var step_duration: float = 0.25
@export var animated: bool = true
@export_group("碰撞")
## 挡路：生成一个同时挡玩家（layer 1）与子弹（layer 32）的静态体。
## 熄灭后立刻撤掉，玩家就能走过去。
@export var blocking: bool = true
@export var collision_size: Vector2 = Vector2(32, 32)
@export_group("熄灭表现")
## 自定义粒子（VXAnimSprite 场景）。留空 = 用下面「熄灭粒子（内置）」的一组参数生成。
@export var consume_effect: PackedScene = null
@export var consume_sound: AudioStream = null

## 熄灭后是否从场景移除（false = 只隐藏，保留节点供存档/联机状态参考）
@export var free_after_consume: bool = true
@export var consumed: bool = false

@export_group("熄灭粒子（内置）")
## 粒子贴图。留空 = 纯色软点（CPUParticles2D 默认方块会显得很硬，建议配一张云状图，
## 例如 res://art/Barrages/烟雾粒子.png）。
@export var consume_particle_texture: Texture2D = null
@export_range(2, 96, 1) var consume_particle_amount: int = 18
@export_range(0.1, 3.0, 0.05) var consume_particle_lifetime: float = 0.8
@export_range(0.0, 200.0, 1.0) var consume_particle_speed_min: float = 20.0
@export_range(0.0, 300.0, 1.0) var consume_particle_speed_max: float = 70.0
@export_range(0.05, 6.0, 0.05) var consume_particle_scale_min: float = 0.5
@export_range(0.05, 8.0, 0.05) var consume_particle_scale_max: float = 1.6
@export var consume_particle_color: Color = Color(0.92, 0.94, 0.96, 0.9)
## 渐隐起点（占生命周期的比例）：0 = 从出生就开始淡出，0.45 = 前 45% 保持、之后淡出。
## ★2026-11-26 用户反馈「粒子出现后应该渐渐消失，而不是直接消失」——
## 旧的兜底粒子没有 color_ramp，alpha 恒定，生命周期一结束整团瞬间消失。
@export_range(0.0, 0.9, 0.05) var consume_particle_fade_from: float = 0.4
## 扩散倍率：粒子在生命周期内从 scale_min 涨到 scale_max × 该值（烟往外散的感觉）。
@export_range(1.0, 3.0, 0.05) var consume_particle_expand: float = 1.35

signal extinguished

var _sprite: Sprite2D = null
var _body: StaticBody2D = null
var _net_world: Node = null
var _remote_consumed: bool = false   ## 本次熄灭来自 Host 广播（不再回推）
var _last_hit_element: int = -1
var _step_index: int = 0
var _step_timer: float = 0.0


func _ready() -> void:
	if step_frames.is_empty():
		step_frames = [1]
	_ensure_children()
	_refresh_sprite()
	_create_collision()
	if Engine.is_editor_hint():
		return
	add_to_group(&"interactive_prop")
	_net_world = _find_network_world()
	if _net_world != null and _net_world.has_signal("interactive_prop_consumed_received"):
		_net_world.connect("interactive_prop_consumed_received", _on_net_consumed)
	if consumed:
		_apply_consumed_visual()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or consumed:
		return
	if not animated or step_frames.size() <= 1:
		return
	_step_timer -= delta
	if _step_timer <= 0.0:
		_step_timer += maxf(step_duration, 0.02)
		_step_index = (_step_index + 1) % step_frames.size()
		_refresh_sprite()


# ── 命中入口（子弹 / 投掷物） ──

## 子弹命中：实现 take_damage 让子弹把我们当可命中目标；真正的"熄灭"看 hit tag。
## 签名必须与 bullet.gd 的调用一致（9 参），多出来的参数一律忽略。
func take_damage(_amount: float, _knockback: float = 0.0, _dir: Vector2 = Vector2.ZERO,
		_is_headshot: bool = false, _knockback_stun: float = 0.0, _hitstun: float = 0.0,
		_source_id: int = 0, element: int = 0, _causes_heat: bool = false) -> void:
	_last_hit_element = element
	if element == 3 and consume_on_ice:   ## 3 = WeaponData.Element.ICE
		consume("ice")


## 子弹携带的 tag（BulletData.hit_tag）：灭火器喷溅 = "extinguish"。
func on_hit_tag(tag: String, _element: int = 0) -> void:
	if tag.is_empty():
		return
	if tag in consume_tags:
		consume(tag)


## 投掷物爆炸波及（throwable_projectile 在伤害结算后调用）。
func on_throwable_hit(item_id: String, element: int) -> void:
	_last_hit_element = element
	if element == 3 and consume_on_ice:
		consume(item_id if not item_id.is_empty() else "ice")


## 近战命中（PlayerMeleeAttackState / NetworkWorld 的近战判定额外查一遍本机关）。
## 只有武器 id 在 `melee_trigger_ids` 里才生效 —— 没配置 = 近战打不掉。
func on_melee_hit(weapon_id: String) -> void:
	if consumed or weapon_id.is_empty():
		return
	if weapon_id in melee_trigger_ids:
		consume(weapon_id)


## 熄灭 / 破坏：撤碰撞、播粒子、隐藏或移除。
func consume(reason: String = "") -> void:
	if consumed:
		return
	consumed = true
	remove_from_group(&"interactive_prop")
	_disable_collision()
	_play_consume_fx()
	if consume_sound != null:
		var g: Node = get_node_or_null("/root/Global")
		if g != null and g.has_method("play_sfx_managed"):
			g.call("play_sfx_managed", consume_sound, get_parent())
	print("[交互精灵] %s 已熄灭（来源=%s，element=%s）" % [name, reason, str(_last_hit_element)])
	_broadcast_consumed()
	extinguished.emit()
	_apply_consumed_visual()
	_schedule_release()


## 联机同步（2026-11-25）：Host 判定熄灭 → 广播路径；Client 收到后本地隐藏 + 撤碰撞。
## 后加入的客户端由 Host 在 ready 时补发已熄灭列表（见 NetworkWorld）。
func _broadcast_consumed() -> void:
	if _remote_consumed:
		return
	var net: Node = get_node_or_null("/root/Net")
	if net == null or not net.has_method("is_online_session") or not bool(net.call("is_online_session")):
		return
	if not bool(net.get("is_host")):
		return
	if _net_world != null and _net_world.has_method("broadcast_interactive_prop_consumed"):
		_net_world.call("broadcast_interactive_prop_consumed", get_path())


func _on_net_consumed(node_path: NodePath) -> void:
	if consumed or str(node_path) != str(get_path()):
		return
	_remote_consumed = true
	consumed = true
	remove_from_group(&"interactive_prop")
	_disable_collision()
	_play_consume_fx()
	_apply_consumed_visual()
	_schedule_release()


## 熄灭后延迟释放节点。
##
## ★2026-11-26 用户反馈「粒子还是突然消失」：旧实现写死 0.6s ——
## 当时 `consume_particle_lifetime` 是 0.55，刚好卡在粒子结束前一点点；
## 后来默认寿命提到 0.8，节点在粒子播到 75% 时就被 `queue_free`，
## 内置粒子挂在本节点下 → 被连根拔掉，看起来就是"戛然消失"。
## 现在按实际寿命留 0.25s 余量；自定义粒子场景（consume_effect）挂在 current_scene
## 上，不受本节点释放影响，沿用保守值即可。
func _schedule_release() -> void:
	if not free_after_consume:
		return
	var wait: float = 0.6
	if consume_effect == null:
		wait = maxf(0.3, consume_particle_lifetime) + 0.25
	var tree: SceneTree = get_tree() if is_inside_tree() else null
	if tree == null:
		queue_free()
		return
	var timer: SceneTreeTimer = tree.create_timer(wait)
	timer.timeout.connect(queue_free)


func _find_network_world() -> Node:
	if not is_inside_tree():
		return null
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.find_child("NetworkWorld", true, false)


func _apply_consumed_visual() -> void:
	if _sprite != null:
		_sprite.visible = false
	_disable_collision()


# ── 外观 / 碰撞 ──

func _ensure_children() -> void:
	_sprite = get_node_or_null("Sprite2D") as Sprite2D
	if _sprite == null:
		_sprite = Sprite2D.new()
		_sprite.name = "Sprite2D"
		_sprite.centered = true
		add_child(_sprite)


func _refresh_sprite() -> void:
	if _sprite == null:
		return
	_sprite.texture = walk_texture
	_sprite.position = sprite_offset
	_sprite.visible = walk_texture != null and not consumed
	if walk_texture == null:
		return
	_sprite.region_enabled = true
	var frame: int = clampi(step_frames[_step_index], 0, 2) if _step_index < step_frames.size() else 0
	_sprite.region_rect = WALK.region_rect(walk_texture, char_index, direction, frame)


func _create_collision() -> void:
	if not blocking:
		return
	_body = get_node_or_null("Collision") as StaticBody2D
	if _body == null:
		_body = StaticBody2D.new()
		_body.name = "Collision"
		add_child(_body)
	## 1 = 世界（挡玩家，玩家 mask 含 bit0）；32 = 子弹阻挡（bullet mask 含 bit5）。
	_body.collision_layer = 1 | 32
	_body.collision_mask = 0
	var shape: CollisionShape2D = _body.get_node_or_null("Shape") as CollisionShape2D
	if shape == null:
		shape = CollisionShape2D.new()
		shape.name = "Shape"
		_body.add_child(shape)
	var rect: RectangleShape2D = shape.shape as RectangleShape2D
	if rect == null:
		rect = RectangleShape2D.new()
		shape.shape = rect
	rect.size = collision_size


func _disable_collision() -> void:
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
		_body = null


func _play_consume_fx() -> void:
	## 自定义粒子优先（PackedScene，里层通常是 VXAnimSprite）。
	if consume_effect != null:
		var root: Node = get_tree().current_scene if is_inside_tree() else get_parent()
		var fx: Node = consume_effect.instantiate()
		if root != null:
			root.add_child(fx)
			if fx is Node2D:
				(fx as Node2D).global_position = global_position
			return
	## 兜底：内置烟尘（不需要任何素材也能有反馈），参数全部来自上面的导出组。
	var p := CPUParticles2D.new()
	p.name = "ConsumePuff"
	p.amount = maxi(2, consume_particle_amount)
	p.lifetime = maxf(0.1, consume_particle_lifetime)
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector2.UP
	p.spread = 180.0
	p.gravity = Vector2(0, -40)
	p.initial_velocity_min = consume_particle_speed_min
	p.initial_velocity_max = maxf(consume_particle_speed_min, consume_particle_speed_max)
	p.scale_amount_min = maxf(0.05, consume_particle_scale_min)
	p.scale_amount_max = maxf(consume_particle_scale_min, consume_particle_scale_max)
	p.color = consume_particle_color
	## ★渐隐（2026-11-26）：没有 color_ramp 时粒子 alpha 恒定，寿命一到整团瞬间消失。
	## 这里按 fade_from 把后段 alpha 压到 0；再配一条尺寸曲线让粒子边散边变大。
	var base: Color = consume_particle_color
	var ramp := Gradient.new()
	ramp.set_color(0, Color(base.r, base.g, base.b, base.a))
	ramp.set_color(1, Color(base.r, base.g, base.b, 0.0))
	ramp.add_point(clampf(consume_particle_fade_from, 0.0, 0.9),
		Color(base.r, base.g, base.b, base.a * 0.9))
	p.color_ramp = ramp
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 1.0))
	grow.add_point(Vector2(1.0, maxf(1.0, consume_particle_expand)))
	p.scale_amount_curve = grow
	if consume_particle_texture != null:
		p.texture = consume_particle_texture
	add_child(p)
	## 入树之后再点火：未入树时设 emitting 在部分版本里不会补发首帧粒子。
	p.emitting = true
