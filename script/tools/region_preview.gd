extends Control

## ── 架构定位 ──
## 系统：物品编辑器的可视化工具 ｜ 层：UI（Control，画布）
## 联机：不涉及（编辑器工具，运行期不加载）
## 职责：把武器的「攻击区域」画出来 —— 近战判定矩形 / 推击判定矩形 + 溅射圈 / 子弹射程线。
## 依赖：WeaponData 字段、CharacterData 行走图（角色身体，仅供比例参照）
##
## 【为什么这里必须画轴对齐矩形】运行时的近战/推击判定是
## `RectangleShape2D` + 零旋转（见 `PlayerMeleeAttackState._create_melee_hitbox`），
## 世界里就是正放的矩形，`melee_range_size.x` = 横向、`.y` = 纵向。
## 画成旋转矩形会让人误判"左右砍得比上下砍得远"，进而配错数值。
## （敌人攻击是投影法 + 朝向旋转，属于另一套，见 EnemyAttackState。）
##
## 拖动矩形 = 改「前伸偏移」（沿朝向轴的投影），只负责画与发信号，
## 写回 .tres 由 item_editor 处理（与 offset_preview.gd 同款分工）。

signal forward_edited(mode: String, value: float)

const MODE_MELEE := "melee"
const MODE_SHOVE := "shove"
const MODE_BULLET := "bullet"

const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRS: int = 4
## 角色 Sprite2D 在 player.tscn 里的 position = (0, -16)
const SPRITE_Y: float = -16.0

const C_MELEE := Color(1.0, 0.38, 0.24)
const C_SHOVE := Color(0.35, 0.85, 1.0)
const C_BULLET := Color(1.0, 0.85, 0.2)

var weapon: WeaponData = null
var character: CharacterData = null
var character_id: String = ""
var mode: String = MODE_MELEE
var direction: int = 0
var frame: int = 1
var bullet_index: int = 0
var zoom: float = 2.0
var font: Font = null

var _dragging: bool = false
var _origin: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_NONE
	_origin = Vector2(size.x * 0.5, size.y * 0.52)
	resized.connect(func():
		_origin = Vector2(size.x * 0.5, size.y * 0.52)
		queue_redraw())


func set_preview(p_weapon: WeaponData, p_character: CharacterData, p_mode: String,
		p_direction: int, p_frame: int, p_bullet_index: int = 0) -> void:
	weapon = p_weapon
	character = p_character
	character_id = p_character.get_character_key() if p_character else ""
	mode = p_mode
	direction = clampi(p_direction, 0, 3)
	frame = clampi(p_frame, 0, 2)
	bullet_index = maxi(0, p_bullet_index)
	queue_redraw()


func cancel_drag() -> void:
	_dragging = false


# ═══════════════════════════════════════
# 绘制
# ═══════════════════════════════════════

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#1b1b1e"))
	_draw_grid()
	if weapon == null:
		_text(Vector2(16, 28), "没有可预览的武器", Color("#e2b93d"))
		return
	_draw_character()
	match mode:
		MODE_MELEE:
			_draw_rect_region(weapon.melee_range_size, weapon.melee_range_forward_offset,
				C_MELEE, "近战", false, 0.0)
		MODE_SHOVE:
			_draw_rect_region(weapon.shove_range_size, weapon.shove_range_forward_offset,
				C_SHOVE, "推击", true, weapon.shove_splash_radius)
		MODE_BULLET:
			_draw_bullet_range()
	_draw_origin()
	_draw_info()


func _draw_grid() -> void:
	var step_px: float = 16.0 * zoom
	var col := Color(1, 1, 1, 0.035)
	var x: float = fposmod(_origin.x, step_px)
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), col, 1.0)
		x += step_px
	var y: float = fposmod(_origin.y, step_px)
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), col, 1.0)
		y += step_px


func _body_center() -> Vector2:
	return _origin + Vector2(0, SPRITE_Y) * zoom


func _dir_vec() -> Vector2:
	match direction:
		0: return Vector2.DOWN
		1: return Vector2.LEFT
		2: return Vector2.RIGHT
		3: return Vector2.UP
	return Vector2.DOWN


func _dir_label() -> String:
	return ["下", "左", "右", "上"][direction]


