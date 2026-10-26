extends Control

## ── 偏移可视化预览（物品编辑器工具）──
## 画布：角色行走图（举起/攻击帧）+ 偏移标记。支持三种模式：
##   · bullet：角色举起帧 + 黄色子弹点（按方向 / BulletData.spawn_offset + 武器级偏移）
##   · weapon：角色攻击帧 + 武器单体动作图（按步号选列，偏移即武器中心位置）
##   · effect：角色举起帧 + 攻击特效落点标记（不含 .tscn 内置 position_offset）
##
## 拖动标记（或武器图）会发 `offset_edited`，由 item_editor 写回 WeaponEffectOffsets。
## 这里只负责画和拖，不直接改资源。

signal offset_edited(mode: String, character_id: String, direction: int, value: Vector2)

const MODE_BULLET := "bullet"
const MODE_WEAPON := "weapon"
const MODE_EFFECT := "effect"

const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRS: int = 4
## 角色 Sprite2D 在 player.tscn 里的 position = (0, -16)
const SPRITE_Y: float = -16.0

var weapon: WeaponData = null
var character: CharacterData = null
var character_id: String = ""
var mode: String = MODE_BULLET
var direction: int = 0
var step: int = 0
var char_idx: int = 0
var frame: int = 1
var bullet_index: int = 0
## 武器级偏移（当前方向的 WeaponEffectOffsets 字段）
var offset: Vector2 = Vector2.ZERO
## true = 当前角色还没有武器级条目，画的是 BulletData / 特效兜底偏移
var using_default: bool = false
var zoom: float = 3.0
var font: Font = null

var _dragging: bool = false
var _grab: Vector2 = Vector2.ZERO
var _origin: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_NONE
	_origin = Vector2(size.x * 0.5, size.y * 0.62)
	resized.connect(func():
		_origin = Vector2(size.x * 0.5, size.y * 0.62)
		queue_redraw())


func set_preview(p_weapon: WeaponData, p_character: CharacterData, p_mode: String,
		p_direction: int, p_step: int, p_char_idx: int, p_frame: int,
		p_bullet_index: int, p_offset: Vector2, p_using_default: bool) -> void:
	weapon = p_weapon
	character = p_character
	character_id = p_character.get_character_key() if p_character else ""
	mode = p_mode
	direction = clampi(p_direction, 0, 3)
	step = p_step
	char_idx = maxi(0, p_char_idx)
	frame = clampi(p_frame, 0, 2)
	bullet_index = maxi(0, p_bullet_index)
	offset = p_offset
	using_default = p_using_default
	## 不在每次刷新时清 _dragging：拖动过程中 item_editor 会回写并刷新，
	## 清了会导致拖一下就断。切换模式/角色/方向时由 item_editor 调 cancel_drag()。
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
	## 朝上且武器画在人物身后时，先画武器再画人物。
	var behind: bool = mode == MODE_WEAPON and direction == 3 \
		and weapon.melee_weapon_sprite_behind_on_up
	if behind:
		_draw_weapon()
		_draw_character()
	else:
		_draw_character()
		if mode == MODE_WEAPON:
			_draw_weapon()
	_draw_marker()
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


## 角色 Sprite2D 的中心（= 角色原点 + SPRITE_Y，player.tscn 里 Sprite2D 的 position）。
## 武器单体动作图是 `Sprite2D` 的**子节点**，`position` 相对角色中心，
## 所以预览里武器必须画在「角色中心 + offset」；画在「角色原点 + offset」会差 16px，
## 这就是之前「游戏内位置和编辑器预览对不上」的根因（2026-10-24 用户反馈）。
func _body_center() -> Vector2:
	return _origin + Vector2(0, SPRITE_Y) * zoom


func _draw_character() -> void:
	var tex: Texture2D = _character_texture()
	if tex == null:
		return
	var src: Rect2 = _char_region(tex)
	var dst_size: Vector2 = Vector2(FRAME_W, FRAME_H) * zoom
	var center: Vector2 = _body_center()
	draw_texture_rect_region(tex, Rect2(center - dst_size * 0.5, dst_size), src, Color.WHITE)


