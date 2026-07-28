class_name VXAnimSprite extends Node2D
## VX Ace 动画精灵 — 播放 RPG Maker VX Ace 格式的动画精灵表
##
## 精灵表格式：通常 960px 宽 = 5 列 × 192px，每格 192×192
## 通过文件名即可引用 art/Animations/ 下的素材
##
## 偏移系统（三层叠加）：
##   1. VXAnimCellData.offset — 多精灵模式下单个精灵相对帧中心的偏移
##   2. frame_offsets[N] — 第 N 帧的整体偏移（单/多精灵均生效）
##   3. position_offset — 整个动画节点的全局偏移（叠加到节点 position 上）
##
## 使用示例：
##   # 简单调用
##   VXAnimSprite.play_at("血", global_position, get_tree().current_scene)
##   # 自定义帧序 + 每帧时长 + 偏移
##   var a = VXAnimSprite.from_name("爆発")
##   a.frame_sequence = [0, 2, 4, 3, 1]
##   a.frame_durations = [0.1, 0.1, 0.3, 0.1, 0.1]
##   a.frame_offsets = [Vector2(0,0), Vector2(5,0), Vector2(10,-5), Vector2(5,0), Vector2(0,0)]
##   a.position_offset = Vector2(0, -20)
##   add_child(a)


# ═══════════════════════════════════════
# 导出参数
# ═══════════════════════════════════════
@export var texture: Texture2D            ## VX Ace 动画精灵表
@export var h_frames: int = 5             ## 列数（VX Ace 标准 = 5）
@export var v_frames: int = 0             ## 行数（0 = 根据纹理高度自动计算）
@export var fps: float = 10.0             ## 播放速度（帧/秒），frame_durations 为空时使用
@export var looping: bool = false         ## 是否循环播放
@export var auto_free: bool = true        ## 播放完毕自动 queue_free
@export var centered: bool = true         ## 是否居中（false = 左上角锚点）
@export var animation_scale: Vector2 = Vector2(1, 1)  ## 整体缩放
@export var animation_rotation: float = 0.0  ## 整体旋转角度（度）
## 整体位置偏移（叠加到动画节点自身位置之上），用于微调特效相对生成点的位置
@export var position_offset: Vector2 = Vector2.ZERO
## 每帧位置偏移数组，索引对应帧序列中的帧号
## frame_offsets[N] 为第 N 帧的额外 XY 偏移，空或越界 = (0,0)
@export var frame_offsets: Array[Vector2] = []

## 自定义帧序列：指定播放哪些格子索引（按此顺序）
## 空 = 按顺序 0,1,2,... 播放全部格子
@export var frame_sequence: Array[int] = []
## 每帧持续时间（秒），长度应与 frame_sequence 一致
## 空 = 统一使用 fps（1/fps 秒/帧）
@export var frame_durations: Array[float] = []

## 多精灵配置：同一帧可显示多个格子
## 空 = 单精灵模式（每帧显示 frame_sequence 中的一个格子）
@export var cell_data: Array[VXAnimCellData] = []

## 跟随目标节点。启用后动画每帧跟随目标实体移动
@export var follow_target: Node2D = null
## 是否启用跟随（Inspector 可开关，也可通过 play_at 的 follow 参数设置）
@export var follow_enabled: bool = false

# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var _timer: Timer
var _sprites: Array[Sprite2D] = []   ## 当前帧的精灵池
var _seq_idx: int = 0                ## 当前在帧序列中的位置
var _total_frames: int = 0           ## 总帧数
var _cell_size: Vector2 = Vector2(192, 192)
var _playing: bool = false
var _is_multi: bool = false          ## 是否多精灵模式


func _ready() -> void:
	if not texture:
		push_warning("VXAnimSprite: 未设置 texture，跳过初始化")
		return

	# 确保 _sprites 是此实例独有的数组（避免 Godot 4 类级数组共享问题）
	_sprites = []

	# 计算网格
	var tex_w: int = texture.get_width()
	var tex_h: int = texture.get_height()
	var actual_v: int = _calc_v_frames(tex_h)
	_cell_size = Vector2(float(tex_w) / h_frames, float(tex_h) / maxf(1, float(actual_v)))

	# 确定总帧数
	if frame_sequence.size() > 0:
		_total_frames = frame_sequence.size()
	else:
		_total_frames = h_frames * actual_v

	# 判断模式
	_is_multi = cell_data.size() > 0

	# 应用整体位置偏移
	self.position += position_offset

	# 显示第一帧
	_update_frame()

	# 创建计时器
	_timer = Timer.new()
	_timer.wait_time = _get_current_duration()
	_timer.timeout.connect(_on_timer_timeout)
	add_child(_timer)
	_timer.start()
	_playing = true


