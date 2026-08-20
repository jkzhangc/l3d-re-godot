extends Camera2D
## 相机跟随 + 地图边界限制。
##
## 基于 Phantom Camera 插件实现：
##   - 运行时动态创建 PhantomCameraHost + PhantomCamera2D 子节点
##   - SIMPLE 跟随模式 + 阻尼平滑 + 地图边界限制（显式 limit 四边）
## 保留原有 @export 接口，外部脚本（character_switch_manager 等）无感切换。


# ═══════════════════════════════════════
# Phantom Camera 脚本（preload，避免依赖全局 class_name 缓存）
# ═══════════════════════════════════════

const PhantomCameraHostScript := preload("res://addons/phantom_camera/scripts/phantom_camera_host/phantom_camera_host.gd")
const PhantomCamera2DScript := preload("res://addons/phantom_camera/scripts/phantom_camera/phantom_camera_2d.gd")


# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════

@export_group("Follow")
@export var follow_enabled: bool = true
## 平滑跟随速度（越大越快，1=瞬间跟随）。映射为 Phantom 阻尼值 1/follow_speed。
@export var follow_speed: float = 5.0
## 默认缩放（所有地图场景统一 2x）
@export var default_zoom: Vector2 = Vector2(2, 2)

@export_group("Bounds")
@export var limit_to_map: bool = true
## 边界缓冲（像素，正数=镜头可以略超出地图边缘）
@export var bounds_margin: float = 32.0
## 用于计算边界的 TileMapLayer 节点路径（计算并集）
@export var bound_layers: Array[NodePath] = []


# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════

var _target: Node2D = null
var _pcam_host: Node = null
var _pcam: Node2D = null


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════

func _ready() -> void:
	# 应用默认缩放
	zoom = default_zoom
	# 从注册表获取本地玩家
	_target = Players.get_local_entity()
	if follow_enabled:
		_setup_phantom_camera()


## 运行时创建 PhantomCameraHost + PhantomCamera2D，接管本相机的跟随逻辑。
func _setup_phantom_camera() -> void:
	# 1. Host（必须是 Camera2D 的子节点）
	_pcam_host = PhantomCameraHostScript.new()
	_pcam_host.name = "PhantomCameraHost"
	add_child(_pcam_host)

	# 2. PhantomCamera2D（SIMPLE 跟随玩家）
	_pcam = PhantomCamera2DScript.new()
	_pcam.name = "PhantomCamera2D"
	_pcam.follow_mode = PhantomCamera2DScript.FollowMode.SIMPLE
	_pcam.zoom = default_zoom
	_pcam.follow_damping = follow_speed > 0.0
	if follow_speed > 0.0:
		_pcam.follow_damping_value = Vector2(1.0 / follow_speed, 1.0 / follow_speed)
	# 跳过载入时的默认 1s 过渡，直接吸附玩家
	_pcam.tween_on_load = false
	_pcam.follow_target = _target
	# 初始位置对齐玩家，避免首帧从 (0,0) 飞入
	if _target:
		_pcam.position = _target.global_position
	add_child(_pcam)

	# 3. 地图边界限制
	if limit_to_map:
		_setup_map_limits()


## 网络实体在场景加载后才创建时，由 NetworkWorld 重新绑定镜头目标。
func set_follow_target(target: Node2D) -> void:
	_target = target if target and is_instance_valid(target) else null
	if is_instance_valid(_pcam):
		_pcam.follow_target = _target
		if _target:
			_pcam.position = _target.global_position
	teleport_to_player()

## 计算地图边界（bound_layers 各层 used rect 的并集）并应用到 pcam 的显式 limit 四边。
func _setup_map_limits() -> void:
	var rect := _calc_map_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return

	var vs: Vector2 = get_viewport_rect().size / default_zoom
	var center: Vector2 = rect.get_center()
	var half_vs: Vector2 = vs * 0.5

	# 限制边界 = 地图边界 + 缓冲（bounds_margin 正数=镜头可略超出地图）
	var l: float = rect.position.x - bounds_margin
	var t: float = rect.position.y - bounds_margin
	var r: float = rect.end.x + bounds_margin
	var b: float = rect.end.y + bounds_margin

	# 地图小于视口时，扩展到视口大小并居中（避免 phantom 钳制失效）
	if r - l < vs.x:
		l = center.x - half_vs.x
		r = center.x + half_vs.x
	if b - t < vs.y:
		t = center.y - half_vs.y
		b = center.y + half_vs.y

	_pcam.limit_left = roundi(l)
	_pcam.limit_top = roundi(t)
	_pcam.limit_right = roundi(r)
	_pcam.limit_bottom = roundi(b)


## 计算 bound_layers（默认全部 TileMapLayer）used rect 的并集（像素坐标）。
func _calc_map_rect() -> Rect2:
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF

	var layers: Array[TileMapLayer] = []
	for np: NodePath in bound_layers:
		var node := get_node_or_null(np)
		if node is TileMapLayer:
			layers.append(node as TileMapLayer)

	# 若未配置路径，自动查找根节点下所有 TileMapLayer
	if layers.is_empty():
		var tree := get_tree()
		if tree:
			for child: Node in tree.root.get_children():
				if child is TileMapLayer:
					layers.append(child as TileMapLayer)

	for layer: TileMapLayer in layers:
		var used: Rect2i = layer.get_used_rect()
		if used.size.x <= 0 or used.size.y <= 0:
			continue
		var ts: Vector2i = layer.tile_set.tile_size
		min_x = min(min_x, float(used.position.x) * ts.x)
		min_y = min(min_y, float(used.position.y) * ts.y)
		max_x = max(max_x, float(used.position.x + used.size.x) * ts.x)
		max_y = max(max_y, float(used.position.y + used.size.y) * ts.y)

	if min_x == INF:
		return Rect2()

	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


## 切换角色/死亡切换后，把镜头瞬切到玩家当前位置（绕过阻尼）。
func teleport_to_player() -> void:
	if is_instance_valid(_pcam):
		_pcam.teleport_position()
	elif _target:
		position = _target.global_position
