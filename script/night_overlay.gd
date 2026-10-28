class_name NightOverlay extends Node2D

## ── 架构定位 ──
## 系统：夜间视界 ｜ 层：表现（世界 canvas 内的 Node2D，**不是 CanvasLayer**）
## 联机：表现层，各端自行渲染（不联网）
## 职责：Night Hunter 夜间关卡的黑幕 + 光照。只用 Godot 内置 2D 灯光节点：
##   CanvasModulate 乘法打底（含夜间色调）+ 每盏灯一个 PointLight2D（加法提亮），
##   阴影由 TileSet 遮挡层生成的 LightOccluder2D 在 GPU 上裁剪。
## 另有两块**内置节点没有等价物**、必须自己算的能力：
##   ① 火苗闪烁：随机游走 + 低通 + 双正弦，每帧写 PointLight2D.energy
##   ② 角色拖影：照原工程公式（长度 ∝ 离灯距离、远端淡出），只读灯的位置/半径/亮度
## ⚠ 必须待在「世界 canvas」里：Light2D / CanvasModulate 只作用于自己所在的 canvas，
##   塞进 CanvasLayer 就照不到世界精灵。这就是它从 CanvasLayer 改成 Node2D 的原因。
## 依赖：Director 按 DirectorConfig.night_darkness 创建/销毁；FirePatch / LightEmitter 注册光源。
##
## ── 参考（RGD Lighting / RGSS，作者 invwindy）──
## 径向曲线不是拍脑袋 —— 见 GRADIENT_PROFILE，直接从原工程 light.png 量出来的。
## 原工程的"视口之间混合"（@viewport2 挖黑暗 / @viewport1 加法叠色）已由内置 2D 灯光
## 接管（2026-10-21，P3）；旧自研管线（SubViewport + 可见性扇形 + 两个全屏 shader）已删除。

const GROUP: StringName = &"night_overlay"
const MAX_LIGHTS: int = 32

## 灯影响哪些对象（与 CanvasItem.light_mask 是同一套位掩码）。
## 1 = 默认精灵；4 = 玩家（object/player.tscn 的 Sprite2D 设的是 4）。
## 7 = 1|2|4，三种都覆盖 —— 少一位就会出现"某个角色永远不受光"。
const LIGHT_CULL_MASK: int = 7
## 阴影只有 1 号位：与 TileSet occlusion_layer 的 light_mask（已统一为 1）对齐。
const SHADOW_CULL_MASK: int = 1
## PCF5 + 平滑，夜景要软边；None 会看到硬锯齿。
const SHADOW_SMOOTH: float = 3.0
## 灯的离地高度（px）。**必须 > 0 法线贴图才会参与**（PointLight2D.height 默认 0）。
## 角色帧高 64px 时取 32~64 比较自然；值越大光越"平"，越小越贴地容易过曝。
const LIGHT_HEIGHT: float = 48.0

## glow_strength 的基准值。旧管线里 0.5 是"原工程强度"，现在把它当灯光亮度倍率，
## 除以基准后 0.5 → ×1.0，这样 FirePatch / LightLab 现有的 0.5 调用点行为不变。
const GLOW_BASE: float = 0.5

## 全场灯光亮度总倍率（2026-10-21 用户要求"压到 0.7 看看"）。
## 只影响 PointLight2D 的 energy，不影响 darkness、不影响角色拖影。
## 调这个比自己逐盏改 LightEmitter.intensity 省事；想还原就改成 1.0。
const LIGHT_ENERGY_SCALE: float = 0.7

const SHADOW_CAST_SHADER := preload("res://shader/night_shadow_cast.gdshader")

const LIGHT_TEX_SIZE: int = 128

## 原工程 light.png 的径向亮度实测值（半径比例 0%~100%，11 个采样点）。
## 形状是"亮核 + 长尾"的高斯型，跟线性/平台曲线观感差别很大 —— 这是"过渡真实"的关键。
const GRADIENT_PROFILE := [
	0.958, 0.887, 0.791, 0.680, 0.559, 0.435, 0.314, 0.203, 0.106, 0.030, 0.0
]

## 闪烁节奏（2026-10-21 用户反馈"有点快、看得不舒服"后放缓）。
## 原值照搬原工程每 5 帧重掷（0.083s ≈ 12Hz）+ 7.5/17Hz 正弦，实际抖动偏神经质。
## 现改为：0.16s 重掷一次（≈6Hz）+ 2.4/6.2Hz 正弦 —— 读起来像火苗呼吸，而不是电流噪声。
const FLICKER_STEP: float = 0.16
const FLICKER_TAU: float = 0.50

## 闪烁模式（对应 LightEmitter.flicker_mode）
enum FlickerMode {
	MIXED = 0,   ## 随机游走 + 双正弦抖动（默认，最像火苗）
	FIXED = 1,   ## 固定间隔重掷目标值、不起正弦（节奏整齐，像坏灯管）
	RANDOM = 2,  ## 间隔随机、不起正弦（忽快忽慢）
}

