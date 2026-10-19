extends Node2D

## ── 架构定位 ──
## 系统：光照 / 粒子试验场（开发工具，不进正式关卡）
## 联机：无（纯单机调参）
## 职责：把夜间视界、光源颜色/亮度/闪烁/遮挡、角色投影、火星粒子放在一张图里做实时对比，
##       顺便演示 FirePatch（燃烧瓶火海）的完整表现链：火精灵 + 光色 + 闪烁 + 余烬。
## 用法：编辑器打开 scene/fx/light_lab.tscn → F6 直接跑。
##   1~4  开关对应光源（火光由 FirePatch 自动维持，不受 1~4 影响）
##   ↑ ↓  调整夜晚浓度（darkness）
##   G    开关加法发光 pass（对比"只挖亮"与"挖亮+上色"）
##   O    开关墙体遮挡（对比"光穿墙"与"被墙挡住"）
##   F    开关全部闪烁
##   空格  在鼠标处烧一团火（FirePatch，6 秒）
##   P    开关全部火星粒子
##   H    显示/隐藏操作说明
##   R    复位

const FIRE_INTERVAL: float = 6.0

## 墙体（世界坐标矩形）。同一份数据既画出来，也用来生成 StaticBody2D 碰撞
## —— 夜间视界的遮挡射线只认 collision_layer 第 1 位。
const WALL_THICKNESS: float = 10.0
const WALLS: Array[Rect2] = [
	Rect2(0, 0, 640, WALL_THICKNESS),
	Rect2(0, 480 - WALL_THICKNESS, 640, WALL_THICKNESS),
	Rect2(0, 0, WALL_THICKNESS, 480),
	Rect2(640 - WALL_THICKNESS, 0, WALL_THICKNESS, 480),
	# 左房间隔墙：中间留 44px 门洞
	Rect2(210, 0, WALL_THICKNESS, 218),
	Rect2(210, 262, WALL_THICKNESS, 218),
	# 右半区横墙：中间留 80px 门洞
	Rect2(210, 250, 170, WALL_THICKNESS),
	Rect2(460, 250, 170, WALL_THICKNESS),
]

var _overlay: NightOverlay = null
var _hud: Label = null
var _hud_layer: CanvasLayer = null
var _lights: Array[LightEmitter] = []
var _saved_flicker: Array[float] = []
var _fire_left: float = 0.0
var _flicker_on: bool = true
var _embers_on: bool = true
var _glow_on: bool = true
var _occlude_on: bool = true


func _ready() -> void:
	_build_walls()
	_overlay = get_node_or_null("NightOverlay") as NightOverlay
	for name: String in ["Torch", "Lamp", "CoolLight", "PulseLight"]:
		var n := get_node_or_null(name)
		if n is LightEmitter:
			_lights.append(n as LightEmitter)
			_saved_flicker.append((n as LightEmitter).flicker)
	if _overlay:
		# 让假人也参与投影（正式关卡只有 player / enemy 两组）
		_overlay.shadow_groups.append(&"lab_dummy")
	_build_hud()
	_fire_left = 0.0


func _build_walls() -> void:
	var body := StaticBody2D.new()
	body.name = "Walls"
	body.collision_layer = 1
	body.collision_mask = 0
	for r: Rect2 in WALLS:
		var cs := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = r.size
		cs.shape = shape
		cs.position = r.get_center()
		body.add_child(cs)
	add_child(body)


func _process(delta: float) -> void:
	# 火堆：FirePatch 到时间会自己 queue_free，这里循环补一团，保证一直有火看。
	_fire_left -= delta
	if _fire_left <= 0.0:
		_fire_left = FIRE_INTERVAL
		_spawn_fire(Vector2(110, 380))


func _spawn_fire(pos: Vector2) -> void:
	# authoritative = false：试验场里不结算伤害，只跑表现（火精灵动画 / 光 / 余烬）。
	FirePatch.spawn(pos, 2, FIRE_INTERVAL + 0.5, 0.0, 0.33, 0, null, self,
		false, false, null, false, 150.0, 1.0, Color(1.0, 0.52, 0.22), 0.26, 14)


