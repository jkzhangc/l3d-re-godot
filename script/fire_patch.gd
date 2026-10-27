class_name FirePatch extends Node2D

## ── 架构定位 ──
## 系统：燃烧区域 ｜ 层：玩法（Node2D）
## 联机：Host 结算周期伤害
## 职责：在半径内铺满火焰精灵并按 tick 灼烧敌人；Client 镜像只播放火焰与环境音。
## 依赖：ThrowableData（燃烧参数）、敌人伤害接口

## 权威实例负责范围检测、周期伤害和生命周期；Client 镜像只播放火焰与环境音。
## _damage_players 等玩法参数由 Host/单机决定，不能由远端请求任意修改。
## 燃烧区域 — 在半径内填充多个火精灵（VX Ace 行走图），周期性灼烧敌人

const FIRE_TEXTURE_PATH := "res://art/misc/天罰キャラチップ.png"
## 酸池着色器表现（element=ACID 时替换火苗精灵，见 _build_acid_pool）。
const ACID_POOL_VISUAL := preload("res://script/fx/acid_pool_visual.gd")
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
const FRAME_DURATION: float = 0.1   ## 火精灵动画帧间隔
const STEP_FRAMES: int = 3          ## 每个方向的踏步帧数（VX Ace 3 列）
const TOTAL_FRAMES: int = STEP_FRAMES * DIRECTIONS  ## 4方向 × 3帧 = 12 帧完整动画
## 夜间视界默认值（2026-10-19 用户实测「照亮范围和亮度都不够」→ 又反馈「太亮」）：
## 光圈半径 = 火海半径(px) + EXTRA；旧实现硬编码 +64 → 现 +88（+24px）。
## 亮度 1.0 = 中心刚好完全点亮，超过 1 只会扩大亮核（2026-10-19 换缓冲管线后）。
## 两个值都可被 ThrowableData 的 fire_light_* 逐投掷物覆盖。
const NIGHT_LIGHT_EXTRA_PX: float = 88.0
const NIGHT_LIGHT_INTENSITY: float = 1.0
## 火光颜色（加法发光）：暖橙，参考 RGD Lighting 的 torch = [250,126,100]。
const FIRE_LIGHT_COLOR := Color(1.0, 0.52, 0.22)
## 火光闪烁幅度（0.26 ≈ 火苗明暗跳动 + 半径轻微呼吸）。
const FIRE_LIGHT_FLICKER: float = 0.26
## 火海运炭粒子数量（0 = 不起粒子）。
const FIRE_EMBER_AMOUNT: int = 10
## 火光淡入/淡出时长（秒）。燃烧瓶落地时灯不是"啪"地亮/灭，
## 熄灭前先把亮度收下去，免得火没了还剩一个突兀的光圈。
const LIGHT_FADE_IN: float = 0.25
const LIGHT_FADE_OUT: float = 0.7
## 火光下的角色投影默认值（可被 ThrowableData.fire_shadow_* 覆盖）
const FIRE_SHADOW_SCALE: float = 0.55
const FIRE_SHADOW_RANGE: float = 0.0
const FIRE_SHADOW_OPACITY: float = 0.45

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
var _source_owner: Node = null
var _source_is_player_origin: bool = true
## 每次 tick 施加的属性（2026-10-27）：FIRE = 燃烧瓶（点燃），ACID = 酸瓶（只掉血、不点燃）。
var _element: int = WeaponData.Element.FIRE
## 酸池的可视节点（挂在 GroundLayer 下，不是本节点的子节点 —— 见 _build_acid_pool）。
var _acid_visual: Node2D = null
## 夜间视界光源参数（ThrowableData 注入；默认 = 本文件常量）
var _night_light_extra_px: float = NIGHT_LIGHT_EXTRA_PX
var _night_light_intensity: float = NIGHT_LIGHT_INTENSITY
var _night_light_color: Color = FIRE_LIGHT_COLOR
var _night_light_flicker: float = FIRE_LIGHT_FLICKER
var _ember_amount: int = FIRE_EMBER_AMOUNT
var _overlay: NightOverlay = null
var _light_px: float = 0.0
var _light_scale: float = -1.0
var _shadow_scale: float = FIRE_SHADOW_SCALE
var _shadow_range: float = FIRE_SHADOW_RANGE
var _shadow_opacity: float = FIRE_SHADOW_OPACITY
const HitResolver := preload("res://script/hit_resolver.gd")