## ── 角色投影（严格照原工程公式）──
## 原工程每个角色用两个影子精灵：支点在脚底（Sprite#oy = frame_height），
##   spr.angle   = -atan2(dy, dx) - 90      → 影子沿"灯 → 角色"方向躺出去
##   spr.zoom_y  = len * cast_scale         → **长度与离灯的距离成正比**
##   zoom_x      = |dx|/len（另一个精灵用 dy，两片拼出透视压缩）
##   opacity     = shadow_opacity * (1 - (len-1)/(cast_distance-1)) → 越远越淡
## 再叠加 <effect> "CharacterShadow" 让靠脚底一端实、远端虚，看起来是拖影而不是
## "深色的另一个角色"。我们用一个精灵 + 同样的公式 + 一个 fade 着色器近似。
const TILE_PX: float = 32.0
const SHADOW_SCALE: float = 0.5     ## 原 cast_scale：影子长度 = 角色高 × 距离(格) × 本值
const SHADOW_RANGE: float = 0.0     ## 原 cast_distance：投影作用距离（px），0 = 跟随灯半径
## 最大不透明度。2026-10-21 从 0.45 降到 0.34：角色遮挡体会再叠一层硬影，
## 两层暗色相加会发脏；拖影退成"余韵"、遮挡影当"实体"，叠起来才自然。
const SHADOW_OPACITY: float = 0.34
## 影子整体朝角色方向回缩的比例（× 角色帧高）。0 = 影子脚底与角色脚底精确重合。
const SHADOW_NEAR_NUDGE_RATIO: float = 0.0
## 角色帧底部的透明留白（帧内像素）。行走图脚底下通常有几行全透明，
## 这段留白会被 stretch 放大：2px 留白 × 2 倍拉伸 = 脚下 4px 的空隙，
## 看起来就是"影子比脚底低十几像素"。这里在缩放前补掉，空隙随拉伸等比消失。
const SHADOW_FRAME_BOTTOM_PAD: float = 2.0
## 角色拖影的羽化（单位=贴图像素）。
## ⚠ 2026-10-21 三次调整的结论：
##   v1 按"距离/投影范围"给 0.9~3.2px + 9 点等权均值 → 轮廓糊成一团；
##   v2 按拉伸量给 0~1.6px 仍在边缘发灰；
##   v3 改为中心加权 5 点、上限 0.9px（只柔化边缘带，剪影主体实心）；
##   v4 曾把上限放到 1.5px，但当时 UV 换算基准写错（用帧尺寸当整图尺寸），参数实际被夹死、
##   调了没反应；修好基准后重新标定：上限 **6px**、斜率 **0.80**。
## 单位是**帧内的贴图像素**（1px ≈ 1 个美术像素），仍是中心加权 5 点，只软不糊。
## 想更硬：节点上的 shadow_softness 调 0.5；完全硬边设 0；更软设 1.5~2。
const SHADOW_BLUR_MIN: float = 0.0
const SHADOW_BLUR_MAX: float = 6.0
const SHADOW_BLUR_PER_STRETCH: float = 0.80

static var _gradient_tex_rgb: ImageTexture = null


## 单盏光源的运行时状态。flicker>0 时每 FLICKER_STEP 重掷 target，指数平滑逼近。
class LightRecord:
	var source: Node2D
	var radius: float = 96.0          ## 屏幕像素（会按 zoom 折算成世界半径）
	var intensity: float = 1.0
	var color: Color = Color.WHITE
	var flicker: float = 0.0
	## 闪烁模式（FlickerMode）与重掷间隔。interval <= 0 = 用全局 FLICKER_STEP。
	var flicker_mode: int = 0
	var flicker_interval: float = 0.0
	var occlude: bool = true
	var cur: float = 0.0
	var target: float = 0.0
	var step_left: float = 0.0
	var phase: float = 0.0
	var value: float = 1.0
	## 离地高度（px）。>0 时法线贴图才参与光照；0 = 完全忽略法线。
	var light_height: float = LIGHT_HEIGHT
	## 本盏灯的渲染对象
	var light: PointLight2D = null
	## 角色投影参数（原工程 :cast_shadow / :cast_distance / :cast_scale / :shadow_opacity）
	var cast_shadow: bool = true
	var shadow_scale: float = SHADOW_SCALE
	var shadow_range: float = SHADOW_RANGE
	var shadow_opacity: float = SHADOW_OPACITY
	var exit_hook: Callable = Callable()


var darkness: float = 0.85
## 发光整体倍率。0 = 只挖黑暗不上色；1 = 原工程强度；0.4~0.6 比较克制。
var glow_strength: float = 0.5

## ── 夜间色调（在灯光之前乘法）──
## 想给夜晚加蓝调时用这两个参数，**不要**再往夜图里放 ScreenTone。
## 理由：ScreenTone 是屏幕后处理，采样的是「已经包含灯光」的画面，蓝色调会把暖橙火光
## 一起乘蓝、一起压暗（2026-10-21 实测：R市 混入 29.5% 蓝色乘法，火光被压掉一截）。
## CanvasModulate 在世界精灵之前完成乘法，PointLight2D 之后才加法叠加 → 暖色完整保留。
@export var night_tint: Color = Color(1.0, 1.0, 1.0, 1.0):
	set(v):
		night_tint = v
		_apply_modulate()
## 色调混入强度（对应 ScreenTone 的 intensity × tone_color.a）。0 = 不染色。
@export_range(0.0, 1.0, 0.01) var night_tint_strength: float = 0.0:
	set(v):
		night_tint_strength = v
		_apply_modulate()

