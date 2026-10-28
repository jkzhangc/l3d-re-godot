extends CanvasLayer

## ── 架构定位 ──
## 系统：世界提示文字 ｜ 层：表现（CanvasLayer）
## 联机：纯本地表现，各端自行换算屏幕坐标，零同步
## 职责：把世界里的提示 Label 搬进独立 canvas ——
##   ① 不再参与 Node2D 的 z 排序 → 不会被角色、上层图块（z_index=1）盖住；
##   ② 不处于夜图 CanvasModulate 所在的 canvas → 不被「暗度」压暗；
##   ③ 每帧把「锚点世界坐标 + 本地偏移」换算成屏幕坐标，跟随镜头/缩放。
## 依赖：无（各交互节点主动 attach）
##
## 【为什么必须是 CanvasLayer】
## 夜图的暗度是 `CanvasModulate`，它**作用于同一个 canvas 的所有 CanvasItem**，
## 没有任何 per-item 的开关能豁免。换 canvas（CanvasLayer）是唯一干净的解法；
## 层级问题顺带一起解决 —— 世界里的 z_index 再高也只在同一个 canvas 内排序。
##
## 【层级】用户 2026-10-28 定稿：`layer = 89`。
## 为什么不取 100：提示文字是**常驻**的，必须被黑幕(90) / ED(95) / 章节总结(100) 盖住；
## 为什么不取 10：要压过调试跳转按钮(85) 与道具使用闪烁(88)，否则文字会被它们糊住。
## 与 DamageNumber（100）各自一个层（伤害数字有自己的 clear_all()，不能共用实例）。
##
## 【用法】节点建好/摆好 Label 之后调一次 `HintTextLayer.attach(label)` 即可：
##   · 锚点 = label 当时的父节点（Node2D），偏移 = label 当时的 position；
##   · 之后若改了想要的偏移，再调一次 attach(label, 新的偏移) 覆盖；
##   · 幂等：重复 attach 只更新偏移，不会重复搬移。
## ⚠ 搬移后 `get_node_or_null("HintLabel")` 就查不到了 —— 调用方必须自己缓存 Label 引用。
## ⚠ 故意不写 `class_name`：新建脚本的类名要等编辑器重扫才进全局类缓存，
##   无编辑器的 headless 运行会 Parse Error。统一走 `preload(...)` 常量引用
##   （与 project 内 holdout_spawn_point 等脚本同一处理）。

## 提示文字层（2026-10-28 用户定稿：89）。
const LAYER: int = 89
const GROUP: StringName = &"hint_text_layer"

static var _instance: Variant = null

## item(CanvasItem：Label / 血条 Control 等) → {"anchor": Node2D, "offset": Vector2}
var _items: Dictionary = {}


## 把一个世界内的提示画布项（Label / 进度条 Control）交给覆盖层托管。
## offset_override 传 Vector2 时用它当「相对锚点原点的偏移」；不传 = 取当前 position。
static func attach(item: CanvasItem, offset_override: Variant = null) -> void:
	if item == null or not is_instance_valid(item):
		return
	## 编辑器里不搬：@tool 脚本会跑 _ready/_process，搬走会污染正在编辑的场景树。
	if Engine.is_editor_hint():
		return
	var overlay: Variant = _ensure_overlay()
	if overlay == null:
		return
	if overlay._items.has(item):
		## 已托管：只刷新偏移（调用方可能刚重排过位置，如键帽按文字宽度改宽度）。
		if offset_override is Vector2:
			overlay._items[item]["offset"] = offset_override as Vector2
		return
	var parent: Node = item.get_parent()
	var anchor := parent as Node2D
	if anchor == null:
		## 拿不到世界锚点（不在 Node2D 下）→ 保持原样，避免把提示搬丢。
		return
	var current := item.get("position") as Vector2
	var offset: Vector2 = (offset_override as Vector2) if offset_override is Vector2 else current
	if parent != null:
		parent.remove_child(item)
	overlay.add_child(item)
	overlay._items[item] = {"anchor": anchor, "offset": offset}
	item.self_modulate = Color(1, 1, 1, 1)


static func _ensure_overlay() -> Variant:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var scene: Node = tree.current_scene
	## 已创建但还在 deferred 入树途中也要直接复用（否则会重复建层）。
	## 但**属于上一张图的旧层必须丢弃**：换图瞬间旧层还 valid（queue_free 要等帧末），
	## 新图的提示若挂进去会随旧场景一起被释放 → 文字永久不显示。
	if _instance != null and is_instance_valid(_instance):
		var parent: Node = (_instance as Node).get_parent()
		if scene == null or parent == null or parent == scene:
			return _instance
		_instance = null
	var existing: Variant = tree.get_first_node_in_group(GROUP)
	if existing != null:
		var existing_parent: Node = (existing as Node).get_parent()
		if scene == null or existing_parent == scene:
			_instance = existing
			return existing
	if scene == null:
		return null
	var layer := CanvasLayer.new()
	layer.set_script(load("res://script/ui/hint_text_layer.gd"))
	layer.name = "HintTextLayer"
	layer.layer = LAYER
	## ★必须在所有世界节点之后执行：部分锚点（HintMarker / blast_wall）每帧/每次显示都会
	## 重写 label.position（写的是**局部偏移**）。若本层先跑，那一写就会把屏幕坐标顶掉，
	## 表现是文字卡在左上角、不跟镜头。process_priority 调高 = 本帧最后写，稳定覆盖。
	layer.process_priority = 1000
	layer.add_to_group(GROUP)
	_instance = layer
	## ★必须 deferred：attach 多半发生在某个节点的 `_ready()` 里，此刻 current_scene 正在
	## `add_child()` 内部（parent busy）→ 直接 add_child 会被拒绝并静默留在树外
	##（与 script/damage_number.gd 的 DamageNumberLayer 同一个坑）。
	scene.call_deferred("add_child", layer)
	return layer


func _process(_delta: float) -> void:
	if _items.is_empty():
		return
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var xform: Transform2D = vp.get_canvas_transform()
	## 倒序遍历，安全删除失效条目。
	var entries: Array = _items.keys()
	for i: int in range(entries.size() - 1, -1, -1):
		var item: Variant = entries[i]
		if not is_instance_valid(item):
			_items.erase(item)
			continue
		var entry: Dictionary = _items[item]
		var anchor: Variant = entry.get("anchor")
		if not is_instance_valid(anchor):
			## 锚点已释放（掉落物被拾取 / 关卡物件被清）→ 提示跟着销毁，避免残留到换图。
			_items.erase(item)
			(item as CanvasItem).queue_free()
			continue
		var node := anchor as Node2D
		var canvas_item := item as CanvasItem
		if not node.is_inside_tree():
			## 节点暂时离树（换图 / 移动节点搬运中）→ 先藏起来，别停在旧坐标上。
			canvas_item.self_modulate.a = 0.0
			continue
		var world: Vector2 = node.global_position + (entry.get("offset") as Vector2)
		## Label / Control 都有 position，但 CanvasItem 基类没有 → 走动态 set。
		canvas_item.set("position", xform * world)
		## 父链被隐藏时画布项不会跟着隐藏（已不在原父级下）→ 用 self_modulate 的 alpha 代偿。
		## 用 self_modulate 而不是 modulate：调用方可能自己设了 modulate（如 boss_encounter 的 0.85）。
		canvas_item.self_modulate.a = 1.0 if node.is_visible_in_tree() else 0.0
