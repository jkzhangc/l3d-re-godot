class_name NightOverlay extends CanvasLayer

## ── 架构定位 ──
## 系统：夜间视界 ｜ 层：表现（CanvasLayer 5）
## 联机：表现层，各端自行渲染（不联网）
## 职责：Night Hunter 夜间关卡的黑幕 + 光照合成。三个部分：
##   ① 光照缓冲（SubViewport）：每盏灯一个"可见性扇形"多边形 + 径向光晕贴图，加法累加；
##   ② 黑幕：采样缓冲，按亮度挖掉黑暗；
##   ③ 发光：采样缓冲做加法上色 + 色调映射。
## 依赖：Director 按 DirectorConfig.night_darkness 创建/销毁；FirePatch / LightEmitter 注册光源。
##
## ── 参考（RGD Lighting / RGSS，作者 invwindy）──
## 原工程正是"视口之间混合"：@viewport2 里用 light.png 挖黑暗，@viewport1 里用
## light-illum.png 加法叠色，再对每帧的 light_rand 做低通滤波得到火苗抖动。
## 这里同构搬到 Godot：SubViewport = 光照缓冲，两个全屏 ColorRect = 两次合成。
## 径向曲线也不是拍脑袋 —— 见 GRADIENT_PROFILE，直接从原工程 light.png 量出来的。

const GROUP: StringName = &"night_overlay"
## 上限只用于记录数量保护；缓冲里多画几个多边形本身不贵。
const MAX_LIGHTS: int = 32

## 层级（2026-10-19 用户实测修复）：夜晚黑幕必须**压在世界之上、所有 UI 之下**。
## 旧值 80 会盖住 CombatHUD（layer 10）与触摸控件（layer 80）。
## 5 = 世界(0) 之上，CombatHUD(10) / 色调(50) / 触摸(80) / 黑幕(90) / ED(95) / 菜单(100) 之下。
## ⚠ 别改回 >=10：这是「滤镜只染世界、不染 UI」的唯一手段。
const OVERLAY_LAYER: int = 5

const SHADOW_SHADER := preload("res://shader/night_shadow.gdshader")
const SHADOW_CAST_SHADER := preload("res://shader/night_shadow_cast.gdshader")
const GLOW_SHADER := preload("res://shader/night_glow.gdshader")

## 光被什么挡住：只对图块"角色层"（collision_layer bit0 = 1）做射线检测。
## 墙体、桌椅都挂在这一层 —— 与原工程"建筑遮挡"同义。
const OCCLUSION_MASK: int = 1
## 可见性扇形射线数。160 条 = 2.25° 一条，墙角落差在 640×480 世界里够细。
const RAY_COUNT: int = 160
## 光照缓冲相对视口的分辨率。0.5 = 半分辨率，靠线性过滤天然得到柔和的影子边缘。
const BUFFER_SCALE: float = 0.5
const LIGHT_TEX_SIZE: int = 128

## 原工程 light.png 的径向亮度实测值（半径比例 0%~100%，11 个采样点）。
## 形状是"亮核 + 长尾"的高斯型，跟线性/平台曲线观感差别很大 —— 这是"过渡真实"的关键。
const GRADIENT_PROFILE := [
	0.958, 0.887, 0.791, 0.680, 0.559, 0.435, 0.314, 0.203, 0.106, 0.030, 0.0
]

## 闪烁节奏：对应原工程每 5 帧（60fps ≈ 0.083s）重掷一次 light_rand。
const FLICKER_STEP: float = 0.083
const FLICKER_TAU: float = 0.35
## 闪烁时半径的呼吸比例（强度变化的百分比）。
const FLICKER_RADIUS_RATIO: float = 0.35

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
const SHADOW_OPACITY: float = 0.45  ## 最大不透明度
## 影子整体朝角色方向回缩的比例（× 角色帧高）。
## 0 = 影子脚底与角色脚底精确重合（默认，符合原工程 spr.oy = frame_height 的语义）。
## 只有某些素材帧底部带空白时，才需要把它调大（0.1 ≈ 6px）来补掉空隙。
const SHADOW_NEAR_NUDGE_RATIO: float = 0.0

static var _gradient_tex: ImageTexture = null