var _modulate: CanvasModulate = null   ## 整体乘法打底（夜晚的黑 + 夜间色调）
var _builtin_root: Node2D = null       ## 所有 PointLight2D 的容器
var _flash_value: float = 0.0          ## 闪光弹白闪的当前强度（0~1）
var _records: Array = []
var _shadow_cache: Dictionary = {}   ## 角色 Node2D → 影子 Sprite2D
var _occluder_cache: Dictionary = {} ## 角色 Node2D → 遮挡体 LightOccluder2D
## 参与投影的节点组。正式关卡用 player/enemy；试验场可追加自己的假人组。
var shadow_groups: Array[StringName] = [&"player", &"enemy"]
## 拖影柔化倍率：0 = 完全硬边的像素影子，1 = 默认（最远约 0.9px），2 = 明显发软。
## 只影响角色拖影，不影响墙体阴影（墙影走 Light2D 的 shadow_filter）。可在 Inspector 实时调。
@export_range(0.0, 2.0, 0.05) var shadow_softness: float = 1.0
## 影子其实有**两层**，这个值现在**同时控制两层**（2026-10-21 用户实测反馈后统一）：
##   ① 拖影（NightShadow 精灵）的 alpha 羽化
##   ② 遮挡影（LightOccluder2D 多边形投影）的 shadow_filter_smooth
## 之所以要统一：拖影只在灯半径内才画，站位一远就只剩遮挡影；只调拖影会"看起来没反应"。
## 下面两个参数是遮挡影的**基准值**，实际生效 = 基准 × clamp(shadow_softness, 0, 2)。
## 遮挡阴影的滤波质量：None(最快、最硬) / PCF5 / PCF13(最软、最慢)。
@export_enum("None", "PCF5", "PCF13") var shadow_filter_quality: int = 1
## 遮挡阴影的边缘平滑半径（Light2D.shadow_filter_smooth）。越大越软；会同时影响墙影。
@export_range(0.0, 32.0, 0.5) var shadow_smooth: float = SHADOW_SMOOTH
## 角色是否挡光：给每个角色挂一个贴合身体的 LightOccluder2D。
## ⚠ 内置 2D 灯光**不会**因为精灵挡住了就自动投影，遮挡只认 LightOccluder2D。
##
## 默认 **false（关闭）**，2026-10-21 用户实测结论：
## 多边形投影天然是硬边、且没有距离衰减，和 RGD 拖影的柔边美术方向冲突；
## 缩面积（矩形→下半身椭圆）、加距离渐变、提高 shadow_filter_smooth 都试过，
## 只缓解不消失。关掉后角色影子只由拖影负责，观感统一。
## 想让角色重新挡光就把它勾上——代码与参数都保留，随时可以 A/B。
@export var character_occluders: bool = false
## 角色遮挡体的宽度占帧宽的比例（椭圆直径）。
const OCCLUDER_WIDTH_RATIO: float = 0.40
## 遮挡体的高度占帧高的比例。**只取下半身**：矩形整帧高会投出一条贯穿墙面的硬边黑带，
## 和像素画风冲突（2026-10-21 用户两次反馈）。
const OCCLUDER_HEIGHT_RATIO: float = 0.45
## 椭圆边数。12 ≈ 每 30° 一个点，投影边缘看起来是圆的而不是方的。
const OCCLUDER_SEGMENTS: int = 12
## 灯与角色距离小于 `OCCLUDER_NEAR_DISTANCE` 时遮挡体缩到 0（= 不遮光）；
## 到 `OCCLUDER_NEAR_DISTANCE + OCCLUDER_FADE_DISTANCE` 时长到满尺寸。
## 用**渐变**而不是一刀切：一刀切会让"某些位置有影子、某些位置完全没有"，
## 走两步就跳变，比影子本身更突兀（2026-10-21 用户实测）。
const OCCLUDER_NEAR_DISTANCE: float = 24.0
const OCCLUDER_FADE_DISTANCE: float = 40.0
var _time: float = 0.0
var _flash_left: float = 0.0
var _flash_total: float = 0.0
var _flash_strength: float = 0.0


func _ready() -> void:
	add_to_group(GROUP)
	_build()
	set_darkness(darkness)
	set_glow_strength(glow_strength)
	# 启动日志：用来确认"编辑器里调的值有没有真的进到运行中的实例"。
	# 编辑器 Inspector 的修改不会影响已经在跑的游戏，必须重启（或用远程检查器）。
	print("[NightOverlay] path=%s softness=%.2f smooth=%.1f occluders=%s tint=%.2f" % [
		get_path(), shadow_softness, shadow_smooth, str(character_occluders), night_tint_strength])


## CanvasModulate 负责"黑"，PointLight2D 负责"亮"，遮挡交给 TileSet 遮挡层生成的
## LightOccluder2D（GPU 裁剪，不需要每帧射线）。
func _build() -> void:
	_modulate = CanvasModulate.new()
	_modulate.name = "Modulate"
	add_child(_modulate)
	_builtin_root = Node2D.new()
	_builtin_root.name = "Lights"
	add_child(_builtin_root)
	_apply_modulate()


func set_darkness(value: float) -> void:
	darkness = clampf(value, 0.0, 1.0)
	_apply_modulate()


