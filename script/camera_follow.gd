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
	# 自动查找玩家（联机模式下玩家可能尚未生成，延迟到 _process 中重试）
	_target = _find_player()
	if _target:
		print("[Camera] 玩家已找到: %s" % _target.name)
	else:
		print("[Camera] 玩家未找到，将在 _process 中重试...")
	_calc_bounds()


## 在场景中查找 Player 节点。
## 联机模式下优先返回 authority 为自己的玩家。
func _find_player() -> Node2D:
	var tree := get_tree()
	if not tree:
		return null

	var my_id: int = multiplayer.get_unique_id()
	var fallback: Node2D = null

	# 使用 group "player" 查找（Player._ready() 中 add_to_group）
	var players: Array[Node] = tree.get_nodes_in_group("player")
	print("[Camera] 找到 %d 个玩家 (my_id=%d)" % [players.size(), my_id])

	for p: Node in players:
		if not (p is CharacterBody2D) or not p.has_method("get_weapon_data"):
			continue
		var auth: int = p.get_multiplayer_authority()
		print("[Camera]   - %s authority=%d" % [p.name, auth])
		if auth == my_id:
			print("[Camera] 选中自己的玩家: %s" % p.name)
			return p as Node2D
		if not fallback:
			fallback = p as Node2D

	if fallback:
		print("[Camera] 回退：%s" % fallback.name)
	return fallback


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

var _found_own_player: bool = false   ## 是否已找到自己的玩家（联机模式）

func _process(delta: float) -> void:
	# 联机模式下玩家延迟生成，持续重试直到找到自己的玩家
	if not _found_own_player:
		var candidate: Node2D = _find_player()
		if candidate:
			var my_id: int = multiplayer.get_unique_id()
			if candidate.get_multiplayer_authority() == my_id:
				_found_own_player = true
			_target = candidate
			print("[Camera] 延迟找到玩家: %s (authority=%d, my_id=%d)" % [candidate.name, candidate.get_multiplayer_authority(), my_id])

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