func _draw_weapon() -> void:
	var tex: Texture2D = weapon.melee_weapon_sprite
	if tex == null:
		return
	var cell: Vector2 = Vector2(float(tex.get_width()) / 3.0, float(tex.get_height()) / 4.0)
	var col: int = weapon.get_melee_weapon_sprite_col(step)
	if col < 0:
		col = 1
	var src := Rect2(col * cell.x, direction * cell.y, cell.x, cell.y)
	var dst_size: Vector2 = cell * zoom
	var center: Vector2 = _body_center() + offset * zoom
	var rect := Rect2(center - dst_size * 0.5, dst_size)
	## 专用身体（文件名不含 近战/近接）且没开 force 时，游戏里不会叠动作图：
	## 这里画半透明提示，方便知道「调了也不会生效」。
	var alpha: float = 1.0 if _weapon_overlay_active() else 0.38
	draw_texture_rect_region(tex, rect, src, Color(1, 1, 1, alpha))


func _draw_marker() -> void:
	match mode:
		MODE_BULLET:
			var bd: BulletData = _bullet()
			if bd == null:
				return
			var base: Vector2 = _bullet_base()
			var p: Vector2 = _origin + (base + offset) * zoom
			draw_line(_origin, p, Color(1.0, 0.85, 0.2, 0.35), 2.0)
			draw_circle(p, 8.0, Color(0.05, 0.05, 0.06, 0.95))
			draw_circle(p, 5.5, Color(1.0, 0.88, 0.12))
			_text(p + Vector2(11, -8), "子弹 (%d, %d)" % [roundi(offset.x), roundi(offset.y)],
				Color(1.0, 0.9, 0.35))
			if using_default:
				_text(p + Vector2(11, 8), "当前用 BulletData 默认偏移", Color(0.75, 0.75, 0.75))
		MODE_EFFECT:
			var p: Vector2 = _origin + offset * zoom
			draw_circle(p, 14.0, Color(1.0, 0.4, 0.15, 0.20))
			draw_line(p - Vector2(17, 0), p + Vector2(17, 0), Color(1.0, 0.55, 0.2), 2.0)
			draw_line(p - Vector2(0, 17), p + Vector2(0, 17), Color(1.0, 0.55, 0.2), 2.0)
			## 特效点通常在身体上，标签不画在标记旁（会压住人物）；看右侧状态栏即可。
			if using_default:
				_text(p + Vector2(13, 8), "当前用 attack_effect_offset_override", Color(0.75, 0.75, 0.75))
		MODE_WEAPON:
			var p: Vector2 = _body_center() + offset * zoom
			draw_circle(p, 4.0, Color(0.35, 0.7, 1.0, 0.8))
			_text(p + Vector2(10, -8), "武器 (%d, %d)" % [roundi(offset.x), roundi(offset.y)],
				Color(0.55, 0.8, 1.0))


func _draw_origin() -> void:
	draw_line(_origin - Vector2(9, 0), _origin + Vector2(9, 0), Color(1, 1, 1, 0.45), 1.0)
	draw_line(_origin - Vector2(0, 9), _origin + Vector2(0, 9), Color(1, 1, 1, 0.45), 1.0)
	_text(_origin + Vector2(12, 16), "角色原点", Color(0.7, 0.7, 0.7))


func _weapon_overlay_active() -> bool:
	var tex: Texture2D = _character_texture()
	return weapon != null and (weapon.melee_weapon_sprite_force or weapon.is_generic_melee_body(tex))


func _draw_info() -> void:
	var lines: Array[String] = []
	lines.append("模式：%s" % _mode_label())
	lines.append("角色：%s   方向：%s" % [character_id if not character_id.is_empty() else "（未设置）",
		_dir_label()])
	if mode == MODE_WEAPON:
		var seq: Array[int] = weapon.get_melee_attack_char_sequence()
		var ci: int = seq[clampi(step, 0, seq.size() - 1)] if not seq.is_empty() else char_idx
		var col: int = weapon.get_melee_weapon_sprite_col(step)
		lines.append("步号：%d / %d   char_idx=%d   帧=%d   武器列=%s" % [
			step + 1, seq.size(), ci, frame, str(col) if col >= 0 else "本步不显示"])
		if not _weapon_overlay_active():
			lines.append("⚠ 专用身体自带武器：游戏内不叠动作图（可开 melee_weapon_sprite_force）")
	else:
		lines.append("角色索引：%d   帧：%d" % [char_idx, frame])
	lines.append("缩放：%d%%   滚轮缩放" % int(round(zoom * 100.0)))
	for i: int in range(lines.size()):
		_text(Vector2(14, 22 + i * 18), lines[i], Color(0.78, 0.78, 0.78))
	_text(Vector2(14, size.y - 14), "拖动标记 / 武器图调整偏移", Color(0.62, 0.62, 0.62))