## 把 darkness / 夜间色调 / 闪光 换算成 CanvasModulate 的颜色。
## 语义对齐：旧管线是 alpha = darkness 的黑幕叠加，等价于整体乘 (1 - darkness)，
## 所以这里直接用 k = 1 - darkness 作为底色，观感才接得上（darkness 0.4 的夜图不会突然变白天）。
## 顺序很关键：先乘 darknes → 再乘夜间色调 → 最后闪光压白（灯光在这一切之后才叠加）。
func _apply_modulate() -> void:
	if _modulate == null:
		return
	var k: float = clampf(1.0 - darkness, 0.0, 1.0)
	# 蓝通道略抬，避免纯灰没有夜感；幅度刻意做小，免得色偏过头。
	var c := Color(k, k, minf(k * 1.06, 1.0))
	if night_tint_strength > 0.0:
		var t: Color = Color(1.0, 1.0, 1.0).lerp(night_tint, night_tint_strength)
		c = Color(c.r * t.r, c.g * t.g, c.b * t.b)
	if _flash_value > 0.0:
		c = c.lerp(Color(1.0, 1.0, 1.0), _flash_value)
	_modulate.color = c


## 发光整体倍率 = 灯光亮度倍率（GLOW_BASE 为基准，0.5 → ×1.0，因此既有调用点无需改动）。
func set_glow_strength(value: float) -> void:
	glow_strength = maxf(value, 0.0)


## 注册动态光源（source 退出场景树时自动注销）。对同一 source 再调 = 更新参数。
## radius_px: 屏幕像素亮圈半径（会按当前 zoom 折算成世界半径）。
## intensity:  亮度。1.0 ≈ 完全点亮中心；0.6~0.8 更接近原工程的克制感。
## color:      光色（加法发光）。火 ≈ Color(1.0, 0.52, 0.22)。
## flicker:    闪烁幅度（0 = 稳定；0.25 火苗；>0.5 故障灯）。
## occlude:    true = 被墙体/家具遮挡（原工程"建筑遮挡"）。
func register_light(source: Node2D, radius_px: float, intensity: float = 1.0,
		color: Color = Color.WHITE, flicker: float = 0.0, occlude: bool = true) -> void:
	if source == null:
		return
	var rec: LightRecord = null
	for r: LightRecord in _records:
		if r.source == source:
			rec = r
			break
	if rec == null:
		if _records.size() >= MAX_LIGHTS:
			return
		rec = LightRecord.new()
		rec.source = source
		rec.phase = randf() * TAU
		rec.step_left = randf() * FLICKER_STEP
		rec.exit_hook = unregister_light.bind(source)
		source.tree_exiting.connect(rec.exit_hook)
		_records.append(rec)
	# 改半径/遮挡不需要重建任何东西：PointLight2D 每帧同步即可。
	rec.radius = maxf(radius_px, 8.0)
	rec.intensity = maxf(intensity, 0.0)
	rec.color = color
	rec.flicker = clampf(flicker, 0.0, 1.0)
	rec.occlude = occlude


## 设置某盏灯的角色投影参数（对应原工程的 cast_shadow / cast_distance / cast_scale /
## shadow_opacity）。同一盏灯再次调用 = 更新。
## scale:   长度倍率。影子长度 = 角色高 × (离灯距离/32) × scale —— 离灯越远越长。
## opacity: 最大不透明度（近处实际值，远处自动衰减）。
## range_px: 投影作用距离（世界像素）。0 = 用灯半径；超出就不投影。
## cast:    false = 这盏灯不投影（原工程 [noshadow]）。
func set_light_shadow(source: Node2D, scale: float = SHADOW_SCALE,
		opacity: float = SHADOW_OPACITY, range_px: float = SHADOW_RANGE,
		cast: bool = true) -> void:
	var rec: LightRecord = null
	for r: LightRecord in _records:
		if r.source == source:
			rec = r
			break
	if rec == null:
		return
	rec.cast_shadow = cast
	rec.shadow_scale = maxf(scale, 0.0)
	rec.shadow_range = maxf(range_px, 0.0)
	rec.shadow_opacity = clampf(opacity, 0.0, 1.0)


func unregister_light(source: Node2D) -> void:
	for i: int in range(_records.size() - 1, -1, -1):
		var rec: LightRecord = _records[i]
		if rec.source == source:
			if is_instance_valid(source) and rec.exit_hook.is_valid() \
					and source.tree_exiting.is_connected(rec.exit_hook):
				source.tree_exiting.disconnect(rec.exit_hook)
			_drop_light(rec)
			_records.remove_at(i)


## 闪光弹白闪：短暂把夜间底色整体压向白（夜间视界下"照亮全场"）。
func flash(duration: float, strength: float = 0.95) -> void:
	_flash_left = maxf(_flash_left, duration)
	_flash_total = _flash_left
	_flash_strength = clampf(strength, 0.0, 1.0)


func _process(delta: float) -> void:
	if _builtin_root == null:
		return
	_time += delta
	var zoom: float = maxf(get_viewport().get_canvas_transform().get_scale().x, 0.001)
	_refresh_builtin(delta, zoom)
	_update_character_shadows(zoom)
	_update_flash(delta)


