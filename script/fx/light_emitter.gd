@tool
class_name LightEmitter extends Node2D

## ── 架构定位 ──
## 系统：夜间视界 · 光源（表现） ｜ 层：表现（Node2D）
## 联机：纯表现，各端各自算（不同步）
## 职责：把「一个点光源」做成可直接拖进地图的组件——颜色、半径、亮度、闪烁都在
##       Inspector 里调，运行时自动注册到本图的 NightOverlay，节点销毁自动注销。
## 依赖：NightOverlay（找不到 = 白天关卡，本节点零开销，只留编辑器的圆圈预览）。
## 用法：把本节点放到要发光的位置即可；需要火光粒子就勾 embers_enabled。

@export_group("光源")
## 关掉 = 不注册光源（地图上留点但不发光，方便 A/B 对比）
@export var light_enabled: bool = true
## 亮圈半径（屏幕像素，约等于世界像素；燃烧瓶默认 160~220）
@export_range(8.0, 800.0, 1.0) var radius: float = 180.0
## 亮度倍率：1 = 中心完全点亮；0.6~0.8 更克制（贴近原工程），>1 亮核更大
@export_range(0.0, 8.0, 0.05) var intensity: float = 1.0
## 光色（加法发光用）。火光 ≈ (1.0, 0.52, 0.22)
@export var light_color: Color = Color(1.0, 0.52, 0.22)
## 闪烁幅度：0 = 稳定；0.2~0.3 ≈ 火苗；0.6+ = 故障灯
@export_range(0.0, 1.0, 0.01) var flicker: float = 0.0
## 是否被墙体/家具挡住（原工程的"建筑遮挡"）。关掉可以对比"光穿墙"。
@export var occlude: bool = true
## 灯的离地高度（px）。**> 0 时法线贴图才参与光照**，0 = 完全忽略法线（灯变成纯圆形亮斑）。
## 角色帧高 64px 时 32~64 比较自然；吊灯/路灯可调大，地面物件调小。
@export_range(0.0, 512.0, 1.0) var light_height: float = 48.0

@export_group("角色投影")
## 是否让角色在这盏灯下投出影子（原工程 :cast_shadow / [noshadow]）
@export var cast_shadow: bool = true
## 影子长度倍率：长度 = 角色高 × (离灯距离/32) × 本值 —— 离灯越远影子越长
@export_range(0.0, 3.0, 0.05) var shadow_scale: float = 0.5
## 投影作用距离（世界像素）。0 = 跟随灯半径；超出不投影
@export_range(0.0, 800.0, 1.0) var shadow_range: float = 0.0
## 影子在脚底处的最大不透明度（远端会自动淡出）
@export_range(0.0, 1.0, 0.01) var shadow_opacity: float = 0.45

@export_group("火星粒子（可选）")
## 勾上会在光源位置生成一层上升的火星（CPUParticles2D，加法混合）
@export var embers_enabled: bool = false
@export_range(0, 64, 1) var ember_amount: int = 14
@export var ember_color: Color = Color(1.0, 0.70, 0.28, 1.0)
@export_range(0.5, 8.0, 0.1) var ember_lifetime: float = 1.3
@export_range(1.0, 16.0, 0.5) var ember_size: float = 3.0
## 粒子从光源中心往上飘的初始速度
@export_range(0.0, 200.0, 1.0) var ember_speed: float = 44.0
## 发射圆盘半径（火星从多大范围里冒出来）
@export_range(0.0, 120.0, 1.0) var ember_radius: float = 24.0

@export_group("编辑器预览")
## 没勾时，编辑器里只画一圈细线；勾上会填一层半透明色，方便看光池大小
@export var preview_fill: bool = true
## ⚠ 编辑器预览圈 = radius / preview_zoom。
## 运行时 radius 是"屏幕像素"，NightOverlay 会除以相机 zoom 折算成世界半径，
## 而编辑器画布是 1:1 世界坐标 —— 不折算就会画成两倍大（2026-10-21 用户实测反馈）。
## 默认 2.0 对齐 `script/camera_follow.gd` 的 default_zoom；改相机缩放时同步改这里。
@export_range(0.1, 8.0, 0.1) var preview_zoom: float = 2.0

var _overlay: NightOverlay = null
var _registered: bool = false
var _retry_left: float = 0.0
var _embers: EmberParticles = null


func _ready() -> void:
	set_process(not Engine.is_editor_hint())
	if Engine.is_editor_hint():
		queue_redraw()
		return
	_sync_embers()
	_retry_left = 0.0
	_try_register()


func _process(delta: float) -> void:
	# 光源可能在场景 ready 之后才由 Director 创建（night_darkness>0），
	# 未注册时按 0.25s 间隔重试；注册成功就彻底停掉这条路径。
	if _registered and is_instance_valid(_overlay):
		return
	_retry_left -= delta
	if _retry_left > 0.0:
		return
	_retry_left = 0.25
	_try_register()


func _try_register() -> void:
	if not light_enabled:
		_unregister()
		return
	var ov := NightOverlay.find_any(self)
	if ov == null:
		return
	_overlay = ov
	ov.register_light(self, radius, intensity, light_color, flicker, occlude)
	ov.set_light_height(self, light_height)
	ov.set_light_shadow(self, shadow_scale, shadow_opacity, shadow_range, cast_shadow)
	_registered = true


func _unregister() -> void:
	if _registered and is_instance_valid(_overlay):
		_overlay.unregister_light(self)
	_registered = false


## 运行时改参数后调这个，立刻同步到遮罩（不用等重建）。
func apply_params() -> void:
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	if not is_instance_valid(_overlay) or not _overlay.is_inside_tree():
		_registered = false
		_try_register()
		return
	_overlay.register_light(self, radius, intensity, light_color, flicker, occlude)
	_overlay.set_light_height(self, light_height)
	_overlay.set_light_shadow(self, shadow_scale, shadow_opacity, shadow_range, cast_shadow)


func set_light_enabled(value: bool) -> void:
	light_enabled = value
	if value:
		_registered = false
		_try_register()
	else:
		_unregister()


func set_embers_enabled(value: bool) -> void:
	embers_enabled = value
	_sync_embers()


func _sync_embers() -> void:
	if embers_enabled:
		if _embers == null or not is_instance_valid(_embers):
			_embers = EmberParticles.new()
			_embers.name = "Embers"
			_embers.particle_count = ember_amount
			_embers.start_color = ember_color
			_embers.particle_lifetime = ember_lifetime
			_embers.size_px = ember_size
			_embers.rise_speed = ember_speed
			_embers.emit_radius = ember_radius
			add_child(_embers)
		_embers.visible = true
	elif _embers != null and is_instance_valid(_embers):
		_embers.visible = false


func _exit_tree() -> void:
	_unregister()


## ── 编辑器预览：一圈光池轮廓（不参与游戏）──
## 画的是**世界半径** = radius / preview_zoom，和运行时实际照亮范围一致。
func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var r: float = radius / maxf(preview_zoom, 0.1)
	var c: Color = light_color
	c.a = 0.12 if preview_fill else 0.0
	if preview_fill:
		draw_circle(Vector2.ZERO, r, c)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, Color(light_color.r, light_color.g, light_color.b, 0.65), 1.0, true)