func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 10
	add_child(_hud_layer)
	var panel := ColorRect.new()
	panel.color = Color(0.0, 0.0, 0.0, 0.55)
	panel.position = Vector2(12, 12)
	panel.size = Vector2(336, 176)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(panel)
	_hud = Label.new()
	_hud.position = Vector2(22, 20)
	_hud.size = Vector2(316, 164)
	_hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud.add_theme_color_override("font_color", Color(0.85, 0.95, 0.85))
	Global.apply_ui_font(_hud, 12)
	_hud_layer.add_child(_hud)
	_refresh_hud()


func _refresh_hud() -> void:
	if _hud == null:
		return
	var d: float = _overlay.darkness if _overlay else 0.0
	_hud.text = "光照 / 粒子试验场\n夜晚 %.2f   发光 %s   遮挡 %s   闪烁 %s\n\n1 火把  2 白炽灯  3 冷光  4 呼吸灯\n↑↓ 浓度  G 发光  O 遮挡  F 闪烁\n空格 烧火  P 火星  H 隐藏  R 复位" % [
		d, "开" if _glow_on else "关", "开" if _occlude_on else "关", "开" if _flicker_on else "关"]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1, KEY_2, KEY_3, KEY_4:
			var i: int = int(key.keycode) - int(KEY_1)
			if i < _lights.size():
				_lights[i].set_light_enabled(not _lights[i].light_enabled)
		KEY_UP:
			if _overlay:
				_overlay.set_darkness(_overlay.darkness + 0.05)
		KEY_DOWN:
			if _overlay:
				_overlay.set_darkness(_overlay.darkness - 0.05)
		KEY_G:
			_glow_on = not _glow_on
			if _overlay:
				_overlay.set_glow_strength(0.5 if _glow_on else 0.0)
		KEY_O:
			_occlude_on = not _occlude_on
			for l: LightEmitter in _lights:
				l.occlude = _occlude_on
				l.apply_params()
		KEY_F:
			_flicker_on = not _flicker_on
			for i: int in _lights.size():
				_lights[i].flicker = _saved_flicker[i] if _flicker_on else 0.0
				_lights[i].apply_params()
		KEY_P:
			_embers_on = not _embers_on
			for l: LightEmitter in _lights:
				l.set_embers_enabled(_embers_on)
		KEY_SPACE:
			_spawn_fire(get_global_mouse_position())
		KEY_H:
			_hud_layer.visible = not _hud_layer.visible
		KEY_R:
			if _overlay:
				_overlay.set_darkness(0.9)
				_overlay.set_glow_strength(0.5)
			_glow_on = true
			_flicker_on = true
			_occlude_on = true
			for i: int in _lights.size():
				_lights[i].flicker = _saved_flicker[i]
				_lights[i].occlude = true
				_lights[i].apply_params()
				_lights[i].set_light_enabled(true)
	_refresh_hud()


## 地面 / 网格 / 墙体 / 色块：给光照当参照物（不依赖任何美术资源）。
## 坐标系按摄像机的 640×480 可视区摆（工程用 2x 画布缩放）。
func _draw() -> void:
	draw_rect(Rect2(0, 0, 640, 480), Color(0.16, 0.17, 0.20))
	for x: int in range(0, 641, 32):
		draw_line(Vector2(x, 0), Vector2(x, 480), Color(0.24, 0.26, 0.31), 1.0)
	for y: int in range(0, 481, 32):
		draw_line(Vector2(0, y), Vector2(640, y), Color(0.24, 0.26, 0.31), 1.0)
	for r: Rect2 in WALLS:
		draw_rect(r, Color(0.42, 0.36, 0.30))
		draw_rect(r, Color(0.20, 0.17, 0.14), false, 1.0)
	# 色块：检验光色是否把底色染对（暖光下蓝块应变暗紫、红块更艳）
	var swatches: Array = [
		[Vector2(36, 300), Color(0.75, 0.20, 0.18)],
		[Vector2(92, 300), Color(0.20, 0.62, 0.26)],
		[Vector2(148, 300), Color(0.20, 0.32, 0.78)],
		[Vector2(250, 300), Color(0.78, 0.76, 0.70)],
		[Vector2(306, 300), Color(0.42, 0.40, 0.44)],
	]
	for s: Array in swatches:
		var p: Vector2 = s[0]
		draw_rect(Rect2(p.x, p.y, 48, 48), s[1])
		draw_rect(Rect2(p.x, p.y, 48, 48), Color(0, 0, 0, 0.55), false, 1.0)