## 单盏光源的运行时状态。flicker>0 时每 FLICKER_STEP 重掷 target，指数平滑逼近。
class LightRecord:
	var source: Node2D
	var radius: float = 96.0          ## 屏幕像素（会按 zoom 折算成世界半径）
	var intensity: float = 1.0
	var color: Color = Color.WHITE
	var flicker: float = 0.0
	var occlude: bool = true
	var cur: float = 0.0
	var target: float = 0.0
	var step_left: float = 0.0
	var phase: float = 0.0
	var value: float = 1.0
	var poly: Polygon2D = null
	## 角色投影参数（原工程 :cast_shadow / :cast_distance / :cast_scale / :shadow_opacity）
	var cast_shadow: bool = true
	var shadow_scale: float = SHADOW_SCALE
	var shadow_range: float = SHADOW_RANGE
	var shadow_opacity: float = SHADOW_OPACITY
	var last_pos: Vector2 = Vector2(INF, INF)
	var last_radius: float = -1.0
	var settle_left: float = 0.6      ## 延迟重建：地图碰撞体可能比光源晚就绪
	var exit_hook: Callable = Callable()


var darkness: float = 0.85
## 发光整体倍率。0 = 只挖黑暗不上色；1 = 原工程强度；0.4~0.6 比较克制。
var glow_strength: float = 0.5

var _sv: SubViewport
var _root: Node2D
var _tex: ViewportTexture
var _rect: ColorRect
var _mat: ShaderMaterial          ## 黑幕材质（既有用例按此名读取）
var _rect_glow: ColorRect
var _mat_glow: ShaderMaterial
var _add_mat: CanvasItemMaterial
var _records: Array = []
var _shadow_cache: Dictionary = {}   ## 角色 Node2D → 影子 Sprite2D
## 参与投影的节点组。正式关卡用 player/enemy；试验场可追加自己的假人组。
var shadow_groups: Array[StringName] = [&"player", &"enemy"]
var _time: float = 0.0
var _glow_enabled: bool = true
var _flash_left: float = 0.0
var _flash_total: float = 0.0
var _flash_strength: float = 0.0


func _ready() -> void:
	layer = OVERLAY_LAYER
	add_to_group(GROUP)
	_build_light_buffer()
	_rect = _make_rect()
	_mat = _make_material(SHADOW_SHADER)
	_rect.material = _mat
	add_child(_rect)
	# 加法 pass 必须晚于黑幕绘制（同一 CanvasLayer 内按子节点顺序）。
	_rect_glow = _make_rect()
	_mat_glow = _make_material(GLOW_SHADER)
	_rect_glow.material = _mat_glow
	add_child(_rect_glow)
	if _tex:
		_mat.set_shader_parameter("light_tex", _tex)
		_mat_glow.set_shader_parameter("light_tex", _tex)
	set_darkness(darkness)
	set_glow_strength(glow_strength)
	var vp := get_viewport()
	if vp and not vp.size_changed.is_connected(_sync_size):
		vp.size_changed.connect(_sync_size)


## 光照缓冲：一个透明的 SubViewport，里面只有"灯光多边形"。
func _build_light_buffer() -> void:
	_sv = SubViewport.new()
	_sv.name = "LightBuffer"
	_sv.transparent_bg = true
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sv.disable_3d = true
	_sv.msaa_2d = Viewport.MSAA_DISABLED
	_sv.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	# HDR：允许 rgb > 1，发光那一步才能做漂亮的指数色调映射（不爆白）。
	if "use_hdr_2d" in _sv:
		_sv.use_hdr_2d = true
	add_child(_sv)
	_root = Node2D.new()
	_root.name = "Lights"
	_sv.add_child(_root)
	_sync_size()
	_tex = _sv.get_texture()
	_add_mat = CanvasItemMaterial.new()
	_add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD


func _sync_size() -> void:
	var vp := get_viewport()
	if vp == null or _sv == null:
		return
	var s: Vector2 = vp.get_visible_rect().size * BUFFER_SCALE
	_sv.size = Vector2i(maxi(int(s.x), 8), maxi(int(s.y), 8))


func _make_rect() -> ColorRect:
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _make_material(sh: Shader) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = sh
	return m


func set_darkness(value: float) -> void:
	darkness = clampf(value, 0.0, 1.0)
	if _mat:
		_mat.set_shader_parameter("darkness", darkness)


## 发光整体倍率：0 = 关闭加法上色，1 = 原工程强度。
func set_glow_strength(value: float) -> void:
	glow_strength = maxf(value, 0.0)
	_glow_enabled = glow_strength > 0.0
	if _mat_glow:
		_mat_glow.set_shader_parameter("glow_strength", glow_strength)
	if _rect_glow:
		_rect_glow.visible = _glow_enabled


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
	# 只有"会改变可见性扇形"的参数变化才需要重建（160 条射线不便宜）。
	# 改亮度/颜色/闪烁（比如火焰熄灭时的淡出）每帧调用也不会触发重建。
	var geometry_changed: bool = not is_equal_approx(rec.radius, maxf(radius_px, 8.0)) \
			or rec.occlude != occlude
	rec.radius = maxf(radius_px, 8.0)
	rec.intensity = maxf(intensity, 0.0)
	rec.color = color
	rec.flicker = clampf(flicker, 0.0, 1.0)
	rec.occlude = occlude
	if geometry_changed:
		rec.last_pos = Vector2(INF, INF)  ## 下一帧重建
		rec.settle_left = 0.6


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
			_drop_poly(rec)
			_records.remove_at(i)


