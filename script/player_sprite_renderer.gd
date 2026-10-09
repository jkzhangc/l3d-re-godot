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


## 按当前模式刷新精灵贴图与帧区。死亡后拒绝一切刷新，防止覆盖 _die() 设置的死亡帧。
func refresh_sprite() -> void:
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
			var tex: Texture2D = null
			# 角色专属武器行走图
			if _p.current_character:
				tex = _p.current_character.get_weapon_walk_texture(_p._weapon_data.weapon_state_name)
			# 回退到武器默认行走图
			if not tex:
				tex = _p._weapon_data.weapon_walk_texture
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