func _draw_character() -> void:
	var tex: Texture2D = _character_texture()
	if tex == null:
		return
	var src: Rect2 = _char_region(tex)
	var dst_size: Vector2 = Vector2(FRAME_W, FRAME_H) * zoom
	var center: Vector2 = _body_center()
	draw_texture_rect_region(tex, Rect2(center - dst_size * 0.5, dst_size), src, Color.WHITE)


## 轴对齐判定矩形：中心 = 角色原点 + 朝向 × 前伸偏移（与运行时完全一致）。
func _draw_rect_region(p_size: Vector2, forward: float, color: Color, title: String,
		dashed: bool, splash: float) -> void:
	if p_size.x <= 0.0 or p_size.y <= 0.0:
		_text(_origin + Vector2(16, -60), "%s判定尺寸为 0（不会命中）" % title, Color("#ff8a65"))
		return
	var center: Vector2 = _origin + _dir_vec() * forward * zoom
	var rect := Rect2(center - p_size * 0.5 * zoom, p_size * zoom)
	draw_rect(rect, Color(color.r, color.g, color.b, 0.14), true)
	if dashed:
		_dashed_rect(rect, color, 2.0, 6.0, 4.0)
	else:
		draw_rect(rect, color, false, 2.0)

	if splash > 0.0:
		draw_arc(center, splash * zoom, 0.0, TAU, 40, Color(color.r, color.g, color.b, 0.5), 1.5)

	## 中心点 + 前伸指示线（从角色原点到矩形中心）
	draw_line(_origin, center, Color(color.r, color.g, color.b, 0.35), 1.0)
	draw_circle(center, 3.0, color)
	_text(rect.position + Vector2(2, -6),
		"%s %d×%d · 前伸 %d" % [title, roundi(p_size.x), roundi(p_size.y), roundi(forward)],
		color)


## 子弹射程：起点 = BulletData 的发射方向 × spawn_offset，长度 = BulletData.max_range。
## ⚠ 射程 / 速度属于 **BulletData**（`bullet_list` 里的一条），不是 WeaponData 字段。
func _draw_bullet_range() -> void:
	var bd: BulletData = _bullet()
	if bd == null:
		_text(_origin + Vector2(16, -60), "这把武器没有子弹资源（不会发射）", Color("#ff8a65"))
		return
	var dir: Vector2 = _dir_vec()
	var fire_dir: Vector2 = bd.get_fire_direction(dir)
	var start: Vector2 = _origin + fire_dir * bd.spawn_offset * zoom
	var end: Vector2 = start + fire_dir * bd.max_range * zoom

	draw_circle(start, 4.0, C_BULLET)
	_dashed_line(start, end, C_BULLET, 2.0, 7.0, 5.0)
	## 箭头
	var side: Vector2 = Vector2(-fire_dir.y, fire_dir.x)
	draw_line(end, end - fire_dir * 12.0 + side * 6.0, C_BULLET, 2.0)
	draw_line(end, end - fire_dir * 12.0 - side * 6.0, C_BULLET, 2.0)
	_text(start + Vector2(8, -8),
		"射程 %d px · 速度 %d px/s" % [roundi(bd.max_range), roundi(bd.speed)], C_BULLET)


func _draw_origin() -> void:
	draw_line(_origin - Vector2(9, 0), _origin + Vector2(9, 0), Color(1, 1, 1, 0.45), 1.0)
	draw_line(_origin - Vector2(0, 9), _origin + Vector2(0, 9), Color(1, 1, 1, 0.45), 1.0)
	_text(_origin + Vector2(12, 16), "角色原点", Color(0.7, 0.7, 0.7))


func _draw_info() -> void:
	var lines: Array[String] = []
	lines.append("模式：%s   方向：%s" % [_mode_label(), _dir_label()])
	lines.append("角色：%s" % (character_id if not character_id.is_empty() else "（未设置）"))
	lines.append("缩放：%d%%   滚轮缩放" % int(round(zoom * 100.0)))
	for i: int in range(lines.size()):
		_text(Vector2(14, 22 + i * 18), lines[i], Color(0.78, 0.78, 0.78))
	_text(Vector2(14, size.y - 14), "拖动矩形 = 改前伸偏移（判定尺寸用右侧输入框）", Color(0.62, 0.62, 0.62))


func _text(pos: Vector2, text: String, color: Color) -> void:
	draw_string(_font(), pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)