func _drop_poly(rec: LightRecord) -> void:
	if rec.poly != null and is_instance_valid(rec.poly):
		rec.poly.queue_free()
	rec.poly = null


## 闪光弹白闪：短暂把黑幕整体压向透明（夜间视界下"照亮全场"）。
func flash(duration: float, strength: float = 0.95) -> void:
	_flash_left = maxf(_flash_left, duration)
	_flash_total = _flash_left
	_flash_strength = clampf(strength, 0.0, 1.0)


func _process(delta: float) -> void:
	if _mat == null:
		return
	_time += delta
	var xform := get_viewport().get_canvas_transform()
	var zoom: float = maxf(xform.get_scale().x, 0.001)
	# 世界坐标 → 缓冲像素：先套主画布变换，再整体缩到缓冲分辨率。
	var buffer_scale := Transform2D(0.0, Vector2(BUFFER_SCALE, BUFFER_SCALE), 0.0, Vector2.ZERO)
	_root.transform = buffer_scale * xform
	_refresh_lights(delta, zoom)
	_update_character_shadows(zoom)
	_update_flash(delta)


func _refresh_lights(delta: float, zoom: float) -> void:
	var live: Array = []
	for rec: LightRecord in _records:
		if not is_instance_valid(rec.source) or not rec.source.is_inside_tree():
			_drop_poly(rec)
			continue
		live.append(rec)
		_advance_flicker(rec, delta)
		var pos: Vector2 = rec.source.global_position
		var world_radius: float = maxf(rec.radius / zoom, 8.0)
		if rec.poly == null or pos.distance_to(rec.last_pos) > 3.0 \
				or absf(world_radius - rec.last_radius) > 1.5:
			_rebuild_poly(rec, pos, world_radius)
		elif rec.occlude and rec.settle_left > 0.0:
			# 地图碰撞体可能比光源晚一帧就绪：延迟补一次重建，避免"光穿墙"的假象。
			rec.settle_left -= delta
			if rec.settle_left <= 0.0:
				_rebuild_poly(rec, pos, world_radius)
		var e: float = rec.intensity * rec.value
		rec.poly.color = Color(rec.color.r * e, rec.color.g * e, rec.color.b * e, 1.0)
		rec.poly.visible = e > 0.001
	_records = live


## 重建可见性扇形 → 多边形顶点 + UV（UV 让光晕贴图正好铺满以光源为心、半径 R 的方框）。
func _rebuild_poly(rec: LightRecord, pos: Vector2, world_radius: float) -> void:
	if rec.poly == null or not is_instance_valid(rec.poly):
		rec.poly = Polygon2D.new()
		rec.poly.name = "Light%d" % _root.get_child_count()
		rec.poly.texture = _gradient_texture()
		rec.poly.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		rec.poly.material = _add_mat
		_root.add_child(rec.poly)
	var fan: PackedVector2Array = _cast_fan(pos, world_radius, rec.occlude)
	var pts := PackedVector2Array()
	var uvs := PackedVector2Array()
	pts.resize(fan.size())
	uvs.resize(fan.size())
	var inv: float = 1.0 / (2.0 * world_radius)
	for i: int in fan.size():
		var rel: Vector2 = fan[i] - pos
		pts[i] = rel
		# ⚠ Polygon2D.uv 是**贴图像素坐标**，不是 0~1 归一化（2026-10-19 实测：
		# 传归一化值会让整个多边形采样到贴图左上角 alpha=0 → 灯完全不亮）。
		uvs[i] = (rel * inv + Vector2(0.5, 0.5)) * float(LIGHT_TEX_SIZE)
	rec.poly.position = pos
	rec.poly.polygon = pts
	rec.poly.uv = uvs
	rec.last_pos = pos
	rec.last_radius = world_radius


