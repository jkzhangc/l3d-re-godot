class_name EnemyAcidSpit extends Area2D

## ── 架构定位 ──
## 系统：敌人攻击 ｜ 层：玩法（Area2D 投射物）
## 联机：仅 Host/单机生成（Client 暂不还原吐酸演出，与首狩り的 Client 视觉妥协同层级）。
## 职责：ブレインディモス 的酸弹 —— 全工程首个敌方投射物：
##       直飞 → 命中玩家（伤害 + element=酸 → 削り自动触发）/ 撞墙销毁 / 与玩家子弹相消。
## 依赖：art/misc/ブレインディモス酸弾.png（12 帧动画）、sound/酸着弾.ogg
##
## 原作依据（enemy.html ブレインディモス条）：
##   「正面から撃ち合いをすると酸で銃弾を相殺してしまうこともある」→ 与玩家子弹同归于尽；
##   「この酸には削り効果があり、連続で食らうと武器があっという間にダメにされてしまう」
##   → element=ACID 走 player.take_damage 的削り通道（弹夹 -2 / 近战耐久 -8）。

## 相消判定的玩家子弹组名（bullet.gd _ready 加组）
const PLAYER_BULLET_GROUP := &"player_bullets"

var direction: Vector2 = Vector2.RIGHT
var speed: float = 450.0
var damage: float = 8.0
var source_id: int = 0
## 命中/落地特效（VXAnimSprite 场景）与染色——由 EnemySpitState 从特感 tres 透传。
## 空 = 不播特效。命中玩家与撞墙/落地共用。
var impact_effect: PackedScene = null
var impact_tone: Color = Color(1, 1, 1, 1)
## 飞行寿命（秒）：防止无遮挡走廊里永久飞行。
var _life: float = 3.0
var _dead: bool = false
var _anim_time: float = 0.0
## 动画行（0=下 1=左 2=右 3=上，与角色表同布局）：
## 12 帧 = 3 帧 × 4 方向，按飞行方向锁定行后只循环该行 3 帧（2026-09-17 用户反馈：
## 原先 12 帧连播会出现"飞行中切换方向"的怪相）。
var _anim_row: int = 0

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _impact_sound: AudioStreamPlayer2D = $ImpactSound


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	_pick_anim_row()


## 按飞行方向选一次动画行（下=0 左=1 右=2 上=3），飞行中不再切换。
func _pick_anim_row() -> void:
	if absf(direction.x) >= absf(direction.y):
		_anim_row = 2 if direction.x >= 0.0 else 1
	else:
		_anim_row = 0 if direction.y >= 0.0 else 3


func _process(delta: float) -> void:
	if _dead:
		return
	# 该方向行的 3 帧蠕动循环 @ 10fps
	_anim_time += delta
	_sprite.frame = _anim_row * 3 + (int(_anim_time * 10.0) % 3)


func _physics_process(delta: float) -> void:
	if _dead:
		return
	_life -= delta
	if _life <= 0.0:
		_impact()
		return
	global_position += direction * speed * delta


## 命中任何 body：玩家 → 结算伤害；墙/机器 → 直接碎裂。
func _on_body_entered(body: Node2D) -> void:
	if _dead:
		return
	if body.has_method("take_damage") and body.get("_is_dying") != true:
		## 見切/SA 无效化在 take_damage 内部处理（与敌人近战同入口）。
		body.take_damage(damage, 60.0, direction, false, 0.0, 0.0, source_id,
			WeaponData.Element.ACID, false)
	_impact()


## 与玩家子弹相消（原作「酸で銃弾を相殺」）：双方销毁。
## 玩家子弹 collision_layer=64（「玩家弹」），本 Area2D mask 含 64 才能感知它。
## 注意：进组的节点是子弹的 Area2D 子节点，销毁必须作用到子弹根节点（否则留下隐形弹体继续飞）。
func _on_area_entered(area: Area2D) -> void:
	if _dead:
		return
	if area.is_in_group(PLAYER_BULLET_GROUP):
		var root: Node = area.get_parent()
		if root != null and root.has_method("cancel_by_enemy_acid"):
			root.cancel_by_enemy_acid()
		else:
			area.queue_free()
		_impact()


## 碎裂：停移动、藏精灵、放着弾音、播完即焚。
func _impact() -> void:
	if _dead:
		return
	_dead = true
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	_sprite.visible = false
	_play_impact_effect()
	if _impact_sound.stream == null:
		queue_free()
		return
	_impact_sound.pitch_scale = randf_range(0.92, 1.08)
	_impact_sound.play()
	await _impact_sound.finished
	queue_free()


## 命中/落地特效：数据驱动（特感 tres 的 spit_impact_effect / spit_impact_tone，
## 经 EnemySpitState 透传），VXAnimSprite.play_scene 在 global_position 播放。
## 需要程序化特殊演出时可直接改写本方法（tone 染色已支持，2026-09-17）。
func _play_impact_effect() -> void:
	if impact_effect == null:
		return
	var parent: Node = get_tree().current_scene
	if parent == null:
		return
	VXAnimSprite.play_scene(impact_effect, global_position, parent,
		10.0, null, Vector2.ZERO, impact_tone)