## shadow: 角色投影参数（可省略）。键：scale / range / opacity ——
##   参数太多，这里用字典而不是继续加位置参数（见 ThrowableData.fire_shadow_*）。
## element: 每次 tick 施加的属性（2026-10-27）。默认 FIRE 保持燃烧瓶既有行为；
##   酸瓶这类"火海只是持续伤害地面"的投掷物传 ACID，就不会把敌人点燃。
static func spawn(pos: Vector2, radius: int, duration: float, damage: float, tick_interval: float, char_idx: int, ambient_sound: AudioStream, parent: Node, authoritative: bool = true, damage_players: bool = true, source_owner: Node = null, source_is_player_origin: bool = false, night_light_extra_px: float = NIGHT_LIGHT_EXTRA_PX, night_light_intensity: float = NIGHT_LIGHT_INTENSITY, night_light_color: Color = FIRE_LIGHT_COLOR, night_light_flicker: float = FIRE_LIGHT_FLICKER, ember_amount: int = FIRE_EMBER_AMOUNT, shadow: Dictionary = {}, element: int = WeaponData.Element.FIRE) -> void:
	var patch := FirePatch.new()
	patch._radius = radius
	patch._duration = duration
	patch._damage = damage
	patch._tick_interval = tick_interval
	patch._char_idx = char_idx
	patch._ambient_sound = ambient_sound
	patch._authoritative = authoritative
	patch._damage_players = damage_players
	patch._source_owner = source_owner
	patch._source_is_player_origin = HitResolver.is_player(source_owner) if is_instance_valid(source_owner) else source_is_player_origin
	patch._element = element
	patch._night_light_extra_px = night_light_extra_px
	patch._night_light_intensity = night_light_intensity
	patch._night_light_color = night_light_color
	patch._night_light_flicker = night_light_flicker
	patch._ember_amount = ember_amount
	patch._shadow_scale = float(shadow.get("scale", FIRE_SHADOW_SCALE))
	patch._shadow_range = float(shadow.get("range", FIRE_SHADOW_RANGE))
	patch._shadow_opacity = float(shadow.get("opacity", FIRE_SHADOW_OPACITY))
	patch.global_position = pos
	parent.add_child(patch)
	patch._build_fire()


func _build_fire() -> void:
	## ★酸液地面（2026-10-27 用户需求）：酸瓶没有酸池美术素材 → 不铺火苗，
	## 改用着色器画一滩强酸（见 script/fx/acid_pool_visual.gd）。
	## 伤害/生命周期/夜间光源/发光粒子与燃烧瓶完全共用，只有"长什么样"不同。
	if _element == WeaponData.Element.ACID:
		_build_acid_pool()
		_setup_ambient_sound()
		_setup_embers()
		_setup_night_light()
		return
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
	_setup_embers()
	_setup_night_light()


## 酸池：着色器液面挂在 **GroundLayer**（而不是本节点）——
## 本节点在场景根下、火苗用 z=4 盖住一切；液面必须相反：压在角色(z=1)之下、
## 地面图块之上。GroundLayer 没有 y_sort，子节点 z=0 正好是这个层级。
func _build_acid_pool() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var host: Node = scene.find_child("GroundLayer", true, false)
	if host == null:
		host = scene
	var vis := Node2D.new()
	vis.name = "AcidPoolSurface"
	vis.set_script(ACID_POOL_VISUAL)
	vis.call("setup", float(_radius) * 32.0 + 16.0)
	vis.z_index = 0
	host.add_child(vis)
	vis.global_position = global_position
	_acid_visual = vis


## 酸液面是**另一个父节点**下的节点，本节点被回收时必须一并清掉，否则会留下
## 一滩永远不消失的酸（直到换图）。
func _exit_tree() -> void:
	if _acid_visual != null and is_instance_valid(_acid_visual):
		_acid_visual.queue_free()
	_acid_visual = null