## 在半径内做一圈射线，被图块挡住的点回退到碰撞面前 → 扇形即为"可见范围"。
## occlusion = false 时返回整圆（白天/无遮挡需求的光源零成本）。
func _cast_fan(center: Vector2, radius: float, occlusion: bool) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(RAY_COUNT)
	if not occlusion:
		for i: int in RAY_COUNT:
			var a: float = TAU * float(i) / float(RAY_COUNT)
			pts[i] = center + Vector2(cos(a), sin(a)) * radius
		return pts
	var vp := get_viewport()
	var space: PhysicsDirectSpaceState2D = vp.world_2d.direct_space_state if vp else null
	if space == null:
		for i: int in RAY_COUNT:
			var a0: float = TAU * float(i) / float(RAY_COUNT)
			pts[i] = center + Vector2(cos(a0), sin(a0)) * radius
		return pts
	var q := PhysicsRayQueryParameters2D.create(center, center, OCCLUSION_MASK)
	q.collide_with_areas = false
	for i: int in RAY_COUNT:
		var a: float = TAU * float(i) / float(RAY_COUNT)
		var dir := Vector2(cos(a), sin(a))
		q.from = center
		q.to = center + dir * radius
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			pts[i] = q.to
		else:
			var hp: Vector2 = hit["position"]
			var d: float = hp.distance_to(center)
			# 贴墙的灯：命中点几乎重合时按整半径处理，否则会缩成一个黑点。
			pts[i] = center + dir * maxf(d - 1.5, radius * 0.02)
	return pts


## 角色投影：找身边最强的灯，把角色剪影作为自己的子节点放到背光侧
## （show_behind_parent → 与角色同一排序槽位，且不会掉到地面图块下面）。
func _update_character_shadows(zoom: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
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
			var best: float = 0.0
			var best_dir := Vector2.ZERO
			var best_dist: float = 0.0
			var best_rec: LightRecord = null
			for rec: LightRecord in _records:
				if rec.intensity <= 0.0 or not rec.cast_shadow or not is_instance_valid(rec.source):
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
	var h: float = base_h * absf(s.scale.y)
	var sh := _shadow_for(node)
	sh.texture = s.texture
	sh.region_enabled = s.region_enabled
	sh.region_rect = s.region_rect
	sh.flip_h = s.flip_h
	# 支点放到底边中点（脚底），这样 scale.y / rotation 都绕脚底做。
	sh.offset = Vector2(-base_w * 0.5, -base_h)
	sh.position = s.position + Vector2(0.0, h * 0.5) - dir * (h * SHADOW_NEAR_NUDGE_RATIO)
	# 拉得越长越收窄一点，避免变成一条胖带子
	var width_scale: float = clampf(1.0 - 0.14 * stretch, 0.55, 1.0)
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
	var mat := sh.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("fade_near", alpha)
		mat.set_shader_parameter("fade_far", alpha * 0.08)
		mat.set_shader_parameter("sprite_height", base_h)
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
	_mat.set_shader_parameter("flash_strength", f)
	if _flash_left <= 0.0 and _flash_strength != 0.0:
		_flash_strength = 0.0
		_mat.set_shader_parameter("flash_strength", 0.0)


## 闪烁推进：随机游走（低频）+ 正弦抖动（高频），两者都乘 flicker 幅度。
func _advance_flicker(rec: LightRecord, delta: float) -> void:
	if rec.flicker <= 0.0:
		rec.value = 1.0
		rec.cur = 0.0
		rec.target = 0.0
		return
	rec.step_left -= delta
	if rec.step_left <= 0.0:
		rec.step_left = FLICKER_STEP * randf_range(0.75, 1.35)
		rec.target = randf_range(-1.0, 1.0)
	var k: float = 1.0 - exp(-delta / FLICKER_TAU)
	rec.cur = lerpf(rec.cur, rec.target, k)
	var fast: float = sin(_time * 7.5 + rec.phase) * 0.22 + sin(_time * 17.0 + rec.phase * 2.3) * 0.1
	rec.value = maxf(0.0, 1.0 + rec.flicker * (rec.cur * 0.8 + fast))


## 光晕贴图：按原工程 light.png 的实测曲线生成（白色 + alpha 衰减），所有光源共用。
func _gradient_texture() -> ImageTexture:
	if _gradient_tex != null:
		return _gradient_tex
	var img := Image.create(LIGHT_TEX_SIZE, LIGHT_TEX_SIZE, false, Image.FORMAT_RGBA8)
	var c: float = float(LIGHT_TEX_SIZE) * 0.5
	for y: int in LIGHT_TEX_SIZE:
		for x: int in LIGHT_TEX_SIZE:
			var d: float = Vector2(x - c + 0.5, y - c + 0.5).length() / c
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, _profile(d)))
	_gradient_tex = ImageTexture.create_from_image(img)
	return _gradient_tex


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
