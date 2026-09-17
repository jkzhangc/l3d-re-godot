class_name NightOverlay extends CanvasLayer

## ── 架构定位 ──
## 系统：夜间视界 ｜ 层：表现（CanvasLayer）
## 联机：表现层，各端自行渲染（不联网）
## 职责：Night Hunter 夜间关卡的黑幕遮罩——全屏压暗，按注册光源在屏幕空间"挖亮"。
##       提供光源注册 API（火海/燃烧瓶/起火点等 Node2D 动态光源）与闪光弹全局白闪。
## 依赖：Director 按 DirectorConfig.night_darkness 创建/销毁；FirePatch / 投掷物注册光源。

## 光源上限（shader uniform 数组定长；超出的忽略——同屏火源不会超过这个量级）
const MAX_LIGHTS: int = 32
const SHADER := "
shader_type canvas_item;
uniform float darkness : hint_range(0.0, 1.0) = 0.85;
uniform float flash_strength : hint_range(0.0, 1.0) = 0.0;
uniform int light_count = 0;
uniform vec3 lights[32];
void fragment() {
	vec2 px = UV / SCREEN_PIXEL_SIZE;
	float lit = 0.0;
	for (int i = 0; i < light_count; i++) {
		float d = distance(px, lights[i].xy);
		float l = 1.0 - clamp(d / max(lights[i].z, 1.0), 0.0, 1.0);
		lit = max(lit, l * l * (3.0 - 2.0 * l));  // smoothstep 软边
	}
	float a = darkness * (1.0 - lit) - flash_strength;
	COLOR = vec4(0.015, 0.015, 0.04, clamp(a, 0.0, 1.0));
}
"

var darkness: float = 0.85
var _rect: ColorRect
var _mat: ShaderMaterial
var _lights: Array[Node2D] = []
var _light_radius: Dictionary = {}      ## Node2D → radius px
var _flash_left: float = 0.0
var _flash_total: float = 0.0
var _flash_strength: float = 0.0


func _ready() -> void:
	layer = 80   ## 单位层之上、黑幕(90)/ED名单(95)/章节总结(100)之下
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER
	_mat.shader = sh
	_rect.material = _mat
	add_child(_rect)
	set_darkness(darkness)


func set_darkness(value: float) -> void:
	darkness = clampf(value, 0.0, 1.0)
	if _mat:
		_mat.set_shader_parameter("darkness", darkness)


## 注册动态光源（source 在退出场景树时自动注销）。
## radius_px: 屏幕像素亮圈半径；zoom=2x 视口下 1 世界像素 = 1 屏幕像素（CanvasLayer 无缩放）。
func register_light(source: Node2D, radius_px: float) -> void:
	if source == null:
		return
	if not _lights.has(source):
		_lights.append(source)
		source.tree_exiting.connect(unregister_light.bind(source))
	_light_radius[source] = maxf(radius_px, 16.0)


func unregister_light(source: Node2D) -> void:
	_lights.erase(source)
	_light_radius.erase(source)


## 闪光弹白闪：短暂把黑幕整体压向透明（夜间视界下"照亮全场"）。
func flash(duration: float, strength: float = 0.95) -> void:
	_flash_left = maxf(_flash_left, duration)
	_flash_total = _flash_left
	_flash_strength = clampf(strength, 0.0, 1.0)


func _process(delta: float) -> void:
	if _mat == null:
		return
	# ── 光源uniform刷新（世界→屏幕坐标）──
	var xform := get_viewport().get_canvas_transform()
	var count: int = 0
	var arr := PackedVector3Array()
	for s: Node2D in _lights:
		if not is_instance_valid(s) or not s.is_inside_tree():
			continue
		if count >= MAX_LIGHTS:
			break
		var sp: Vector2 = xform * s.global_position
		arr.append(Vector3(sp.x, sp.y, _light_radius.get(s, 96.0)))
		count += 1
	_mat.set_shader_parameter("light_count", count)
	_mat.set_shader_parameter("lights", arr)
	# ── 闪光衰减：前 30% 保持近全亮（闪光致盲的"白感"），之后 smoothstep 平滑渐暗——
	# 曲线两端斜率趋 0，开始变暗和归零都不会跳变（2026-09-16 用户反馈：要慢慢变回）。
	var f: float = 0.0
	if _flash_left > 0.0:
		_flash_left = maxf(0.0, _flash_left - delta)
		var t: float = 1.0 - _flash_left / maxf(_flash_total, 0.001)  ## 0→1 衰减进度
		var k: float = clampf((t - 0.3) / 0.7, 0.0, 1.0)
		f = _flash_strength * (1.0 - k * k * (3.0 - 2.0 * k))
	_mat.set_shader_parameter("flash_strength", f)
	# 闪光完全结束后复位强度
	if _flash_left <= 0.0 and _flash_strength != 0.0:
		_flash_strength = 0.0
		_mat.set_shader_parameter("flash_strength", 0.0)


## ── 场景级工具：在 current_scene 下查找/创建/移除 NightOverlay ──

static func find_in_scene(scene: Node) -> NightOverlay:
	if scene == null:
		return null
	for child: Node in scene.get_children():
		if child is NightOverlay:
			return child
	return null


## 按 darkness 值同步 overlay 存在性：<=0 移除，>0 创建并设置。
## 返回当前 overlay（可能为 null）。
static func apply_darkness(scene: Node, darkness_value: float) -> NightOverlay:
	if scene == null or not scene.is_inside_tree():
		return null
	var overlay := find_in_scene(scene)
	if darkness_value <= 0.0:
		if overlay:
			overlay.queue_free()
		return null
	if overlay == null:
		overlay = NightOverlay.new()
		scene.add_child(overlay)
	overlay.set_darkness(darkness_value)
	return overlay
