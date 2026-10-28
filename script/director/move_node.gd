@tool
class_name MoveNode extends Node2D

## ── 架构定位 ──
## 系统：关卡表现 / 剧情机关 ｜ 层：玩法（Node2D，关卡作者标记）
## 联机：**各端本地表现**（触发信号两端同源，见下）—— 无 RPC、无同步
## 职责：一个「收到信号后自己挪到指定坐标」的物件。外观支持两种：
##       ① 整张贴图原样显示（**不裁剪**，适合单张门 / 石头 / 车辆图）；
##       ② VX 行走图取帧（角色格 + 朝向 + 踏步 + 朝向动画，与传送点同款）。
##       可选实体碰撞（默认开，层 33，与医疗箱同款）。
## 依赖：Tween、Global（无）、HoldoutMachine（仅防守战捷径用）

## 【触发】两种写法，互不冲突：
##   · 通用信号：`trigger_source_path` 填节点路径、`trigger_signal` 填信号名；
##   · 防守战捷径：路径留空 + `auto_find_holdout=true` → 自动接**场景里最近的**
##     HoldoutMachine 的 `holdout_finished`（该信号 Host / Client 两端各发一次，
##     因此多人下各端都会各自播放同一段位移，无需 RPC）。
##   另有 `trigger()` 供代码 / 其他节点手动调用。

## 【移动】终点两种填法：
##   · RELATIVE（默认）：`target_offset` 相对**摆放位置**；
##   · ABSOLUTE：`target_position` 直接填全局坐标（父节点有变换时自动换算成局部）。
##   缓动走 Tween：`transition` / `ease_type` / `duration`，可选 `start_delay`。

## ⚠ 移动中的碰撞体是 StaticBody2D：它**不会主动推开**玩家。别让移动路径扫过玩家站位
##   （否则玩家会被留在墙里）——这类"推人"需求请另开 AnimatableBody2D 方案。

const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
## 行走图文件名特殊前缀（`$` = 单角色表）解析，见 script/vx_walk_sheet.gd
const WALK := preload("res://script/vx_walk_sheet.gd")

const COLLISION_NODE: String = "Collision"
const COLLISION_SHAPE_NODE: String = "Shape"
const COLLISION_LAYER: int = 33

enum TargetMode { RELATIVE = 0, ABSOLUTE = 1 }

signal move_started
signal move_finished

# ═══════════════════════════════════════
# 配置 — 外观
# ═══════════════════════════════════════
@export_group("外观")
## 勾上 = 按 VX 行走图取帧（角色格 / 朝向 / 踏步）；不勾 = 整张贴图原样显示，**不做任何裁剪**。
@export var use_walk_sprite: bool = false:
	set(v):
		use_walk_sprite = v
		_refresh_sprite()
## 贴图。行走图模式 = VX 精灵表；非行走图模式 = 单张图片（整张显示）。
@export var texture: Texture2D:
	set(v):
		texture = v
		_refresh_sprite()
@export var sprite_offset: Vector2 = Vector2.ZERO:
	set(v):
		sprite_offset = v
		_refresh_sprite()
@export var sprite_modulate: Color = Color.WHITE:
	set(v):
		sprite_modulate = v
		_refresh_sprite()
@export_range(0, 7, 1) var walk_char_index: int = 0:
	set(v):
		walk_char_index = v
		_refresh_sprite()
@export_range(0, 3, 1) var walk_direction: int = 0:
	set(v):
		walk_direction = v
		_refresh_sprite()

@export_group("踏步动画（行走图模式）")
@export var step_frames: Array[int] = [1, 0, 1, 2]
@export_range(0.02, 5.0, 0.01) var step_duration: float = 0.25
@export var animated: bool = true

@export_group("朝向动画（行走图模式）")
## 与踏步动画**各自独立计时**；默认关 = 固定用 walk_direction。
@export var facing_frames: Array[int] = [0]
@export_range(0.02, 5.0, 0.01) var facing_duration: float = 0.25
@export var facing_animated: bool = false

# ═══════════════════════════════════════
# 配置 — 移动
# ═══════════════════════════════════════
@export_group("移动")
@export var target_mode: TargetMode = TargetMode.RELATIVE:
	set(v):
		target_mode = v
		queue_redraw()
## RELATIVE 模式：相对**摆放位置**的终点偏移。
@export var target_offset: Vector2 = Vector2(0, -64):
	set(v):
		target_offset = v
		queue_redraw()
## ABSOLUTE 模式：终点全局坐标。
@export var target_position: Vector2 = Vector2.ZERO:
	set(v):
		target_position = v
		queue_redraw()
@export_range(0.05, 30.0, 0.05) var duration: float = 1.0
## 缓动曲线（Tween.TransitionType：SINE/QUAD/CUBIC/EXPO/BACK/BOUNCE…）
@export var transition: Tween.TransitionType = Tween.TRANS_SINE
## 缓动方向（Tween.EaseType：IN / OUT / IN_OUT / OUT_IN）
@export var ease_type: Tween.EaseType = Tween.EASE_IN_OUT
## 收到信号后延迟多久才开始移动（秒）。
@export_range(0.0, 10.0, 0.05) var start_delay: float = 0.0