func _calc_v_frames(tex_h: int) -> int:
	if v_frames > 0:
		return v_frames
	return maxi(1, int(ceil(float(tex_h) / _cell_size.y)))


func _get_cell_index() -> int:
	## 单精灵模式：获取当前帧的格子索引
	if frame_sequence.size() > 0:
		return frame_sequence[_seq_idx]
	return _seq_idx


## 获取当前逻辑帧号（考虑 frame_sequence）
## 多精灵模式下用于匹配 cell_data.frame_idx
func _get_actual_frame() -> int:
	if frame_sequence.size() > 0:
		return frame_sequence[_seq_idx]
	return _seq_idx


func _get_current_duration() -> float:
	if frame_durations.size() > _seq_idx:
		return frame_durations[_seq_idx]
	return 1.0 / maxf(0.1, fps)


## 获取当前帧的位置偏移（frame_offsets[_seq_idx]，越界返回零向量）
func _get_current_frame_offset() -> Vector2:
	if _seq_idx >= 0 and _seq_idx < frame_offsets.size():
		return frame_offsets[_seq_idx]
	return Vector2.ZERO


func _process(_delta: float) -> void:
	## 每帧跟随目标实体
	if follow_enabled and is_instance_valid(follow_target):
		global_position = follow_target.global_position + position_offset


func _on_timer_timeout() -> void:
	_seq_idx += 1
	if _seq_idx >= _total_frames:
		if looping:
			_seq_idx = 0
		else:
			_timer.stop()
			_playing = false
			if auto_free:
				queue_free()
			return
	_timer.wait_time = _get_current_duration()
	_update_frame()


# ═══════════════════════════════════════
# 帧渲染
# ═══════════════════════════════════════

func _update_frame() -> void:
	if _is_multi:
		_update_multi()
	else:
		_update_single()


func _update_single() -> void:
	## 单精灵模式：只显示一个格子，位置 = 帧偏移
	var cell_idx: int = _get_cell_index()
	if _sprites.size() == 0:
		var s := _create_sprite()
		_sprites.append(s)
	var s: Sprite2D = _sprites[0]
	var frame_offset: Vector2 = _get_current_frame_offset()
	_apply_cell_to_sprite(s, cell_idx, frame_offset, animation_scale, animation_rotation, 1.0, 0, false)


func _update_multi() -> void:
	## 多精灵模式：找出当前帧的所有 cell，每个一个 Sprite2D
	## 每个精灵位置 = cell.offset + 帧偏移
	var actual_frame: int = _get_actual_frame()
	var frame_cells: Array[VXAnimCellData] = []
	for cd: VXAnimCellData in cell_data:
		if cd.frame_idx == actual_frame:
			frame_cells.append(cd)

	# 确保精灵池足够
	while _sprites.size() < frame_cells.size():
		_sprites.append(_create_sprite())

	# 多余的精灵隐藏
	for i: int in range(frame_cells.size(), _sprites.size()):
		_sprites[i].visible = false

	# 应用每个 cell：偏移 = cell 自身偏移 + 帧偏移
	var frame_offset: Vector2 = _get_current_frame_offset()
	for i: int in frame_cells.size():
		var cd: VXAnimCellData = frame_cells[i]
		_apply_cell_to_sprite(_sprites[i], cd.pattern, cd.offset + frame_offset,
			animation_scale * cd.scale, animation_rotation + cd.rotation_deg,
			cd.opacity, cd.blend_mode, cd.flip_h)


func _create_sprite() -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = texture
	s.centered = centered
	s.region_enabled = true
	add_child(s)
	return s


func _apply_cell_to_sprite(s: Sprite2D, pattern: int, offset: Vector2, sc: Vector2, rot: float, op: float, blend: int, flip: bool) -> void:
	s.visible = true
	var col: int = pattern % h_frames
	var row: int = pattern / h_frames
	s.region_rect = Rect2(col * _cell_size.x, row * _cell_size.y, _cell_size.x, _cell_size.y)
	s.position = offset
	s.scale = sc
	s.rotation_degrees = rot
	s.modulate = Color(1, 1, 1, op)
	s.flip_h = flip

	match blend:
		1:  # Additive
			s.material = _get_additive_material()
		2:  # Subtractive
			s.material = _get_subtractive_material()
		_:  # Normal
			s.material = null


