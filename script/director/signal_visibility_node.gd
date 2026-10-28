@tool
class_name SignalVisibilityNode
extends Node2D

## ── 架构定位 ──
## 系统：关卡机关表现（灯 / 招牌 / 装饰物显隐）｜ 层：玩法（Node2D 包装层）
## 联机：**各端本地表现** —— 信号由各端自己发（开关互动是本机玩家），无 RPC、无同步
## 职责：一个「收到某个信号就显示、收到另一个信号就隐藏」的包装节点。
##       把灯 / 光效 / 贴图 / 甚至带碰撞的物件挂成它的子节点即可，
##       显隐跟随本节点（`visible` 会连子节点一起生效）。
## 依赖：信号源（默认取场景里最近的 InteractiveSwitchNode）、Global（无）

## 【为什么做成包装层】
##   灯光往往是「贴图 + PointLight2D + 可能还有碰撞」一组节点。挂在这个包装层上，
##   一条 `visible` 就整体开关；不用给每个子节点各挂一份脚本。
##
## 【信号名从哪来】
##   `InteractiveSwitchNode` 的两个命名信号（默认 `switch_on` / `switch_off`）。
##   信号是运行时注册的，所以本节点**延迟一帧**再连（见 `_connect_signals`）。
##
## 【初始状态】
##   默认 `start_hidden = true`（灯一开始是灭的）。勾掉则一开始就亮。
##   `fade_seconds > 0` 时显隐走 modulate 透明度过渡（碰撞立即生效，不等淡出）。

@export_group("信号源")
## 发信号的节点。留空 = 自动取**场景里最近的** InteractiveSwitchNode。
@export var source_path: NodePath
## 要监听的两个信号名（与开关上的 `signal_on_name` / `signal_off_name` 对应）。
@export var show_signal: String = "switch_on"
@export var hide_signal: String = "switch_off"

@export_group("表现")
## 一开始是否隐藏（默认隐藏 = 灯是灭的）。
@export var start_hidden: bool = true
## 淡入淡出时长（秒）；0 = 立即切换。
@export_range(0.0, 5.0, 0.05) var fade_seconds: float = 0.0
## 隐藏时同步关掉子节点的碰撞（灯一般没有，带碰撞的闸门类物件用得上）。
@export var disable_collision_on_hide: bool = true

var _shown: bool = false
var _tween: Tween = null


func _ready() -> void:
	_shown = not start_hidden
	_apply_instant(_shown)
	_apply_collision(_shown)
	if Engine.is_editor_hint():
		return
	## 开关的命名信号是运行时 add_user_signal 注册的 → 必须等它的 _ready 跑完再连。
	call_deferred("_connect_signals")


## 延迟接线：解析信号源 → 连 show / hide 两个命名信号。
func _connect_signals() -> void:
	var src: Node = _resolve_source()
	if src == null:
		print("[SignalVisibility] %s 找不到信号源（source_path=%s）" % [name, str(source_path)])
		return
	var connected: int = 0
	connected += _connect_one(src, show_signal, "_on_show_signal")
	connected += _connect_one(src, hide_signal, "_on_hide_signal")
	if connected > 0:
		print("[SignalVisibility] %s 已接 %s（show=%s / hide=%s）" % [
			name, src.name, show_signal, hide_signal])


func _connect_one(src: Node, raw_name: String, method: String) -> int:
	var sig_name: String = raw_name.strip_edges()
	if sig_name.is_empty():
		return 0
	if not src.has_signal(sig_name):
		print("[SignalVisibility] %s 的信号源 %s 没有信号「%s」" % [name, src.name, sig_name])
		return 0
	var cb: Callable = Callable(self, method)
	if not src.is_connected(sig_name, cb):
		src.connect(sig_name, cb)
	return 1


## 信号源：路径优先（相对本节点 → 相对场景根）；留空取场景里**最近**的开关。
func _resolve_source() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	if not source_path.is_empty():
		var direct: Node = get_node_or_null(source_path)
		if direct != null:
			return direct
		if tree.current_scene != null:
			return tree.current_scene.get_node_or_null(source_path)
		return null
	var best: Node = null
	var best_dist: float = INF
	for node: Node in tree.get_nodes_in_group("interactive_switch"):
		if not (node is Node2D) or not is_instance_valid(node):
			continue
		var dist: float = global_position.distance_squared_to((node as Node2D).global_position)
		if dist < best_dist:
			best_dist = dist
			best = node
	return best


# ═══════════════════════════════════════
# 显隐
# ═══════════════════════════════════════

func is_shown() -> bool:
	return _shown


## 外部（代码 / 其他信号）也能直接控制。
func set_shown(shown: bool, animate: bool = true) -> void:
	if _shown == shown and visible == shown:
		return
	## ★淡入必须从「完全隐藏」的 alpha 重新起算（2026-10-28 用户实测「淡入是直接显示」）：
	## 初始 `_apply_instant(false)` 与 `_finish_fade_out()` 都会把 alpha 复位成 1.0，
	## 旧实现又直接 tween 到 1.0 → 实际是 1.0→1.0，一帧就到位。
	## 只有「切换前已经不可见」才归零；淡出中途反悔（visible 仍为 true）则从当前 alpha 继续淡入，
	## 否则会先闪黑一下再变亮。
	var was_hidden: bool = not visible
	_shown = shown
	_apply_collision(shown)
	if not animate or fade_seconds <= 0.0 or Engine.is_editor_hint():
		_apply_instant(shown)
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	if shown:
		visible = true
		if was_hidden:
			modulate.a = 0.0
		_tween.tween_property(self, "modulate:a", 1.0, fade_seconds)
	else:
		_tween.tween_property(self, "modulate:a", 0.0, fade_seconds)
		var cb: Callable = _finish_fade_out
		_tween.finished.connect(cb)


func _on_show_signal() -> void:
	set_shown(true)


func _on_hide_signal() -> void:
	set_shown(false)


func _apply_instant(shown: bool) -> void:
	visible = shown
	modulate.a = 1.0


func _finish_fade_out() -> void:
	if _shown:
		return
	visible = false
	modulate.a = 1.0   ## 复位，下次显示从头淡入


## 隐藏时关掉整棵子树的碰撞（只动 disabled，不改层 / process_mode）。
func _apply_collision(shown: bool) -> void:
	if not disable_collision_on_hide:
		return
	_set_collision_recursive(self, shown)


func _set_collision_recursive(node: Node, enabled: bool) -> void:
	if node is CollisionShape2D:
		(node as CollisionShape2D).set_deferred("disabled", not enabled)
	elif node is CollisionPolygon2D:
		(node as CollisionPolygon2D).set_deferred("disabled", not enabled)
	for child: Node in node.get_children():
		_set_collision_recursive(child, enabled)
