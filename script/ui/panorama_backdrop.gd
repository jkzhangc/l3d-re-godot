class_name PanoramaBackdrop extends Node2D

## ── 架构定位 ──
## 系统：界面公共组件 ｜ 层：表现（Node2D）
## 职责：下滚全景背景（角色选择界面同款）：重复纹理 + 缓慢下滚 + 压暗覆层。
##       供关卡选择 / 难度选择等界面复用，保证与角色选择界面观感统一。
## 依赖：无。
##
## 【用法】在 Control 界面的 _ready 里最先 add_child（先加的先画 → 垫底）：
##   var backdrop := PanoramaBackdrop.new()
##   backdrop.texture_path = "res://art/Panorama/地下.png"
##   add_child(backdrop)

@export_group("背景")
@export var texture_path: String = "res://art/Panorama/地下.png"
@export var bg_scale: float = 2.0               ## 背景放大倍数
@export var scroll_speed: float = 20.0          ## 滚动速度（素材像素/秒，向下）
@export var dim_alpha: float = 0.35             ## 压暗覆层透明度（保证前景可读）

var _bg_sprite: Sprite2D = null
var _region_size: Vector2 = Vector2.ZERO
var _offset: float = 0.0


func _ready() -> void:
	var tex: Texture2D = load(texture_path) as Texture2D
	if not tex:
		push_warning("[PanoramaBackdrop] 背景素材加载失败: %s，退回纯色" % texture_path)
		var fallback := ColorRect.new()
		fallback.color = Color(0.02, 0.02, 0.08, 1.0)
		fallback.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(fallback)
		return

	var view := get_viewport_rect().size
	_region_size = (view / bg_scale).ceil()
	_bg_sprite = Sprite2D.new()
	_bg_sprite.name = "ScrollingBackground"
	_bg_sprite.texture = tex
	_bg_sprite.centered = false
	_bg_sprite.scale = Vector2(bg_scale, bg_scale)
	_bg_sprite.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	_bg_sprite.region_enabled = true
	_bg_sprite.region_rect = Rect2(Vector2.ZERO, _region_size)
	add_child(_bg_sprite)

	# 轻微压暗，保证窗口/文字可读（与角色选择界面一致）
	var dim := ColorRect.new()
	dim.name = "DimOverlay"
	dim.color = Color(0, 0, 0, dim_alpha)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)


func _process(delta: float) -> void:
	if not _bg_sprite:
		return
	# region 原点上移 = 画面内容向下滚动；取模防浮点漂移，纹理重复保证无缝
	_offset = fmod(_offset + scroll_speed * delta, 240.0)
	_bg_sprite.region_rect = Rect2(Vector2(0.0, -_offset), _region_size)