var _add_mat: CanvasItemMaterial = null
var _sub_mat: CanvasItemMaterial = null


func _get_additive_material() -> CanvasItemMaterial:
	if not _add_mat:
		_add_mat = CanvasItemMaterial.new()
		_add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return _add_mat


func _get_subtractive_material() -> CanvasItemMaterial:
	if not _sub_mat:
		_sub_mat = CanvasItemMaterial.new()
		_sub_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
	return _sub_mat


# ═══════════════════════════════════════
# Static 工厂方法
# ═══════════════════════════════════════

## 从动画名称创建实例。
##   .tscn → 加载预配置动画场景（anim/ 目录或完整路径）
##   其他  → 加载 art/Animations/<name>.png 精灵表
static func from_name(anim_name: String, fps: float = 10.0) -> VXAnimSprite:
	if anim_name.is_empty():
		return null

	# .tscn 路径 → 加载预配置动画场景
	if anim_name.ends_with(".tscn"):
		var tscn_path: String = anim_name
		if not tscn_path.begins_with("res://") and not tscn_path.begins_with("user://"):
			tscn_path = "res://anim/" + tscn_path
		if not ResourceLoader.exists(tscn_path):
			push_warning("VXAnimSprite: 找不到动画场景: " + tscn_path)
			return null
		var packed: PackedScene = load(tscn_path) as PackedScene
		if not packed:
			push_warning("VXAnimSprite: 无法加载场景: " + tscn_path)
			return null
		var node: Node = packed.instantiate()
		if not (node is VXAnimSprite):
			push_warning("VXAnimSprite: 场景根节点不是 VXAnimSprite: " + tscn_path)
			node.queue_free()
			return null
		return node as VXAnimSprite

	# 原始精灵表路径
	var path: String = "res://art/Animations/" + anim_name
	if not path.ends_with(".png"):
		path += ".png"

	if not ResourceLoader.exists(path):
		push_warning("VXAnimSprite: 找不到动画素材: " + path)
		return null

	var tex: Texture2D = load(path) as Texture2D
	if not tex:
		return null

	var anim := VXAnimSprite.new()
	anim.texture = tex
	anim.fps = fps
	return anim


## 在指定位置播放动画，自动添加到场景树，播完自动释放。
## 若传入 follow 节点且非空，则启用跟随模式（动画每帧跟随该实体移动）。
static func play_at(anim_name: String, pos: Vector2, parent: Node, fps: float = 10.0, follow: Node2D = null) -> VXAnimSprite:
	var anim := from_name(anim_name, fps)
	if not anim:
		return null
	anim.global_position = pos
	if follow:
		anim.follow_target = follow
		anim.follow_enabled = true
	parent.add_child(anim)
	return anim


## 从 PackedScene 创建 VXAnimSprite 实例。
## offset_override 非零时叠加到 .tscn 内置的 position_offset 上（在 _ready() 前设置）。
static func from_scene(packed: PackedScene, offset_override: Vector2 = Vector2.ZERO) -> VXAnimSprite:
	if not packed:
		push_warning("VXAnimSprite.from_scene: PackedScene is null")
		return null
	var node: Node = packed.instantiate()
	if not (node is VXAnimSprite):
		push_warning("VXAnimSprite.from_scene: 场景根节点不是 VXAnimSprite")
		node.queue_free()
		return null
	var anim: VXAnimSprite = node as VXAnimSprite
	if offset_override != Vector2.ZERO:
		anim.position_offset += offset_override
	return anim


## 从 PackedScene 实例化动画并在指定位置播放。
## offset_override 非零时叠加到 .tscn 内置的 position_offset 上。
static func play_scene(packed: PackedScene, pos: Vector2, parent: Node, fps: float = 10.0, follow: Node2D = null, offset_override: Vector2 = Vector2.ZERO) -> VXAnimSprite:
	var anim := from_scene(packed, offset_override)
	if not anim:
		return null
	anim.global_position = pos
	if follow:
		anim.follow_target = follow
		anim.follow_enabled = true
	parent.add_child(anim)
	return anim