## 火星：从火海里往上飘的余烬（纯表现，各端各自播）。
## 数量由 ThrowableData.fire_ember_amount 控制，0 = 不起。
func _setup_embers() -> void:
	if _ember_amount <= 0:
		return
	var embers := EmberParticles.new()
	embers.name = "Embers"
	embers.particle_count = _ember_amount
	embers.start_color = _night_light_color.lightened(0.18)
	embers.end_color = Color(0.9, 0.2, 0.05, 0.0)
	embers.size_px = 2.6
	embers.particle_lifetime = 1.15
	embers.rise_speed = 42.0
	embers.emit_radius = float(_radius) * 32.0 * 0.62
	embers.z_index = 5
	add_child(embers)


func _setup_night_light() -> void:
	## 夜间视界：火海本身就是光源。NightOverlay 存在时把火海注册成暖橙亮圈。
	## 光圈半径 = 火海半径(px) + 余量（默认 88）；亮度倍率 / 颜色 / 闪烁都由
	## ThrowableData.fire_light_* 逐投掷物注入。
	## 用 find_any 而不是 find_in_scene：试验场/自定义场景里遮罩不一定挂在 current_scene 下。
	## NightOverlay 不存在（白天关卡）时零开销。
	var overlay := NightOverlay.find_any(self)
	if overlay:
		_overlay = overlay
		_light_px = float(_radius) * 32.0 + maxf(_night_light_extra_px, 0.0)
		overlay.register_light(self, _light_px, 0.0, _night_light_color, _night_light_flicker)
		overlay.set_light_shadow(self, _shadow_scale, _shadow_opacity, _shadow_range, true)
		_update_light_fade(0.0)


## 火光淡入淡出：改亮度不会重建可见性扇形（NightOverlay.register_light 只在
## 半径/遮挡变化时才重建），所以每帧调用也不贵。
func _update_light_fade(_delta: float) -> void:
	if _overlay == null or not is_instance_valid(_overlay):
		return
	var k: float = 1.0
	if LIGHT_FADE_IN > 0.0 and _elapsed < LIGHT_FADE_IN:
		k = _elapsed / LIGHT_FADE_IN
	var left: float = _duration - _elapsed
	if LIGHT_FADE_OUT > 0.0 and left < LIGHT_FADE_OUT:
		k = minf(k, maxf(left / LIGHT_FADE_OUT, 0.0))
	if is_equal_approx(k, _light_scale):
		return
	_light_scale = k
	_overlay.register_light(self, _light_px,
		maxf(_night_light_intensity, 0.0) * k, _night_light_color, _night_light_flicker)


func _setup_ambient_sound() -> void:
	## 火海环境音（循环），随 FirePatch 销毁而停止。
	if not _ambient_sound:
		return
	var ap := AudioStreamPlayer2D.new()
	ap.name = "FireAmbientSound"
	ap.stream = _ambient_sound
	# 走 SFX 总线（2026-09-13 用户反馈：全局音量对部分音效无效——本播放器直连 Master 漏网）
	ap.bus = "SFX"
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

	_update_light_fade(delta)

	# 熄灭
	if _elapsed >= _duration:
		queue_free()


func _burn() -> void:
	if not _authoritative or not HitResolver.is_damage_authority():
		return
	var radius_px: float = _radius * 32.0 + 16.0
	# 目标组 = 真敌人 + 训练木偶（木偶**不在** "enemy" 组，见 HitResolver.DAMAGE_TARGET_GROUPS）；
	# `_damage_players` 时再带上玩家。
	var groups: Array[StringName] = []
	for target_group: StringName in HitResolver.DAMAGE_TARGET_GROUPS:
		groups.append(target_group)
	if _damage_players:
		groups.append(&"player")
	for group: StringName in groups:
		for n: Node in get_tree().get_nodes_in_group(group):
			if n is Node2D and (n as Node2D).global_position.distance_to(global_position) <= radius_px:
				if (n as Node2D).has_method("take_damage"):
					# source_id=0 跳过源头去重，保证持续灼烧按 tick 间隔生效。
					# 玩家来源火海统一经过 Player.take_damage，关闭时不扣 HP/不点燃。
					if (n as Node2D).is_in_group("player"):
						(n as Node2D).take_damage(_damage, 0.0, Vector2.ZERO, false, 0.0, 0.0, 0, _element, false, _source_owner, _source_is_player_origin)
					else:
						(n as Node2D).take_damage(_damage, 0.0, Vector2.ZERO, false, 0.0, 0.0, 0, _element)
