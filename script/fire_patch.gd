class_name FirePatch extends Node2D
## 权威实例负责范围检测、周期伤害和生命周期；Client 镜像只播放火焰与环境音。
## _damage_players 等玩法参数由 Host/单机决定，不能由远端请求任意修改。
## 燃烧区域 — 在半径内填充多个火精灵（VX Ace 行走图），周期性灼烧敌人

const FIRE_TEXTURE_PATH := "res://art/misc/天罰キャラチップ.png"
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
const FRAME_DURATION: float = 0.1   ## 火精灵动画帧间隔
const STEP_FRAMES: int = 3          ## 每个方向的踏步帧数（VX Ace 3 列）
const TOTAL_FRAMES: int = STEP_FRAMES * DIRECTIONS  ## 4方向 × 3帧 = 12 帧完整动画

var _radius: int = 1
var _duration: float = 5.0
var _damage: float = 10.0
var _tick_interval: float = 0.33   ## 灼烧判定间隔（秒，默认 ~20 帧）
var _char_idx: int = 0             ## 火精灵行走图角色索引
var _ambient_sound: AudioStream = null   ## 火海环境音（循环播放）
var _elapsed: float = 0.0
var _tick_timer: float = 0.0
var _frame: int = 0
var _frame_timer: float = 0.0
var _fire_sprites: Array[Sprite2D] = []
var _authoritative: bool = true
var _damage_players: bool = true


static func spawn(pos: Vector2, radius: int, duration: float, damage: float, tick_interval: float, char_idx: int, ambient_sound: AudioStream, parent: Node, authoritative: bool = true, damage_players: bool = true) -> void:
	var patch := FirePatch.new()
	patch._radius = radius
	patch._duration = duration
	patch._damage = damage
	patch._tick_interval = tick_interval
	patch._char_idx = char_idx
	patch._ambient_sound = ambient_sound
	patch._authoritative = authoritative
	patch._damage_players = damage_players
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

	_setup_ambient_sound()


func _setup_ambient_sound() -> void:
	## 火海环境音（循环），随 FirePatch 销毁而停止。
	if not _ambient_sound:
		return
	var ap := AudioStreamPlayer2D.new()
	ap.name = "FireAmbientSound"
	ap.stream = _ambient_sound
	add_child(ap)
	var cb: Callable = func(): ap.play()
	ap.finished.connect(cb)
	ap.play()


func _fire_region(flat: int) -> Rect2:
	# 完整动画：按帧数先切方向（每 3 帧换一行），再切踏步列
	var dir: int = flat / STEP_FRAMES
	var col: int = flat % STEP_FRAMES
	var char_col: int = _char_idx % CHARS_PER_ROW
	var char_row: int = _char_idx / CHARS_PER_ROW
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

	# 伤害只在权威端执行；客户端仅显示火焰和音效。
	if _authoritative:
		_tick_timer += delta
		if _tick_timer >= _tick_interval:
			_tick_timer = 0.0
			_burn()

	# 熄灭
	if _elapsed >= _duration:
		queue_free()


func _burn() -> void:
	var radius_px: float = _radius * 32.0 + 16.0
	for group: StringName in ([&"enemy", &"player"] if _damage_players else [&"enemy"]):
		for n: Node in get_tree().get_nodes_in_group(group):
			if n is Node2D and (n as Node2D).global_position.distance_to(global_position) <= radius_px:
				if (n as Node2D).has_method("take_damage"):
					# source_id=0 跳过源头去重，保证持续灼烧按 tick 间隔生效
					(n as Node2D).take_damage(_damage, 0.0, Vector2.ZERO, false, 0.0, 0.0, 0)
