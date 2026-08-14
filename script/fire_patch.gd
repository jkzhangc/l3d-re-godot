class_name FirePatch extends Node2D
## 燃烧区域 — 在半径内填充多个火精灵（VX Ace 行走图），周期性灼烧敌人

const FIRE_TEXTURE_PATH := "res://art/misc/天罰キャラチップ.png"
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
const TICK_INTERVAL: float = 1.0    ## 灼烧判定间隔（秒）
const FRAME_DURATION: float = 0.1   ## 火精灵动画帧间隔
const STEP_FRAMES: int = 3          ## 每个方向的踏步帧数（VX Ace 3 列）
const TOTAL_FRAMES: int = STEP_FRAMES * DIRECTIONS  ## 4方向 × 3帧 = 12 帧完整动画

var _radius: int = 1
var _duration: float = 5.0
var _damage: float = 10.0
var _elapsed: float = 0.0
var _tick_timer: float = 0.0
var _frame: int = 0
var _frame_timer: float = 0.0
var _fire_sprites: Array[Sprite2D] = []


static func spawn(pos: Vector2, radius: int, duration: float, damage: float, parent: Node) -> void:
	var patch := FirePatch.new()
	patch._radius = radius
	patch._duration = duration
	patch._damage = damage
	patch.global_position = pos
	parent.add_child(patch)
	patch._build_fire()


func _build_fire() -> void:
	var tex: Texture2D = load(FIRE_TEXTURE_PATH)
	if not tex:
		printerr("[FirePatch] 火精灵表加载失败: %s" % FIRE_TEXTURE_PATH)
		return
	for dx: int in range(-_radius, _radius + 1):
		for dy: int in range(-_radius, _radius + 1):
			if dx * dx + dy * dy > _radius * _radius:
				continue
			var s := Sprite2D.new()
			s.texture = tex
			s.region_enabled = true
			s.position = Vector2(dx * 32 + randf_range(-6.0, 6.0), dy * 32 + randf_range(-6.0, 6.0))
			s.z_index = 4
			s.region_rect = _fire_region(randi() % TOTAL_FRAMES)
			add_child(s)
			_fire_sprites.append(s)


func _fire_region(flat: int) -> Rect2:
	# 完整动画：按帧数先切方向（每 3 帧换一行），再切踏步列
	var dir: int = flat / STEP_FRAMES
	var col: int = flat % STEP_FRAMES
	var char_col: int = 0
	var char_row: int = 0
	var x: int = char_col * (FRAME_W * 3) + col * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir * FRAME_H
	return Rect2(x, y, FRAME_W, FRAME_H)


func _process(delta: float) -> void:
	_elapsed += delta

	# 火精灵动画
	_frame_timer += delta
	if _frame_timer >= FRAME_DURATION:
		_frame_timer = 0.0
		_frame = (_frame + 1) % TOTAL_FRAMES
		for s: Sprite2D in _fire_sprites:
			s.region_rect = _fire_region(_frame)

	# 灼烧敌人
	_tick_timer += delta
	if _tick_timer >= TICK_INTERVAL:
		_tick_timer = 0.0
		_burn_enemies()

	# 熄灭
	if _elapsed >= _duration:
		queue_free()


func _burn_enemies() -> void:
	var radius_px: float = _radius * 32.0 + 16.0
	for e: Node in get_tree().get_nodes_in_group("enemy"):
		if e is Node2D and (e as Node2D).global_position.distance_to(global_position) <= radius_px:
			if (e as Node2D).has_method("take_damage"):
				(e as Node2D).take_damage(_damage, 0.0, Vector2.ZERO, false, 0.0, 0.0, get_instance_id())
