extends RefCounted

## ── 架构定位 ──
## 系统：玩家精灵渲染 ｜ 层：服务类（RefCounted，由 player 持有）
## 联机：表现层（远端实体也走本服务刷新行走/武器/落地帧），与权威解耦
## 职责：按当前模式（普通/武器/推击/投掷物）刷新 sprite 的贴图与 region_rect；
##       计算当前移动档的动画帧时长。
## 依赖：player 实体（读 @export 外观字段、模式状态、sprite 节点）
##
## 【为什么从 player.gd 抽出（2026-10-08）】精灵渲染 + 帧时长约 65 行、纯表现逻辑，
## 与状态机/权威战斗无关。`_refresh_sprite` / `_mode_anim_duration` 均为 player 内部自用
## （外部无调用点），抽出后 player.gd 保留同名转发门面。
##
## 【状态变量留在 player】`_moving` / `_is_walking` / `_anim_step` / `_facing` /
## `_weapon_mode` / `_weapon_data` / `_current_weapon_char_idx` / `_shove_mode` /
## `_shove_texture` / `_throwable_mode` / `_throwable_texture` / `_throwable_char_idx` /
## `_is_dying` **全部保留在 player.gd** —— 只搬「逻辑」不搬「状态」。本服务经 `_p.<字段>`
## 读写（GDScript 下划线仅约定）。`sprite` 是 @onready 节点引用，也留在 player。

## 帧常量（与原 player.gd 同名同值；VX Ace 标准角色格 = 4 方向 × 3 帧）。
const FRAME_W: int = 48   ## 576 / 12
const FRAME_H: int = 64   ## 512 / 8
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
const WALK_SEQUENCE: Array[int] = [1, 0, 1, 2]
const STAND_FRAME: int = 1
const DIR_ROWS: Array[int] = [0, 1, 2, 3]

var _p: Node = null


func _init(player: Node) -> void:
	_p = player


## 当前移动档的动画帧时长（秒）：CharacterData 值 >0 = 手动固定；0 = 按全局基准
## （150px/s↔0.18s）与当前档速度自动换算——速度越快帧间隔越短（2026-09-15 统一公式）。
func mode_anim_duration(is_walking: bool) -> float:
	var manual: float = _p.walk_frame_duration if is_walking else _p.run_frame_duration
	if manual > 0.0:
		return manual
	var speed: float = _p.walk_speed if is_walking else _p.run_speed
	return clampf(Global.ANIM_BASE_FRAME_DURATION * Global.ANIM_BASE_SPEED / maxf(speed, 1.0), 0.05, 0.5)


## 按当前模式刷新精灵贴图与帧区，并同步「武器单体动作图」。
## 死亡后拒绝一切刷新，防止覆盖 _die() 设置的死亡帧。
func refresh_sprite() -> void:
	_refresh_character_sprite()
	_refresh_weapon_overlay()


## 角色本体（行走图 / 武器行走图 / 投掷物 / 推击）的贴图与帧区。
func _refresh_character_sprite() -> void:
	var sprite: Sprite2D = _p.sprite
	if not sprite:
		return
	if _p._is_dying:   ## 死亡后拒绝一切刷新，防止覆盖 _die() 设置的死亡帧
		return

	# 投掷物举起模式：使用投掷物行走图（跟随朝向+踏步）
	if _p._throwable_mode and _p._throwable_texture:
		sprite.texture = _p._throwable_texture
		var char_idx: int = _p._throwable_char_idx
		var frame: int = STAND_FRAME if not _p._moving else WALK_SEQUENCE[_p._anim_step]
		var char_col: int = char_idx % CHARS_PER_ROW
		var char_row: int = char_idx / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_p._facing]
		var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
		return

	# 武器模式下使用武器纹理和角色索引
	if _p._weapon_mode and _p._weapon_data:
		# 推击模式：优先推击行走图（运行时设置 > 武器字段 > 角色字段 > 回退普通武器纹理）
		if _p._shove_mode and _p._shove_texture:
			sprite.texture = _p._shove_texture
		else:
			var tex: Texture2D = _weapon_body_texture(_p._weapon_data)
			if not tex:
				return
			sprite.texture = tex
		var char_idx: int = _p._current_weapon_char_idx
		var frame: int = STAND_FRAME if not _p._moving else WALK_SEQUENCE[_p._anim_step]

		var char_col: int = char_idx % CHARS_PER_ROW
		var char_row: int = char_idx / CHARS_PER_ROW
		var dir_row: int = DIR_ROWS[_p._facing]

		var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
		sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
		return

	# 普通模式
	if not _p.walk_texture or not _p.run_texture:
		return
	var use_run_tex: bool = _p._moving and not _p._is_walking
	sprite.texture = _p.run_texture if use_run_tex else _p.walk_texture

	var char_idx: int = _p.run_char_index if use_run_tex else _p.walk_char_index
	var frame: int = STAND_FRAME if not _p._moving else WALK_SEQUENCE[_p._anim_step]

	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var dir_row: int = DIR_ROWS[_p._facing]

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H

	sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