## 内置模式每帧：推进闪烁、同步 PointLight2D 的位置/半径/颜色/亮度。
## **不做任何射线检测** —— 遮挡由 GPU 按 LightOccluder2D 裁剪，这是本方案最大的性能收益。
func _refresh_builtin(delta: float, zoom: float) -> void:
	var live: Array = []
	var mult: float = glow_strength / GLOW_BASE * LIGHT_ENERGY_SCALE
	for rec: LightRecord in _records:
		if not is_instance_valid(rec.source) or not rec.source.is_inside_tree():
			_drop_light(rec)
			continue
		live.append(rec)
		_advance_flicker(rec, delta)
		_ensure_light(rec)
		var l: PointLight2D = rec.light
		if l == null or not is_instance_valid(l):
			continue
		l.global_position = rec.source.global_position
		var world_radius: float = maxf(rec.radius / zoom, 8.0)
		l.texture_scale = 2.0 * world_radius / float(LIGHT_TEX_SIZE)
		l.color = rec.color
		## 亮度还要乘光源（含父链）的透明度：SignalVisibilityNode 的淡出是 modulate:a → 0，
		## 不跟着衰减就会「贴图慢慢暗、灯一直亮到最后一帧突然灭」。
		l.energy = maxf(rec.intensity * rec.value * mult, 0.0) * _source_alpha(rec)
		l.shadow_enabled = rec.occlude
		l.shadow_filter = shadow_filter_quality
		l.shadow_filter_smooth = shadow_smooth * clampf(shadow_softness, 0.0, 2.0)
		## ★光源节点被隐藏（含父链）时不能发光（2026-10-28 用户实测「一开始隐藏的灯还亮着」）：
		## PointLight2D 是本层自己建的子节点，**不随光源节点显隐**，只能在这里判定。
		l.visible = _source_visible(rec) and l.energy > 0.001
	_records = live


## 光源节点的可见性（含整条父链）。SignalVisibilityNode 这类包装层隐藏时，
## 子层的 LightEmitter 仍然在树里、仍然注册着 —— 必须显式否决它的光照。
func _source_visible(rec: LightRecord) -> bool:
	if not is_instance_valid(rec.source):
		return false
	if rec.source is CanvasItem:
		return (rec.source as CanvasItem).is_visible_in_tree()
	return true


## 光源（含父链）的累计不透明度。包装层做淡出时（modulate:a → 0），灯光要同步变暗；
## CanvasItem 的 modulate 是逐级相乘的，但没有"取累计值"的 API，只能自己往上走。
func _source_alpha(rec: LightRecord) -> float:
	var node: Node = rec.source
	var a: float = 1.0
	while node != null:
		if node is CanvasItem:
			var ci := node as CanvasItem
			a *= ci.modulate.a * ci.self_modulate.a
		node = node.get_parent()
	return clampf(a, 0.0, 1.0)


## 按记录懒创建 PointLight2D（第一次 register 或从白天切夜时）。
func _ensure_light(rec: LightRecord) -> void:
	if rec.light != null and is_instance_valid(rec.light):
		return
	if _builtin_root == null:
		return
	var l := PointLight2D.new()
	l.name = "Light2D_%d" % _builtin_root.get_child_count()
	l.texture = _builtin_gradient_texture()
	l.blend_mode = Light2D.BLEND_MODE_ADD
	l.range_item_cull_mask = LIGHT_CULL_MASK
	l.shadow_item_cull_mask = SHADOW_CULL_MASK
	l.shadow_enabled = rec.occlude
	l.shadow_filter = shadow_filter_quality
	l.shadow_filter_smooth = shadow_smooth * clampf(shadow_softness, 0.0, 2.0)
	l.height = rec.light_height
	_builtin_root.add_child(l)
	rec.light = l


## 调整某盏灯的闪烁：幅度 / 模式 / 重掷间隔（秒，<=0 = 用全局 FLICKER_STEP）。
## 幅度 0 = 不闪；0.2 火苗；0.5 明显；>0.8 故障灯。
func set_light_flicker(source: Node2D, amount: float, mode: int = FlickerMode.MIXED,
		interval: float = 0.0) -> void:
	for rec: LightRecord in _records:
		if rec.source == source:
			rec.flicker = clampf(amount, 0.0, 1.0)
			rec.flicker_mode = clampi(mode, 0, 2)
			rec.flicker_interval = maxf(interval, 0.0)
			return


## 设置某盏灯的离地高度（px）。**>0 才会让法线贴图参与光照**，0 = 忽略法线。
## 默认取 LIGHT_HEIGHT(48)；吊灯/路灯可以调大，地面物件调小。
func set_light_height(source: Node2D, height_px: float) -> void:
	for rec: LightRecord in _records:
		if rec.source == source:
			rec.light_height = maxf(height_px, 0.0)
			if rec.light != null and is_instance_valid(rec.light):
				rec.light.height = rec.light_height
			return


func _drop_light(rec: LightRecord) -> void:
	if rec.light != null and is_instance_valid(rec.light):
		rec.light.queue_free()
	rec.light = null