func _font() -> Font:
	return font if font != null else ThemeDB.fallback_font


# ═══════════════════════════════════════
# 数据
# ═══════════════════════════════════════

func _character_texture() -> Texture2D:
	if weapon == null:
		return null
	if character != null:
		var t: Texture2D = character.get_weapon_walk_texture(weapon.weapon_state_name)
		if t != null:
			return t
	return weapon.weapon_walk_texture


func _char_region(tex: Texture2D) -> Rect2:
	var char_idx: int = weapon.get_ready_char_index()
	var col: int = char_idx % CHARS_PER_ROW
	var row: int = char_idx / CHARS_PER_ROW
	var x: int = col * FRAME_W * 3 + frame * FRAME_W
	var y: int = row * FRAME_H * DIRS + direction * FRAME_H
	x = clampi(x, 0, maxi(0, tex.get_width() - FRAME_W))
	y = clampi(y, 0, maxi(0, tex.get_height() - FRAME_H))
	return Rect2(x, y, FRAME_W, FRAME_H)


func _bullet() -> BulletData:
	if weapon == null or weapon.bullet_list.is_empty():
		return null
	return weapon.bullet_list[clampi(bullet_index, 0, weapon.bullet_list.size() - 1)]


func _mode_label() -> String:
	match mode:
		MODE_SHOVE: return "推击区域"
		MODE_BULLET: return "子弹射程"
	return "近战区域"


## 当前可拖动的区域矩形（屏幕坐标）；射程模式没有可拖动的矩形。
func _region_rect() -> Rect2:
	match mode:
		MODE_MELEE:
			var c: Vector2 = _origin + _dir_vec() * weapon.melee_range_forward_offset * zoom
			return Rect2(c - weapon.melee_range_size * 0.5 * zoom, weapon.melee_range_size * zoom)
		MODE_SHOVE:
			var c2: Vector2 = _origin + _dir_vec() * weapon.shove_range_forward_offset * zoom
			return Rect2(c2 - weapon.shove_range_size * 0.5 * zoom, weapon.shove_range_size * zoom)
	return Rect2()


# ═══════════════════════════════════════
# 交互
# ═══════════════════════════════════════

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clampf(zoom * 1.15, 0.5, 6.0)
			queue_redraw()
			accept_event()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clampf(zoom / 1.15, 0.5, 6.0)
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mode != MODE_BULLET and _region_rect().grow(6.0).has_point(mb.position):
					_dragging = true
					_apply_drag(mb.position)
					accept_event()
			else:
				_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		_apply_drag((event as InputEventMouseMotion).position)
		accept_event()


func _apply_drag(screen: Vector2) -> void:
	## 只看「鼠标相对角色原点」在朝向轴上的投影：前伸偏移就是这个标量。
	## 本函数**不写资源**（与 offset_preview 同款分工）：发信号 → item_editor 写回 .tres 并刷新。
	var world: Vector2 = (screen - _origin) / zoom
	var forward: float = clampf(roundf(world.dot(_dir_vec())), 0.0, 512.0)
	var current: float = 0.0
	match mode:
		MODE_MELEE: current = weapon.melee_range_forward_offset
		MODE_SHOVE: current = weapon.shove_range_forward_offset
		_: return
	if is_equal_approx(forward, current):
		return
	forward_edited.emit(mode, forward)


func _dashed_rect(rect: Rect2, color: Color, width: float, dash: float, gap: float) -> void:
	_dashed_line(rect.position, Vector2(rect.end.x, rect.position.y), color, width, dash, gap)
	_dashed_line(Vector2(rect.end.x, rect.position.y), rect.end, color, width, dash, gap)
	_dashed_line(rect.end, Vector2(rect.position.x, rect.end.y), color, width, dash, gap)
	_dashed_line(Vector2(rect.position.x, rect.end.y), rect.position, color, width, dash, gap)


func _dashed_line(from: Vector2, to: Vector2, color: Color, width: float,
		dash: float, gap: float) -> void:
	var total: float = from.distance_to(to)
	if total <= 0.0:
		return
	var dir: Vector2 = (to - from) / total
	var step: float = dash + gap
	var t: float = 0.0
	while t < total:
		var seg_end: float = minf(t + dash, total)
		draw_line(from + dir * t, from + dir * seg_end, color, width)
		t += step