## ── 武器单体动作图（2026-10-23）──
## 「人物与武器分开显示」：角色仍走行走图，武器是独立精灵叠在上面。
## 取哪一帧由**攻击序列第几步**决定（`WeaponData.get_melee_weapon_sprite_col`）：
##   · 武器没配动作图 / 当前不在攻击动画里 / 死亡 / 推击 / 投掷物模式 → 隐藏；
##   · 列 = 前摇/挥动/后摇，行 = FaceDir（下左右上），与图集布局一一对应。
func _refresh_weapon_overlay() -> void:
	var ws: Sprite2D = _p.weapon_sprite
	if ws == null:
		return
	var wd: WeaponData = _p._weapon_data
	if _p._is_dying or _p._throwable_mode or _p._shove_mode \
			or not _p._weapon_mode or wd == null or not wd.has_melee_weapon_sprite():
		ws.visible = false
		return
	var col: int = wd.get_melee_weapon_sprite_col(_p._current_weapon_seq_idx)
	if col < 0:
		ws.visible = false
		return
	## 只有「通用近战身体」（行走图文件名带 近战/近接）才默认叠；
	## 专用身体的攻击帧自带武器，叠上去会变两把（`melee_weapon_sprite_force` 可强制）。
	if not wd.melee_weapon_sprite_force and not wd.is_generic_melee_body(_weapon_body_texture(wd)):
		ws.visible = false
		return
	var tex: Texture2D = wd.melee_weapon_sprite
	var cell_w: int = int(tex.get_width() / 3)
	var cell_h: int = int(tex.get_height() / 4)
	if cell_w <= 0 or cell_h <= 0:
		ws.visible = false
		return
	ws.texture = tex
	ws.region_rect = Rect2(col * cell_w, DIR_ROWS[_p._facing] * cell_h, cell_w, cell_h)
	## 偏移按「角色 × 步号 × 朝向」取：前摇/挥动/后摇的武器位置不一样，
	## 同一个偏移会让某一帧错位（2026-10-23 用户口径）。
	ws.position = wd.get_melee_weapon_sprite_offset(
		_p.current_character, _p._facing, _p._current_weapon_seq_idx)
	## 朝上时人物背对镜头 → 武器画到身后；其余方向画在身前。
	ws.z_index = -1 if (wd.melee_weapon_sprite_behind_on_up and _p._facing == 3) else 1
	ws.visible = true


## 角色当前拿这把武器时的行走图（角色专属 > 武器默认；都没有 → null）。
## 抽出成函数是为了让「角色本体贴图」和「要不要叠武器动作图」用**同一个**取值口径，
## 否则一边查 CharacterData、一边查 WeaponData，判断「是否通用近战身体」会走岔。
func _weapon_body_texture(wd: WeaponData) -> Texture2D:
	if wd == null:
		return null
	if _p.current_character:
		var tex: Texture2D = _p.current_character.get_weapon_walk_texture(wd.weapon_state_name)
		if tex:
			return tex
	return wd.weapon_walk_texture