# ═══════════════════════════════════════
# 配置 — 触发
# ═══════════════════════════════════════
@export_group("触发")
## 信号源节点路径（相对本节点 → 相对场景根）。留空 + `auto_find_holdout` = 防守战捷径。
@export var trigger_source_path: NodePath
## 要监听的信号名（默认 = HoldoutMachine.holdout_finished）。
@export var trigger_signal: String = "holdout_finished"
## 路径留空时，自动接**场景里最近的** HoldoutMachine。
@export var auto_find_holdout: bool = true
## 剧情 flag 触发（留空 = 不启用）。非空时监听 `Global.quest_flag_changed`：
## 该 flag 被置为 true 就移动 —— 与矿洞爆破墙（`blast_wall.wall_flag` → 置 flag → 全端同步）
## 同一套语义，适合"炸开墙后石头滚开 / 钥匙拿到后铁门升起"。
@export var trigger_quest_flag: String = ""
## 只响应一次（默认开）。
@export var one_shot: bool = true

# ═══════════════════════════════════════
# 配置 — 碰撞
# ═══════════════════════════════════════
@export_group("碰撞")
@export var collision_enabled: bool = true:
	set(v):
		collision_enabled = v
		if is_node_ready():
			_ensure_collision()
@export var collision_size: Vector2 = Vector2(32, 32):
	set(v):
		collision_size = v
		if is_node_ready():
			_ensure_collision()
@export var collision_offset: Vector2 = Vector2.ZERO:
	set(v):
		collision_offset = v
		if is_node_ready():
			_ensure_collision()

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _step_index: int = 0
var _step_timer: float = 0.0
var _facing_index: int = 0
var _facing_timer: float = 0.0
var _tween: Tween = null
var _moving: bool = false
var _done: bool = false


func _ready() -> void:
	_ensure_children()
	_ensure_collision()
	_refresh_sprite()
	_step_timer = step_duration
	_facing_timer = facing_duration
	if Engine.is_editor_hint():
		return
	## 延迟一帧再接线：`holdout_machine` 组是在机器的 `_ready` 里加入的，
	## 节点顺序不保证本节点先跑还是机器先跑。
	call_deferred("_connect_trigger")
	## 剧情 flag 触发（矿洞爆破墙同款语义）：立即接，Global 是 autoload 必在。
	if not trigger_quest_flag.is_empty():
		var g: Node = get_node_or_null("/root/Global")
		if g != null and g.has_signal("quest_flag_changed"):
			var flag_cb: Callable = Callable(self, "_on_quest_flag_changed")
			if not g.is_connected("quest_flag_changed", flag_cb):
				g.connect("quest_flag_changed", flag_cb)


func _exit_tree() -> void:
	if Engine.is_editor_hint() or trigger_quest_flag.is_empty():
		return
	var g: Node = get_node_or_null("/root/Global")
	if g == null:
		return
	var flag_cb: Callable = Callable(self, "_on_quest_flag_changed")
	if g.is_connected("quest_flag_changed", flag_cb):
		g.disconnect("quest_flag_changed", flag_cb)


## flag 触发：只认自己配的那个 flag，且只在被**置为 true** 时移动。
func _on_quest_flag_changed(flag_name: String, value: bool) -> void:
	if not value or flag_name != trigger_quest_flag:
		return
	trigger()


func _process(delta: float) -> void:
	if use_walk_sprite and animated and step_frames.size() > 1:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(step_duration, 0.02)
			_step_index = (_step_index + 1) % step_frames.size()
			_refresh_sprite()
	if use_walk_sprite and facing_animated and facing_frames.size() > 1:
		_facing_timer -= delta
		if _facing_timer <= 0.0:
			_facing_timer += maxf(facing_duration, 0.02)
			_facing_index = (_facing_index + 1) % facing_frames.size()
			_refresh_sprite()


# ═══════════════════════════════════════
# 触发接线
# ═══════════════════════════════════════

func _connect_trigger() -> void:
	var src: Node = _resolve_trigger_source()
	if src == null:
		print("[MoveNode] %s 找不到触发源（trigger_source_path=%s / auto_find_holdout=%s）"
			% [name, str(trigger_source_path), str(auto_find_holdout)])
		return
	var sig_name: String = trigger_signal.strip_edges()
	if sig_name.is_empty() or not src.has_signal(sig_name):
		print("[MoveNode] %s 的信号源 %s 没有信号「%s」" % [name, src.name, sig_name])
		return
	var cb: Callable = Callable(self, "_on_trigger_signal")
	if not src.is_connected(sig_name, cb):
		src.connect(sig_name, cb)
	print("[MoveNode] %s 已接 %s.%s" % [name, src.name, sig_name])


