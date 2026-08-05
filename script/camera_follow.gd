extends Camera2D
## 相机跟随 + 地图边界限制。
##
## 以玩家为中心平滑跟随，根据 GroundLayer / DecorLayer 的 tile 范围
## 自动计算边界，防止镜头移出地图。


# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════

@export_group("Follow")
@export var follow_enabled: bool = true
## 平滑跟随速度（越大越快，1=瞬间跟随）
@export var follow_speed: float = 5.0
## 默认缩放（所有地图场景统一 2x）
@export var default_zoom: Vector2 = Vector2(2, 2)

@export_group("Bounds")
@export var limit_to_map: bool = true
## 边界缓冲（像素，正数=镜头可以略超出地图边缘）
@export var bounds_margin: float = 32.0
## 用于计算边界的 TileMapLayer 节点路径
@export var bound_layers: Array[NodePath] = []


# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════

var _target: Node2D = null
var _map_rect: Rect2 = Rect2()  ## 地图像素边界
var _has_bounds: bool = false


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════

func _ready() -> void:
	# 应用默认缩放
	zoom = default_zoom
	# 自动查找玩家
	_target = _find_player()
	print(_target)
	_calc_bounds()


## 在整个场景树中查找 Player 节点。
func _find_player() -> Node2D:
	var tree := get_tree()
	if not tree:
		return null
	for node: Node in tree.root.get_children():
		var found := _find_player_recursive(node)
		if found:
			return found
	return null


func _find_player_recursive(node: Node) -> Node2D:
	if node is CharacterBody2D and node.has_method("get_weapon_data"):
		return node as Node2D
	for child: Node in node.get_children():
		var found := _find_player_recursive(child)
		if found:
			return found
	return null


## 根据 TileMapLayer 计算地图像素边界。
func _calc_bounds() -> void:
	var min_x: float = INF
	var min_y: float = INF
	var max_x: float = -INF
	var max_y: float = -INF

	# 从 bound_layers 路径列表获取图层
	var layers: Array[TileMapLayer] = []
	for np: NodePath in bound_layers:
		var node := get_node_or_null(np)
		if node is TileMapLayer:
			layers.append(node as TileMapLayer)

	# 如果未配置路径，自动查找根节点下的所有 TileMapLayer
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
		var pixel_rect := Rect2(
			Vector2(used.position) * Vector2(ts),
			Vector2(used.size) * Vector2(ts)
		)

		min_x = min(min_x, pixel_rect.position.x)
		min_y = min(min_y, pixel_rect.position.y)
		max_x = max(max_x, pixel_rect.end.x)
		max_y = max(max_y, pixel_rect.end.y)

	if min_x == INF:
		_has_bounds = false
		return

	_has_bounds = true
	_map_rect = Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


# ═══════════════════════════════════════
# 跟随
# ═══════════════════════════════════════

func _process(delta: float) -> void:
	if not follow_enabled or not _target:
		return

	var target_pos: Vector2 = _target.global_position
	var new_pos: Vector2 = position

	if follow_speed > 0.0:
		# 平滑插值
		var t: float = clamp(follow_speed * delta, 0.0, 1.0)
		new_pos = position.lerp(target_pos, t)
	else:
		new_pos = target_pos

	# 边界限制
	if limit_to_map and _has_bounds:
		var vs: Vector2 = get_viewport_rect().size / zoom
		var half_vs: Vector2 = vs * 0.5

		# 允许镜头边界 = 地图边界 + 缓冲
		var cam_min: Vector2 = _map_rect.position - Vector2(bounds_margin, bounds_margin) + half_vs
		var cam_max: Vector2 = _map_rect.end + Vector2(bounds_margin, bounds_margin) - half_vs

		# 如果地图小于视口，居中
		if cam_min.x > cam_max.x:
			new_pos.x = _map_rect.position.x + _map_rect.size.x * 0.5
		else:
			new_pos.x = clamp(new_pos.x, cam_min.x, cam_max.x)

		if cam_min.y > cam_max.y:
			new_pos.y = _map_rect.position.y + _map_rect.size.y * 0.5
		else:
			new_pos.y = clamp(new_pos.y, cam_min.y, cam_max.y)

	position = new_pos
