extends CanvasLayer

## ── 架构定位 ──
## 系统：加载画面 ｜ 层：表现（CanvasLayer，由 Global 常驻持有）
## 联机：不涉及逻辑；显示/结束由 Global 与 NetworkWorld 的 ready 协议驱动
## 职责：全屏黑幕 + 右下角「Loading」+ 上方丧尸追玩家的循环动画。
## 依赖：VXWalkSheet（行走图取帧）、Global.apply_ui_font（像素字体）

## 行走图取帧工具（RefCounted 纯静态，见该文件头）。
const WALK := preload("res://script/vx_walk_sheet.gd")
const PLAYER_FALLBACK := "res://art/Characters/のび太セット.png"
const ZOMBIE_TEXTURE := "res://art/Characters/男性ゾンビ1.png"
const FADE_SEC: float = 0.25

var _root: Control = null
var _player: Sprite2D = null
var _zombie: Sprite2D = null
var _label: Label = null
var _frame: int = 0
var _frame_t: float = 0.0
var _anim_t: float = 0.0
var _player_char_idx: int = 0
var _closing: bool = false
var _auto_hide_timer: Timer = null


func _ready() -> void:
	## ★章节总结 / 结算页会 `get_tree().paused = true`。加载画面必须能在暂停中跑完淡出，
	## 否则会永远盖在总结页上面（2026-10-30 用户实测）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 127
	_build()
	## 兜底：即使调用方被暂停/漏掉 hide，加载画面也不会永久盖住章节总结。
	_auto_hide_timer = Timer.new()
	_auto_hide_timer.one_shot = true
	_auto_hide_timer.wait_time = 5.0
	_auto_hide_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_auto_hide_timer.timeout.connect(finish)
	add_child(_auto_hide_timer)
	visible = false
	set_process(false)


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.92)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)

	## 右下角小舞台：312×152，离屏幕边 48px。
	var box := Control.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	box.offset_left = -360.0
	box.offset_top = -200.0
	box.offset_right = -48.0
	box.offset_bottom = -48.0
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(box)

	_player = Sprite2D.new()
	_player.centered = false
	_player.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_player.scale = Vector2(1.5, 1.5)
	_player.position = Vector2(160, 4)
	_player.z_index = 1
	box.add_child(_player)

	_zombie = Sprite2D.new()
	_zombie.centered = false
	_zombie.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_zombie.scale = Vector2(1.5, 1.5)
	_zombie.position = Vector2(40, 4)
	_zombie.z_index = 0
	box.add_child(_zombie)

	_label = Label.new()
	_label.text = "Loading"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.position = Vector2(0, 104)
	_label.size = Vector2(312, 48)
	_label.add_theme_color_override("font_color", Color(0.86, 0.86, 0.92))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g: Node = get_node_or_null("/root/Global")
	if g != null and g.has_method("apply_ui_font"):
		g.call("apply_ui_font", _label, 40)
	box.add_child(_label)


func show_loading() -> void:
	if _root == null:
		return
	visible = true
	_root.modulate = Color.WHITE
	_closing = false
	_frame = 0
	_frame_t = 0.0
	_anim_t = 0.0
	_apply_frames()
	set_process(true)
	if _auto_hide_timer != null:
		_auto_hide_timer.start()


func finish() -> void:
	if not visible or _closing:
		return
	_closing = true
	if _auto_hide_timer != null:
		_auto_hide_timer.stop()
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, FADE_SEC)
	tw.tween_callback(func() -> void:
		visible = false
		_root.modulate = Color.WHITE
		_closing = false
		set_process(false))


func is_open() -> bool:
	return visible


func _process(delta: float) -> void:
	_frame_t += delta
	if _frame_t >= 0.12:
		_frame_t -= 0.12
		_frame = (_frame + 1) % 3
		_apply_frames()
	_anim_t += delta
	## 两个人一起上下颠、丧尸追近又拉开 —— 不引入任何物理，纯 UI 循环。
	var bob: float = absf(sin(_anim_t * 10.0)) * 4.0
	var chase: float = sin(_anim_t * 4.0)
	_player.position = Vector2(160.0 + chase * 8.0, 4.0 + bob)
	_zombie.position = Vector2(40.0 + chase * 18.0, 4.0 + absf(sin(_anim_t * 10.0 + 1.2)) * 4.0)
	_label.text = "Loading" + ".".repeat(int(_anim_t * 2.0) % 4)


func _apply_frames() -> void:
	if _player == null or _zombie == null:
		return
	var ptex: Texture2D = _resolve_player_texture()
	if ptex != null:
		_player.texture = ptex
		_player.region_enabled = true
		_player.region_rect = WALK.region_rect(ptex, _player_char_idx, 2, _frame)
	var ztex: Texture2D = load(ZOMBIE_TEXTURE) as Texture2D
	if ztex != null:
		_zombie.texture = ztex
		_zombie.region_enabled = true
		_zombie.region_rect = WALK.region_rect(ztex, 0, 2, _frame)


## 优先用本机当前角色的行走图；取不到（标题/大厅/座位尚未建立）回退大雄。
func _resolve_player_texture() -> Texture2D:
	var players: Node = get_node_or_null("/root/Players")
	if players != null and players.get("seats") is Array:
		var seats: Array = players.get("seats")
		var idx: int = int(players.get("active_seat_index"))
		if idx >= 0 and idx < seats.size():
			var st: PlayerState = seats[idx] as PlayerState
			if st != null and st.character != null and st.character.walk_texture != null:
				_player_char_idx = st.character.walk_char_index
				return st.character.walk_texture
	_player_char_idx = 0
	return load(PLAYER_FALLBACK) as Texture2D