## 信号回调：参数全部可选 —— 既能接无参信号，也能接 `holdout_finished(event_name)` 这类带参信号。
func _on_trigger_signal(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
	trigger()


## 信号源：路径优先；留空则按 `auto_find_holdout` 取场景里最近的防守机器。
func _resolve_trigger_source() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	if not trigger_source_path.is_empty():
		var direct: Node = get_node_or_null(trigger_source_path)
		if direct != null:
			return direct
		if tree.current_scene != null:
			return tree.current_scene.get_node_or_null(trigger_source_path)
		return null
	if not auto_find_holdout:
		return null
	var best: Node = null
	var best_dist: float = INF
	for node: Node in tree.get_nodes_in_group("holdout_machine"):
		if not (node is Node2D) or not is_instance_valid(node):
			continue
		var dist: float = global_position.distance_squared_to((node as Node2D).global_position)
		if dist < best_dist:
			best_dist = dist
			best = node
	return best


# ═══════════════════════════════════════
# 移动
# ═══════════════════════════════════════

## 手动 / 信号触发的统一入口（幂等：one_shot 时只生效一次）。
func trigger() -> void:
	if _moving:
		return
	if one_shot and _done:
		return
	_done = true
	_start_move()


## 终点（局部坐标）：绝对模式按父节点变换换算。
func target_local_position() -> Vector2:
	if target_mode == TargetMode.ABSOLUTE:
		var parent_2d: Node2D = get_parent() as Node2D
		if parent_2d != null:
			return parent_2d.to_local(target_position)
		return target_position
	return position + target_offset


func _start_move() -> void:
	_moving = true
	move_started.emit()
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_trans(transition)
	_tween.set_ease(ease_type)
	if start_delay > 0.0:
		_tween.tween_interval(start_delay)
	_tween.tween_property(self, "position", target_local_position(), maxf(duration, 0.01))
	var cb: Callable = _on_move_done
	_tween.finished.connect(cb)


func _on_move_done() -> void:
	_moving = false
	move_finished.emit()


func is_moving() -> bool:
	return _moving


# ═══════════════════════════════════════
# 子节点 / 渲染
# ═══════════════════════════════════════

func _ensure_children() -> void:
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if s == null:
		s = Sprite2D.new()
		s.name = "Sprite2D"
		s.centered = true
		add_child(s)


## 实体碰撞（层 33，与医疗箱 / 存档点同款）。幂等：预置节点只改参数不重建。
func _ensure_collision() -> void:
	var body: StaticBody2D = get_node_or_null(COLLISION_NODE) as StaticBody2D
	if body == null:
		body = StaticBody2D.new()
		body.name = COLLISION_NODE
		add_child(body)
	var active: bool = collision_enabled and is_visible_in_tree()
	body.collision_layer = COLLISION_LAYER if active else 0
	body.collision_mask = 0

	var shape_node: CollisionShape2D = body.get_node_or_null(COLLISION_SHAPE_NODE) as CollisionShape2D
	if shape_node == null:
		shape_node = CollisionShape2D.new()
		shape_node.name = COLLISION_SHAPE_NODE
		body.add_child(shape_node)
	var rect: RectangleShape2D = shape_node.shape as RectangleShape2D
	if rect == null:
		rect = RectangleShape2D.new()
		shape_node.shape = rect
	rect.size = Vector2(maxf(collision_size.x, 1.0), maxf(collision_size.y, 1.0))
	shape_node.position = collision_offset


func _refresh_sprite() -> void:
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if s == null:
		return
	s.texture = texture
	s.position = sprite_offset
	s.modulate = sprite_modulate
	s.visible = texture != null
	if texture == null:
		s.region_enabled = false
		return
	if not use_walk_sprite:
		## 单图模式：整张显示，不做任何裁剪（用户 2026-10-27 明确要求）。
		s.region_enabled = false
		return
	s.region_enabled = true
	var frame: int = clampi(step_frames[_step_index], 0, 2) if _step_index < step_frames.size() else 0
	## 文件名带 `$` 前缀时按单角色表取帧（帧尺寸 = 图/3×4），见 vx_walk_sheet.gd
	s.region_rect = WALK.region_rect(texture, walk_char_index, _current_facing(), frame)


## 当前应显示的朝向：朝向动画开着取序列里的值，否则用 walk_direction。
func _current_facing() -> int:
	if not facing_animated or facing_frames.is_empty():
		return clampi(walk_direction, 0, 3)
	return clampi(facing_frames[_facing_index % facing_frames.size()], 0, 3)


## 编辑器预览：画出终点与位移方向（运行时 `_draw` 为空）。
func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var target: Vector2
	if target_mode == TargetMode.ABSOLUTE:
		target = to_local(target_position)
	else:
		target = target_offset
	var col: Color = Color(0.35, 0.85, 1.0, 0.85)
	draw_line(Vector2.ZERO, target, col, 1.0)
	draw_arc(target, 8.0, 0.0, TAU, 16, col, 1.0)
	draw_line(target + Vector2(-6, 0), target + Vector2(6, 0), col, 1.0)
	draw_line(target + Vector2(0, -6), target + Vector2(0, 6), col, 1.0)