func _text(pos: Vector2, text: String, color: Color) -> void:
	draw_string(_font(), pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)


func _font() -> Font:
	return font if font != null else ThemeDB.fallback_font


# ═══════════════════════════════════════
# 数据 / 命中
# ═══════════════════════════════════════

func _character_texture() -> Texture2D:
	if weapon == null:
		return null
	## 攻击步号预览必须和游戏内攻击时**同一张图**：配了「武器攻击行走图」就用它，
	## 否则回退举起图（2026-10-26 与 WeaponData.get_attack_walk_texture 同一取值链）。
	var atk: Texture2D = weapon.get_attack_walk_texture(character)
	if atk != null:
		return atk
	if character != null:
		var t: Texture2D = character.get_weapon_walk_texture(weapon.weapon_state_name)
		if t != null:
			return t
	return weapon.weapon_walk_texture


func _char_region(tex: Texture2D) -> Rect2:
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


func _dir_vec() -> Vector2:
	match direction:
		0: return Vector2.DOWN
		1: return Vector2.LEFT
		2: return Vector2.RIGHT
		3: return Vector2.UP
	return Vector2.DOWN


func _dir_label() -> String:
	return ["下", "左", "右", "上"][direction]


func _mode_label() -> String:
	match mode:
		MODE_WEAPON: return "武器动作偏移"
		MODE_EFFECT: return "攻击特效偏移"
	return "子弹偏移"


func _weapon_rect() -> Rect2:
	if weapon == null or weapon.melee_weapon_sprite == null:
		return Rect2()
	var tex: Texture2D = weapon.melee_weapon_sprite
	var cell: Vector2 = Vector2(float(tex.get_width()) / 3.0, float(tex.get_height()) / 4.0)
	var dst_size: Vector2 = cell * zoom
	return Rect2(_body_center() + offset * zoom - dst_size * 0.5, dst_size)


## 子弹基础位置 = 实际发射方向（direction_override / angle_offset 已应用） × spawn_offset。
## 武器级偏移仍按**角色朝向**取（与 PlayerRangedAttackState 一致）。
func _bullet_base() -> Vector2:
	var bd: BulletData = _bullet()
	if bd == null:
		return Vector2.ZERO
	return bd.get_fire_direction(_dir_vec()) * bd.spawn_offset


func _bullet_point() -> Vector2:
	var bd: BulletData = _bullet()
	if bd == null:
		return _origin
	return _origin + (_bullet_base() + offset) * zoom


func _hit(p: Vector2) -> bool:
	match mode:
		MODE_WEAPON:
			return _weapon_rect().grow(4.0).has_point(p)
		MODE_BULLET:
			return p.distance_to(_bullet_point()) <= 16.0
		MODE_EFFECT:
			return p.distance_to(_origin + offset * zoom) <= 18.0
	return false


func _active_point() -> Vector2:
	match mode:
		MODE_BULLET:
			return _bullet_point()
		MODE_WEAPON:
			return _body_center() + offset * zoom
		_:
			return _origin + offset * zoom


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clampf(zoom * 1.15, 1.0, 6.0)
			queue_redraw()
			accept_event()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clampf(zoom / 1.15, 1.0, 6.0)
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _hit(mb.position):
					_dragging = true
					_grab = mb.position - _active_point()
					accept_event()
			else:
				_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		_drag_to((event as InputEventMouseMotion).position - _grab)
		accept_event()


func _drag_to(screen: Vector2) -> void:
	## 武器动作图的 offset 相对角色中心；子弹/特效相对角色原点（= 脚底）。
	var anchor: Vector2 = _body_center() if mode == MODE_WEAPON else _origin
	var world: Vector2 = (screen - anchor) / zoom
	var value: Vector2 = world
	if mode == MODE_BULLET:
		var bd: BulletData = _bullet()
		if bd != null:
			value = world - _bullet_base()
	value = Vector2(roundf(value.x), roundf(value.y))
	value.x = clampf(value.x, -512.0, 512.0)
	value.y = clampf(value.y, -512.0, 512.0)
	if value == offset:
		return
	offset = value
	using_default = false
	queue_redraw()
	offset_edited.emit(mode, character_id, direction, offset)
