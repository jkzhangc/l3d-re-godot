extends CanvasLayer

## ── 架构定位 ──
## 系统：画面色调（全屏后处理）｜ 层：表现（CanvasLayer + screen shader）
## 联机：纯本地表现，**零 RPC**（各端屏幕/设置不同，同步没有意义）
## 职责：给「整个世界画面」套一层色调 —— 夜晚、黄昏、雨天、受伤、BOSS 氛围等。
## 依赖：`shader/screen_tone.gdshader`
##
## 【为什么天然不含 UI】
##   shader 用 `hint_screen_texture` 采样**已经画完**的屏幕内容，而绘制顺序按
##   `CanvasLayer.layer` 从小到大。把本节点放在 世界(0) 之上、UI(90+) 之下
##   （默认 `tone_layer = 50`），采样时 UI 还没画 → UI 完全不受影响，**无需任何额外设置**。
##   个别 layer 低于色调层但也不想被染色的层，用 `excluded_nodes` 抬走。
##
## 【用法】
##   1. 把 `scene/fx/screen_tone.tscn` 放进地图场景（放到需要调色的地方即可）；
##   2. Inspector 调 `tone_color` + `intensity`（`intensity = 0` 时完全不绘制，零开销）；
##   3. 代码里用 `set_tone()` / `fade_to()` / `clear_tone()` 动态改。
##
## 【与 CanvasModulate 的区别】CanvasModulate 只能做乘法，且会连带影响同 canvas 上的
## 所有 CanvasItem；本节点是屏幕后处理，额外提供亮度/对比度/饱和度，并能用 layer
## 精确划分「谁参与、谁不参与」。

@export_group("色调")
## 目标色调（乘法）。白 (1,1,1,1) = 不改变画面；分量 >1 提亮；alpha 参与强度计算。
@export var tone_color: Color = Color(1, 1, 1, 1):
	set(v):
		tone_color = v
		_push_params()
## 强度 0~1：0 = 完全无效果（不绘制），1 = 完全套用色调。
@export_range(0.0, 1.0, 0.01) var intensity: float = 0.0:
	set(v):
		intensity = v
		_push_params()

@export_group("画面微调")
@export_range(0.0, 2.0, 0.01) var brightness: float = 1.0:
	set(v):
		brightness = v
		_push_params()
@export_range(0.0, 2.0, 0.01) var saturation: float = 1.0:
	set(v):
		saturation = v
		_push_params()
@export_range(0.0, 2.0, 0.01) var contrast: float = 1.0:
	set(v):
		contrast = v
		_push_params()

@export_group("层级与排除")
## 本色调层所在的 CanvasLayer 层号。默认 50 = 世界(0) 之上、UI(90+) 之下。
## ★任何 layer **大于**此值的 CanvasLayer 都不参与色调 —— 这是排除 UI 的主要手段。
@export var tone_layer: int = 50
## 额外「不参与画面色调」的节点。填 **CanvasLayer**（UI 层）即可：它们会被临时抬到
## 色调层之上，退出时自动恢复原层号。
## ⚠ 只能排除 CanvasLayer —— 普通 Node2D/Control 无法逐个排除（后处理是整屏的）。
##   这类节点请把它们的父层改成 CanvasLayer，再把那个层填进来。
@export var excluded_nodes: Array[NodePath] = []

@onready var _overlay: ColorRect = $Overlay

var _mat: ShaderMaterial
## 被抬走层号的节点 → 原 layer（退出时恢复）
var _saved_layers: Dictionary = {}


func _ready() -> void:
	layer = tone_layer
	_mat = _overlay.material as ShaderMaterial
	_apply_exclusions()
	_push_params()


func _exit_tree() -> void:
	_restore_layers()
	## ★松开材质引用：脚本成员持有 ShaderMaterial 时，退出会报
	## `ERROR: resources still in use at exit`（用 --quit-after 强退时 `_exit_tree`
	## 之后的清理顺序不受我们控制，提前松手最稳）。
	## 松手后若节点被重新加回树，`_push_params()` 会懒取一次，不会失效。
	_mat = null


## 立即套用色调（intensity 默认 1 = 完全套用）。
func set_tone(color: Color, intensity_value: float = 1.0) -> void:
	tone_color = color
	intensity = intensity_value


## 平滑过渡到目标色调。
func fade_to(color: Color, intensity_value: float = 1.0, duration: float = 0.6) -> void:
	var tw: Tween = create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "tone_color", color, duration)
	tw.tween_property(self, "intensity", intensity_value, duration)


## 清除色调（0 秒 = 立刻；>0 = 淡出）。
func clear_tone(duration: float = 0.6) -> void:
	if duration <= 0.0:
		tone_color = Color(1, 1, 1, 1)
		intensity = 0.0
		return
	fade_to(Color(1, 1, 1, 1), 0.0, duration)


## 当前是否真的在影响画面（用于日志 / 用例断言）。
func is_active() -> bool:
	return intensity > 0.0 or not is_equal_approx(brightness, 1.0) \
		or not is_equal_approx(saturation, 1.0) or not is_equal_approx(contrast, 1.0)


func _push_params() -> void:
	if _mat == null:
		## 懒取（_ready 之前 / 被移出树后重新入树时）：_mat 只在这里与 _ready 里赋值，
		## 绝不常驻持有，避免退出时的资源占用告警。
		var ov0: ColorRect = get_node_or_null("Overlay")
		if ov0 != null:
			_mat = ov0.material as ShaderMaterial
	if _mat == null:
		return   ## 节点还没就绪：值已存在属性里，_ready 会统一推一次
	_mat.set_shader_parameter("tone_color", tone_color)
	_mat.set_shader_parameter("intensity", intensity)
	_mat.set_shader_parameter("brightness", brightness)
	_mat.set_shader_parameter("saturation", saturation)
	_mat.set_shader_parameter("contrast", contrast)
	## 完全无效果时干脆不绘制：省掉一次全屏 back-buffer 拷贝（移动端有感知）。
	var ov: ColorRect = get_node_or_null("Overlay")
	if ov != null:
		ov.visible = is_active()


## 把 excluded_nodes 里的 CanvasLayer 抬到色调层之上（原值记下来）。
func _apply_exclusions() -> void:
	for p: NodePath in excluded_nodes:
		var n: Node = get_node_or_null(p)
		if n == null:
			push_warning("[ScreenTone] excluded_nodes 里找不到节点：%s" % p)
			continue
		if n is CanvasLayer:
			var cl: CanvasLayer = n
			if not _saved_layers.has(cl):
				_saved_layers[cl] = cl.layer
			cl.layer = maxi(cl.layer, tone_layer + 1)
		else:
			push_warning("[ScreenTone] excluded_nodes 只支持 CanvasLayer，已忽略：%s（%s）" % [
				p, n.get_class()])


func _restore_layers() -> void:
	for key: Variant in _saved_layers.keys():
		if is_instance_valid(key):
			(key as CanvasLayer).layer = int(_saved_layers[key])
	_saved_layers.clear()
