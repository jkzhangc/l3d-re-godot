class_name EmberParticles extends CPUParticles2D

## ── 架构定位 ──
## 系统：粒子（表现） ｜ 层：表现（Node2D）
## 联机：纯表现，各端各自播（不同步）
## 职责：可复用的火星/烟尘粒子。火堆、燃烧瓶、爆炸余烬都用这一份，
##       颜色 / 尺寸 / 寿命 / 上升速度 / 是否加法混合全部可调。
## 依赖：无（不联网、不读玩法状态）。
## 用法：拖一个 EmberParticles 到场景里改 Inspector；或在代码里 new() 后 add_child。
##   火星（默认）：additive = true，暖橙，向上飘；
##   烟尘：additive = false，深灰、更慢更大。

## 软点贴图边长（程序生成；scale_amount 以它为基准）
const TEX_SIZE: int = 16

@export_group("外观")
## 同时存在的粒子数（16~24 足够，太多在低端机上掉帧）
@export_range(0, 64, 1) var particle_count: int = 18
## 起始颜色
@export var start_color: Color = Color(1.0, 0.72, 0.30, 1.0)
## 结束颜色（默认淡出到透明；不想淡出就把 alpha 设成 1）
@export var end_color: Color = Color(0.85, 0.18, 0.04, 0.0)
## 单个粒子直径（像素）
@export_range(1.0, 24.0, 0.5) var size_px: float = 3.0
## true = 加法混合（火星/光点）；false = 普通混合（烟尘）
@export var additive: bool = true

@export_group("运动")
## 单个粒子寿命（秒）
@export_range(0.1, 6.0, 0.05) var particle_lifetime: float = 1.3
## 初速度（像素/秒，朝 direction）
@export_range(0.0, 300.0, 1.0) var rise_speed: float = 46.0
## 喷射角度（度）
@export_range(0.0, 180.0, 1.0) var spread_degrees: float = 26.0
## 重力 y（负数 = 继续上飘；正数 = 下落）
@export_range(-400.0, 400.0, 1.0) var gravity_y: float = -22.0
## 发射半径（在一个圆盘内随机出生）
@export_range(0.0, 200.0, 1.0) var emit_radius: float = 26.0
## 阻尼（越大越快减速）
@export_range(0.0, 200.0, 1.0) var damping: float = 12.0
## 迸发感（0 = 均匀喷，1 = 一次性全喷）
@export_range(0.0, 1.0, 0.01) var burst_ratio: float = 0.35


func _ready() -> void:
	_apply_config()


## 运行时改参数后调用即可重新套用（不需要重建节点）。
func _apply_config() -> void:
	emitting = false
	local_coords = true
	amount = maxi(particle_count, 1)
	lifetime = maxf(particle_lifetime, 0.1)
	one_shot = false
	explosiveness = clampf(burst_ratio, 0.0, 1.0)
	randomness = 0.55
	preprocess = particle_lifetime
	fixed_fps = 30
	direction = Vector2.UP
	spread = spread_degrees
	gravity = Vector2(0.0, gravity_y)
	initial_velocity_min = rise_speed * 0.55
	initial_velocity_max = rise_speed * 1.45
	damping_min = damping * 0.6
	damping_max = damping * 1.4
	# 贴图是 16×16 的软点，scale_amount 是相对贴图的倍率 —— 必须除以 16，
	# 否则 3px 的火星会被画成 48px 的大光斑（2026-10-19 试验场实测）。
	scale_amount_min = size_px * 0.55 / float(TEX_SIZE)
	scale_amount_max = size_px * 1.15 / float(TEX_SIZE)
	emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	emission_sphere_radius = emit_radius
	texture = _build_soft_dot()
	color_ramp = _build_ramp()
	material = _build_material()
	emitting = true


## 16×16 的径向渐变点，避免粒子是硬方块（程序生成，不占美术资源）。
func _build_soft_dot() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	return tex


func _build_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, start_color)
	g.set_color(1, end_color)
	return g


func _build_material() -> CanvasItemMaterial:
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD if additive else CanvasItemMaterial.BLEND_MODE_MIX
	return m
