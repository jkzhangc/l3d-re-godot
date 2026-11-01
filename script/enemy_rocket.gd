class_name EnemyRocket extends Area2D

## ── 架构定位 ──
## 系统：敌人攻击 ｜ 层：玩法（Area2D 投射物）
## 联机：Host 生成权威弹（结算爆炸伤害）；Client 经 enemy_rocket_presentation RPC 生成
##       `_authoritative=false` 镜像弹 —— 只播特效音效，伤害全部 Host 判定。
## 职责：ネメシス 的火箭弹：直飞 → 命中玩家/墙/射程尽头 → 爆炸（范围伤害 + 特效音效）。
## 依赖：art/Barrages/grenade.png、anim_effect_RPG爆炸动画.tscn、ロケットランチャー爆発.ogg
##
## ★碰撞层（同酸弹铁律）：mask = 4(玩家本体) | 32(图块 physics_layer_1「阻挡」)。
##   **绝不能带 layer 1** —— 那是角色用的墙体/家具层，桌椅会把火箭挡住。

const PLAYER_GROUP := &"player"

var direction: Vector2 = Vector2.RIGHT
var speed: float = 460.0
var damage: float = 80.0
var explosion_radius: float = 96.0
var max_range: float = 720.0
var source_id: int = 0
var explosion_effect: PackedScene = null
var explode_sound: AudioStream = null
## 视觉缩放（1 = 与玩家火箭完全相同；boss 想让弹体更醒目可以调大）。
var visual_scale: float = 1.0
## 贴图按水平帧条切成 N 帧（与 BulletData.bullet_anim_frames 同口径；grenade.png = 1 帧）。
var anim_frames: int = 1
## 权威闸：false 的镜像弹不结算伤害（与酸弹/投掷物同模式）。
var _authoritative: bool = true
var _travelled: float = 0.0
var _anim_time: float = 0.0
var _dead: bool = false

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _explode_player: AudioStreamPlayer2D = $ExplodeSound


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_refresh_sprite()


## ── 与玩家火箭（bullet.gd）同一套渲染口径 ──
## · 贴图水平帧条：单帧宽 = 图宽 / anim_frames，region 只取当前帧；
## · 图默认朝向为 DOWN → rotation = direction.angle() - PI/2（少了这个就整 90° 歪）；
## · 缩放只作用于精灵，不影响碰撞体。
func _refresh_sprite() -> void:
	if _sprite == null:
		return
	var tex: Texture2D = _sprite.texture
	if tex == null:
		return
	var frames: int = maxi(1, anim_frames)
	var frame_w: float = float(tex.get_width()) / float(frames)
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(0.0, 0.0, frame_w, float(tex.get_height()))
	_sprite.scale = Vector2(visual_scale, visual_scale)
	_sprite.rotation = direction.angle() - PI / 2.0
	## 碰撞体长边跟着飞行方向转（同玩家子弹 _update_area_rotation 的口径）
	var cs: CollisionShape2D = get_node_or_null("CollisionShape2D")
	if cs != null:
		cs.rotation = direction.angle()


func _process(delta: float) -> void:
	if _dead or anim_frames <= 1:
		return
	_anim_time += delta
	var frames: int = maxi(1, anim_frames)
	var idx: int = int(_anim_time * 12.0) % frames
	if _sprite == null:
		return
	var tex: Texture2D = _sprite.texture
	if tex == null:
		return
	var frame_w: float = float(tex.get_width()) / float(frames)
	_sprite.region_rect = Rect2(frame_w * float(idx), 0.0, frame_w, float(tex.get_height()))


func _physics_process(delta: float) -> void:
	if _dead:
		return
	var step: Vector2 = direction * speed * delta
	global_position += step
	_travelled += step.length()
	if _travelled >= maxf(1.0, max_range):
		_explode()


func _on_body_entered(body: Node2D) -> void:
	if _dead:
		return
	## 撞到玩家或墙都炸；镜像弹一样炸（只是不结算伤害）。
	if body == self:
		return
	_explode()


## 爆炸：范围伤害（仅权威）→ 特效 → 音效 → 销毁。
func _explode() -> void:
	if _dead:
		return
	_dead = true
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	if _sprite != null:
		_sprite.visible = false
	if _authoritative:
		_damage_players_in_radius()
	_play_explosion_effect()
	if explode_sound != null and _explode_player != null:
		_explode_player.stream = explode_sound
		_explode_player.play()
		await _explode_player.finished
	queue_free()


## 爆炸范围内所有存活玩家受伤（每人一次，不衰减）。
## 只打玩家组：火箭是敌方武器，误伤别的敌人只会让场面莫名其妙。
func _damage_players_in_radius() -> void:
	var r_sq: float = maxf(1.0, explosion_radius) * maxf(1.0, explosion_radius)
	var dir: Vector2 = direction if not direction.is_zero_approx() else Vector2.RIGHT
	for node: Node in get_tree().get_nodes_in_group(PLAYER_GROUP):
		var player: Node2D = node as Node2D
		if player == null or not is_instance_valid(player):
			continue
		if player.get("_is_dying") == true:
			continue
		var rel: Vector2 = player.global_position - global_position
		if rel.length_squared() > r_sq:
			continue
		var knock: Vector2 = rel.normalized() if rel.length_squared() > 1.0 else dir
		player.take_damage(damage, 220.0, knock, false, 0.0, 0.0, source_id,
			WeaponData.Element.NONE, false)


func _play_explosion_effect() -> void:
	if explosion_effect == null:
		return
	var parent: Node = get_tree().current_scene
	if parent == null:
		return
	VXAnimSprite.play_scene(explosion_effect, global_position, parent)


## Client 非权威镜像（NetworkWorld.enemy_rocket_presentation 调用）。
## ⚠ 同酸弹：本脚本带 class_name，preload 场景会形成循环依赖 → 运行期 load()。
## 自定义字段一律走 `set()`：变量类型是 Node2D，直接访问类内字段会过不了静态检查。
static func spawn_mirror(parent: Node, spawn_pos: Vector2, dir: Vector2, speed_: float,
		radius_: float, effect_: PackedScene) -> void:
	if parent == null:
		return
	var scene: PackedScene = load("res://object/enemy_rocket.tscn")
	var proj: Node2D = scene.instantiate()
	proj.global_position = spawn_pos
	proj.set("direction", dir)
	proj.set("speed", speed_)
	proj.set("explosion_radius", radius_)
	proj.set("explosion_effect", effect_)
	proj.set("_authoritative", false)
	parent.add_child(proj)