## 角色投影：找身边最强的灯，把角色剪影作为自己的子节点放到背光侧
## （show_behind_parent → 与角色同一排序槽位，且不会掉到地面图块下面）。
func _update_character_shadows(zoom: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	# 清掉已销毁角色的遮挡体引用，避免字典越积越大
	for key: Variant in _occluder_cache.keys():
		if not is_instance_valid(key):
			_occluder_cache.erase(key)
	if _records.is_empty():
		_hide_all_shadows()
		return
	for group: StringName in shadow_groups:
		for n: Node in tree.get_nodes_in_group(group):
			if not (n is Node2D):
				continue
			var node := n as Node2D
			if node.get("_is_dead") == true or node.get("_is_dying") == true:
				_hide_shadow(node)
				continue
			# 角色挡光：让光在角色身后剪断，人才不像"贴"在地上
			_sync_occluder(node)
			var best: float = 0.0
			var best_dir := Vector2.ZERO
			var best_dist: float = 0.0
			var best_rec: LightRecord = null
			for rec: LightRecord in _records:
				## 隐藏的光源不投影（否则灯关了角色还拖着影子）。
				if rec.intensity <= 0.0 or not rec.cast_shadow or not _source_visible(rec):
					continue
				var wr: float = rec.radius / zoom
				var to_caster: Vector2 = node.global_position - rec.source.global_position
				var d: float = to_caster.length()
				if d > wr * 1.05 or d < 0.001:
					continue
				var closeness: float = 1.0 - d / (wr * 1.05)
				var strength: float = closeness * rec.intensity * rec.value
				if strength > best:
					best = strength
					best_dist = d
					best_dir = to_caster / d
					best_rec = rec
			if best_rec == null:
				_hide_shadow(node)
			else:
				_set_shadow(node, best_dir, best_dist, best_rec, zoom)


## 找到角色身上真正在画的 Sprite2D（角色脚本一般有 `sprite` 属性）。
func _sprite_of(node: Node2D) -> Sprite2D:
	var spr: Variant = node.get("sprite")
	if spr is Sprite2D:
		return spr as Sprite2D
	return node.get_node_or_null("Sprite2D") as Sprite2D


## 角色挡光：给角色挂一个贴身矩形 LightOccluder2D。
## ⚠ 内置 2D 灯光只认 LightOccluder2D —— 精灵挡住并不会自动投影，
##   想让"人挡住光"就必须挂遮挡体（2026-10-21 用户提出）。
func _sync_occluder(node: Node2D) -> void:
	if not character_occluders:
		_remove_occluder(node)
		return
	var spr := _sprite_of(node)
	if spr == null or spr.texture == null:
		_remove_occluder(node)
		return
	var occl: LightOccluder2D = _occluder_cache.get(node)
	if occl == null or not is_instance_valid(occl):
		var shape := OccluderPolygon2D.new()
		shape.closed = true
		# 双面挡光：角色两侧的灯都要被挡，不能按单面法线剔除
		shape.cull_mode = OccluderPolygon2D.CULL_DISABLED
		occl = LightOccluder2D.new()
		occl.name = "NightOccluder"
		occl.occluder = shape
		occl.occluder_light_mask = SHADOW_CULL_MASK
		node.add_child(occl)
		_occluder_cache[node] = occl
	var base_w: float = spr.region_rect.size.x if spr.region_rect.size.x > 0.0 \
			else float(spr.texture.get_width())
	var base_h: float = spr.region_rect.size.y if spr.region_rect.size.y > 0.0 \
			else float(spr.texture.get_height())
	var occ_h: float = base_h * OCCLUDER_HEIGHT_RATIO
	# 灯离得越近，遮挡体越小 → 影子随距离平滑长出来，不会"走两步突然有/没有"。
	var nearest: float = INF
	for rec: LightRecord in _records:
		if is_instance_valid(rec.source):
			nearest = minf(nearest, node.global_position.distance_to(rec.source.global_position))
	var grown: float = clampf((nearest - OCCLUDER_NEAR_DISTANCE) / OCCLUDER_FADE_DISTANCE, 0.0, 1.0)
	grown = grown * grown * (3.0 - 2.0 * grown)   # smoothstep
	var rx: float = base_w * OCCLUDER_WIDTH_RATIO * 0.5 * grown
	var ry: float = occ_h * 0.5 * grown
	# 精灵默认 centered：底边 = 中心 + 半高，对应脚下
	occl.position = Vector2(spr.position.x, spr.position.y + base_h * 0.5)
	# 只用**下半身**：一个贴地的椭圆，底边压住脚底、顶到腰。
	# 矩形会在墙上投出一条笔直的硬边黑带，椭圆读起来才像"腿"。
	var shape2: OccluderPolygon2D = occl.occluder
	var pts := PackedVector2Array()
	pts.resize(OCCLUDER_SEGMENTS)
	for i: int in OCCLUDER_SEGMENTS:
		var a: float = TAU * float(i) / float(OCCLUDER_SEGMENTS)
		pts[i] = Vector2(cos(a) * rx, -occ_h * grown + ry + sin(a) * ry)
	shape2.polygon = pts
	# 缩到几乎没面积时干脆关掉，省掉一次无意义的阴影计算
	occl.occluder_light_mask = SHADOW_CULL_MASK if grown > 0.02 else 0


func _remove_occluder(node: Node2D) -> void:
	var occl: Variant = _occluder_cache.get(node)
	if occl is LightOccluder2D and is_instance_valid(occl):
		(occl as LightOccluder2D).queue_free()
	_occluder_cache.erase(node)


func _shadow_for(node: Node2D) -> Sprite2D:
	var cached: Variant = _shadow_cache.get(node)
	if cached is Sprite2D and is_instance_valid(cached):
		return cached as Sprite2D
	var sh := Sprite2D.new()
	sh.name = "NightShadow"
	# 支点放左下角，再由 offset 挪到底边中点 → 旋转/缩放都绕"脚底"发生（同原工程 oy=frame_height）
	sh.centered = false
	sh.offset = Vector2(0, 0)
	var mat := ShaderMaterial.new()
	mat.shader = SHADOW_CAST_SHADER
	sh.material = mat
	# show_behind_parent：画在角色自身之前，但仍在同一个 y-sort 槽位。
	sh.show_behind_parent = true
	sh.z_index = 0
	sh.z_as_relative = true
	node.add_child(sh)
	_shadow_cache[node] = sh
	return sh


## 影子 = 支点在脚底的剪影，沿"灯 → 角色"方向躺出去，长度随离灯距离增长。
## 公式与原工程一致：
##   angle  = atan2(dir.x, -dir.y)   （让剪影的"头"朝远离灯的一侧）
##   zoom_y = (距离 / 32) * shadow_scale
##   alpha  = shadow_opacity * (1 - 距离 / 投影范围)，再由 shader 沿长度二次淡出
## 位置不需要额外偏移：精灵支点就在脚底，旋转/缩放都绕脚底进行。
func _set_shadow(node: Node2D, dir: Vector2, dist: float, rec: LightRecord, zoom: float) -> void:
	# 角色脚本一般有 `sprite` 属性；没有的话退回找名为 Sprite2D 的子节点（试验场假人）。
	var spr: Variant = node.get("sprite")
	if not (spr is Sprite2D):
		spr = node.get_node_or_null("Sprite2D")
	if not (spr is Sprite2D) or (spr as Sprite2D).texture == null:
		_hide_shadow(node)
		return
	var s := spr as Sprite2D
	var range_px: float = rec.shadow_range if rec.shadow_range > 0.0 else rec.radius / zoom
	if dist >= range_px or rec.shadow_opacity <= 0.0:
		_hide_shadow(node)
		return
	var stretch: float = (dist / TILE_PX) * rec.shadow_scale
	if stretch <= 0.02:
		_hide_shadow(node)
		return
	var fade: float = clampf(1.0 - dist / maxf(range_px, 1.0), 0.0, 1.0)
	var base_w: float = s.region_rect.size.x if s.region_rect.size.x > 0.0 else float(s.texture.get_width())
	var base_h: float = s.region_rect.size.y if s.region_rect.size.y > 0.0 else float(s.texture.get_height())
	var spr_texture_size: Vector2 = s.texture.get_size()
	var h: float = base_h * absf(s.scale.y)
	var sh := _shadow_for(node)
	sh.texture = s.texture
	sh.region_enabled = s.region_enabled
	sh.region_rect = s.region_rect
	sh.flip_h = s.flip_h
	# 支点放到底边中点（脚底），这样 scale.y / rotation 都绕脚底做。
	sh.offset = Vector2(-base_w * 0.5, -base_h + SHADOW_FRAME_BOTTOM_PAD)
	sh.position = s.position + Vector2(0.0, h * 0.5) - dir * (h * SHADOW_NEAR_NUDGE_RATIO)
	# 拉得越长越收窄一点，避免变成一条胖带子
	# 拉得越长越收窄（0.14 → 0.22）：原来的尾部偏胖，和遮挡影叠起来像一条粗带子
	var width_scale: float = clampf(1.0 - 0.22 * stretch, 0.45, 1.0)
	# ⚠ 不做插值/阻尼：原工程每帧直接用 angle / zoom_y 重算。
	#   加平滑会让影子跟着走位"弹"，看着像橡皮筋（2026-10-19 用户反馈）。
	sh.rotation = atan2(dir.x, -dir.y)
	sh.scale = Vector2(s.scale.x * width_scale, s.scale.y * stretch)
	# 原工程 opacity_factor_near = 1-(len-1)/(cast_distance-1)：到边界时已经几乎是 0，
	# 所以它的 visible=false 看不出来。旧实现留了 0.35 的下限，走到边界会"啪"地消失。
	# 再乘灯的当前亮度：火焰熄灭时灯是渐暗的，影子要跟着一起淡掉，不能等灯被移除才消失。
	var alpha: float = rec.shadow_opacity * smoothstep(0.0, 1.0, fade) \
			* clampf(rec.intensity * rec.value, 0.0, 1.0)
	if alpha <= 0.004:
		_hide_shadow(node)
		return
	# 羽化：跟随拉伸量（拉得越长越软），脚底保持清晰；shadow_softness 可整体关掉。
	var blur: float = clampf(stretch * SHADOW_BLUR_PER_STRETCH * shadow_softness,
			SHADOW_BLUR_MIN, SHADOW_BLUR_MAX * maxf(shadow_softness, 0.0))
	# region 切图时必须告诉 shader 本次只在本帧范围内采样，否则模糊会吃到相邻帧。
	var bounds := Rect2(0.0, 0.0, 1.0, 1.0)
	if s.region_enabled and s.texture != null:
		var tsz: Vector2 = spr_texture_size
		if tsz.x > 0.0 and tsz.y > 0.0:
			bounds = Rect2(s.region_rect.position / tsz, s.region_rect.size / tsz)
	var mat := sh.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("fade_near", alpha)
		# 末端几乎全透明（0.08 → 0.02）：让拖影"化开"而不是突然截断
		mat.set_shader_parameter("fade_far", alpha * 0.02)
		mat.set_shader_parameter("sprite_height", base_h)
		mat.set_shader_parameter("blur_px", blur)
		# ⚠ 必须是**整张贴图**的像素尺寸，不是单帧尺寸。region 切图的 UV 是按整图归一化的，
		#   用帧尺寸算偏移会放大 (贴图宽/帧宽) 倍（玩家图集 576/48 = 12 倍），
		#   四个采样点全被 uv_bounds 夹死在帧边缘 —— 表现就是"怎么调模糊都没反应"。
		mat.set_shader_parameter("tex_size", spr_texture_size)
		mat.set_shader_parameter("uv_bounds",
				Vector4(bounds.position.x, bounds.position.y, bounds.end.x, bounds.end.y))
	sh.modulate = Color(0.0, 0.0, 0.0, 1.0)
	sh.visible = true


func _hide_shadow(node: Node2D) -> void:
	var cached: Variant = _shadow_cache.get(node)
	if cached is Sprite2D and is_instance_valid(cached):
		(cached as Sprite2D).visible = false


func _hide_all_shadows() -> void:
	for key: Variant in _shadow_cache.keys():
		var v: Variant = _shadow_cache[key]
		if is_instance_valid(v):
			(v as Sprite2D).visible = false
		else:
			_shadow_cache.erase(key)


func _update_flash(delta: float) -> void:
	# 前 30% 保持近全亮（闪光致盲的"白感"），之后 smoothstep 平滑渐暗。
	var f: float = 0.0
	if _flash_left > 0.0:
		_flash_left = maxf(0.0, _flash_left - delta)
		var t: float = 1.0 - _flash_left / maxf(_flash_total, 0.001)
		var k: float = clampf((t - 0.3) / 0.7, 0.0, 1.0)
		f = _flash_strength * (1.0 - k * k * (3.0 - 2.0 * k))
	if not is_equal_approx(f, _flash_value):
		_flash_value = f
		_apply_modulate()
	if _flash_left <= 0.0 and _flash_strength != 0.0:
		_flash_strength = 0.0


## 闪烁推进：随机游走（低频）+ 正弦抖动（高频），两者都乘 flicker 幅度。
## 模式只影响"什么时候重掷目标值"和"要不要叠正弦"，平滑本身始终走低通，避免硬跳。
func _advance_flicker(rec: LightRecord, delta: float) -> void:
	if rec.flicker <= 0.0:
		rec.value = 1.0
		rec.cur = 0.0
		rec.target = 0.0
		return
	rec.step_left -= delta
	if rec.step_left <= 0.0:
		var base: float = rec.flicker_interval if rec.flicker_interval > 0.0 else FLICKER_STEP
		match rec.flicker_mode:
			FlickerMode.FIXED:
				rec.step_left = base
			FlickerMode.RANDOM:
				rec.step_left = base * randf_range(0.45, 1.9)
			_:
				rec.step_left = base * randf_range(0.75, 1.35)
		rec.target = randf_range(-1.0, 1.0)
	var k: float = 1.0 - exp(-delta / FLICKER_TAU)
	rec.cur = lerpf(rec.cur, rec.target, k)
	var fast: float = 0.0
	if rec.flicker_mode == FlickerMode.MIXED:
		fast = sin(_time * 2.4 + rec.phase) * 0.15 + sin(_time * 6.2 + rec.phase * 2.3) * 0.05
	rec.value = maxf(0.0, 1.0 + rec.flicker * (rec.cur * 0.8 + fast))


## 光晕贴图：**RGB 放曲线，A 固定为 1（不透明）**，所有光源共用。
##
## ⚠ 2026-10-21 实测修正：之前的写法是 RGB 和 A 都放曲线，结果"中心还行、外围明显偏暗"。
## 原因是 PointLight2D 的加法混合会把贴图的 **alpha 也乘进去**，等于把衰减曲线平方了一次：
##   r=50% 处 0.559 → 0.31，r=70% 处 0.314 → 0.10 —— 光池看起来就"缩了一圈"。
## 改成 A=1 后，衰减只由 RGB 决定，光池才和预期一致。
func _builtin_gradient_texture() -> ImageTexture:
	if _gradient_tex_rgb != null:
		return _gradient_tex_rgb
	var img := Image.create(LIGHT_TEX_SIZE, LIGHT_TEX_SIZE, false, Image.FORMAT_RGBA8)
	var c: float = float(LIGHT_TEX_SIZE) * 0.5
	for y: int in LIGHT_TEX_SIZE:
		for x: int in LIGHT_TEX_SIZE:
			var d: float = Vector2(x - c + 0.5, y - c + 0.5).length() / c
			var p: float = _profile(d)
			img.set_pixel(x, y, Color(p, p, p, 1.0))
	_gradient_tex_rgb = ImageTexture.create_from_image(img)
	return _gradient_tex_rgb


## 线性插值取 GRADIENT_PROFILE；半径外为 0。
func _profile(t: float) -> float:
	if t >= 1.0:
		return 0.0
	if t <= 0.0:
		return GRADIENT_PROFILE[0]
	var f: float = t * 10.0
	var i: int = int(f)
	var frac: float = f - float(i)
	var a: float = GRADIENT_PROFILE[i]
	var b: float = GRADIENT_PROFILE[mini(i + 1, GRADIENT_PROFILE.size() - 1)]
	return lerpf(a, b, frac)


## ── 场景级工具：在 current_scene 下查找/创建/移除 NightOverlay ──

static func find_in_scene(scene: Node) -> NightOverlay:
	if scene == null:
		return null
	for child: Node in scene.get_children():
		if child is NightOverlay:
			return child
	return null


## 任意节点找本图的遮罩：先按组（试验场 / 单元测试里 current_scene 可能不是地图根），
## 再退回 current_scene 的直接子节点。找不到返回 null（白天关卡）。
static func find_any(node: Node) -> NightOverlay:
	if node == null or not node.is_inside_tree():
		return null
	var tree: SceneTree = node.get_tree()
	var by_group: Node = tree.get_first_node_in_group(GROUP)
	if by_group is NightOverlay:
		return by_group as NightOverlay
	return find_in_scene(tree.current_scene)


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
