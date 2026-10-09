extends RefCounted

## ── 架构定位 ──
## 系统：敌人精灵渲染 ｜ 层：服务类（RefCounted，由 enemy 持有）
## 联机：表现层；动作表切换会转发 Client（经 enemy._announce_network_action）
## 职责：敌人精灵表渲染：帧尺寸推断/登记、附加动作表栈（push/pop）、行走/站立帧刷新、
##       死亡外观切换、脚底锚点对齐。
## 依赖：enemy 实体（读 @export 外观字段与 sprite 节点；写 walk_texture / sprite_frame_*）
##
## 【为什么从 enemy.gd 抽出（2026-10-08）】精灵渲染约 200 行、是纯表现逻辑，
## 与 AI/战斗/联机权威无关。抽出后 enemy.gd 只保留**同名转发门面** → 外部调用点零改动。
##
## 【状态变量为何留在 enemy】`_action_texture_stack` / `_frame_size_by_texture` /
## `_frame_w_prev` / `_frame_h_prev` / `_action_texture_prev` / `_current_char_index` /
## `_death_appearance_applied` **全部保留在 enemy.gd** —— 只搬「逻辑」不搬「状态」，
## 避免状态迁移引入的时序风险。本服务经 `_e.<字段名>` 直接读写（GDScript 下划线仅约定）。

## 帧常量（与原 enemy.gd 同名同值；VX Ace 标准角色格 = 4 方向 × 3 帧）。
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
const WALK_SEQUENCE: Array[int] = [1, 0, 1, 2]
const STAND_FRAME: int = 1
const DIR_ROWS: Array[int] = [0, 1, 2, 3]

## 宿主 enemy 实体。
var _e: Node = null


func _init(enemy: Node) -> void:
	_e = enemy


# ═══════════════════════════════════════
# 动作表切换（特感：攻击/死亡使用独立贴图）
# ═══════════════════════════════════════

## 切到指定角色格的站立帧（攻击动画用）。会把踏步计数归零。
func set_attack_char_index(char_idx: int) -> void:
	_e._anim_step = 0
	refresh_sprite_with_index(char_idx)


## 切到附加动作表。tex 为空则不动作（保持当前贴图）。
##
## 帧尺寸 determination 顺序（用户 2026-09-12 定稿）：
##   1. 该表自己的缓存（此前推过且确认过）；
##   2. **继承当前（行走）表的帧尺寸** —— 特感的攻击/死亡表画的是同一角色同一比例，
##      只要当前尺寸能整除新表尺寸就直接沿用（"像行走那样的尺寸就没问题"）。
##      T-002 攻击表 1536×576 是"1 角色列"布局（高只有标准的一半角色数，画布高度不变），
##      盲目重推会得出 128×72 把角色水平腰斩；继承行走表的 128×144 则完全正确。
##   3. 兜底：按贴图自动推断（guess_frame_dim，对标准 4 列×2 角色布局可靠）。
func push_action_texture(tex: Texture2D, char_idx: int = 0) -> void:
	if tex == null:
		return
	if _e._action_texture_stack.is_empty():
		_e._action_texture_prev = _e.walk_texture
		# 记住行走表的帧尺寸，restore 时精确还原（不靠重新推断）
		_e._frame_w_prev = _e.sprite_frame_w
		_e._frame_h_prev = _e.sprite_frame_h
	_e._action_texture_stack.append(tex)
	_e.walk_texture = tex
	var cached: Variant = _e._frame_size_by_texture.get(tex)
	var tex_w: int = tex.get_width()
	var tex_h: int = tex.get_height()
	if cached is Vector2i and cached.x > 0 and cached.y > 0 \
			and tex_w % cached.x == 0 and tex_h % cached.y == 0:
		_e.sprite_frame_w = cached.x
		_e.sprite_frame_h = cached.y
	elif _e.sprite_frame_w > 0 and _e.sprite_frame_h > 0 \
			and tex_w % _e.sprite_frame_w == 0 and tex_h % _e.sprite_frame_h == 0:
		# 同角色动作表：沿用行走表帧尺寸（见函数头注释）
		pass
	else:
		_e.sprite_frame_w = 0
		_e.sprite_frame_h = 0
		sync_frame_size_to_texture()
	_e._frame_size_by_texture[tex] = Vector2i(_e.sprite_frame_w, _e.sprite_frame_h)
	refresh_sprite_with_index(char_idx)
	# 联机（A4）：表内动作表切换转发 Client（death_texture 等表外贴图不转发）。
	# Client 侧经 apply_network_action_texture 再次进入本函数，Net.is_host 闸防回环。
	var action_key: String = _e._texture_key_for(tex)
	if action_key != "":
		_e._announce_network_action(action_key, char_idx, true)


## 恢复到行走图（并恢复切换前的角色索引与帧尺寸）。
func restore_walk_texture() -> void:
	if _e._action_texture_stack.is_empty():
		return
	# 联机（A4）：弹出前记下栈顶动作表的 key 并转发恢复（表外贴图 key="" 不转发）。
	var popped_key: String = _e._texture_key_for(_e._action_texture_stack.back())
	_e._action_texture_stack.pop_back()
	if popped_key != "":
		_e._announce_network_action(popped_key, 0, false)
	_e.walk_texture = _e._action_texture_prev if _e._action_texture_stack.is_empty() else _e._action_texture_stack.back()
	if _e._action_texture_stack.is_empty():
		# 精确还原行走表帧尺寸（推断不可靠：多动作表宽度整除方式有歧义）
		_e.sprite_frame_w = _e._frame_w_prev
		_e.sprite_frame_h = _e._frame_h_prev
		## 回到站立帧（中帧）：攻击/突进期间 _anim_step 停在 0（左踏步），
		## 直接恢复会以「迈步」姿势站着，下一拍行走动画才归位（2026-09-15 用户反馈）
		_e._anim_step = 1
		apply_sprite_anchor()
	else:
		# 回到栈顶那张动作表的帧尺寸（用缓存，避免重复推断出错）
		var top: Texture2D = _e._action_texture_stack.back()
		var cached: Variant = _e._frame_size_by_texture.get(top)
		if cached is Vector2i and cached.x > 0 and cached.y > 0:
			_e.sprite_frame_w = cached.x
			_e.sprite_frame_h = cached.y
			apply_sprite_anchor()
		else:
			_e.sprite_frame_w = 0
			_e.sprite_frame_h = 0
			sync_frame_size_to_texture()
	refresh_sprite()


## 当前是否处于附加动作表（供状态机判断是否需要恢复）。
func has_action_texture() -> bool:
	return not _e._action_texture_stack.is_empty()


# ═══════════════════════════════════════
# 死亡外观
# ═══════════════════════════════════════

## ── 死亡表现统一入口（death_texture 接入，2026-09-13）──
##
## 普通僵尸的死亡帧在行走表内（death_char_index 索引），历史路径直接
## refresh_sprite_with_index(death_char_index)。特感（T-002 等）的死亡帧在
## **专用死亡表**（death_texture）里，行走表没有那个角色格 —— 直接索引会越界
## （T-002 death_char_index=3 在行走表只显示错误格子）。
## 统一规则：
##   - death_texture 非空 → push 到死亡表（死亡是终态，不存在 restore 回走表）；
##     帧索引用 death_texture_char_index（-1 回退 death_char_index）。
##   - 爆头死亡对特感同理：headshot_char_index_1/2 是行走表索引，对特感无意义，
##     直接显示死亡表最终帧（放弃两段倒地动画）。
##   - death_texture 为空 → 完全维持旧行为，普通僵尸零影响。
func apply_death_appearance(is_headshot: bool) -> void:
	if _e.death_texture != null:
		push_action_texture(_e.death_texture,
				_e.death_texture_char_index if _e.death_texture_char_index >= 0 else _e.death_char_index)
		_e._death_appearance_applied = true
	elif is_headshot:
		refresh_sprite_with_index(_e.headshot_char_index_1)
	else:
		refresh_sprite_with_index(_e.death_char_index)


# ═══════════════════════════════════════
# 精灵刷新
# ═══════════════════════════════════════

func refresh_sprite() -> void:
	if not _e.sprite or not _e.walk_texture:
		return
	if _e._is_dead:
		return
	_e.sprite.texture = _e.walk_texture
	var frame: int = STAND_FRAME if not _e._moving else WALK_SEQUENCE[_e._anim_step]
	_e._current_char_index = _e.walk_char_index
	draw_sprite_rect(_e.walk_char_index, frame)


func refresh_sprite_with_index(char_idx: int) -> void:
	if not _e.sprite or not _e.walk_texture:
		return
	_e.sprite.texture = _e.walk_texture
	_e._current_char_index = char_idx
	draw_sprite_rect(char_idx, STAND_FRAME)


func draw_sprite_rect(char_idx: int, frame: int) -> void:
	var fw: int = _e.sprite_frame_w if _e.sprite_frame_w > 0 else FRAME_W
	var fh: int = _e.sprite_frame_h if _e.sprite_frame_h > 0 else FRAME_H
	var char_col: int = char_idx % CHARS_PER_ROW
	var char_row: int = char_idx / CHARS_PER_ROW
	var dir_row: int = DIR_ROWS[_e._facing]
	var x: int = char_col * (fw * 3) + frame * fw
	var y: int = char_row * (fh * DIRECTIONS) + dir_row * fh
	_e.sprite.region_rect = Rect2(x, y, fw, fh)


# ═══════════════════════════════════════
# 帧尺寸推断 / 锚点
# ═══════════════════════════════════════

## 按贴图实际尺寸自动推断帧宽高（仅当 sprite_frame_w/h 未显式指定时）。
##
## 推断依据 VX 规格：每角色格 = 3 帧 × 4 方向。整表宽度 = 角色格列数 × 3 × 帧宽。
## 表不一定是标准 4 列（T-002 的三张表是 6 列 × 4 行），因此不能直接除以 12/8。
## 做法：在候选帧宽里找"能整除且格子数合理"的最大值 —— 优先按 CHARS_PER_ROW
## 列推断，失败再逐档回退。
##
## ⚠ 对表列数 ≠ CHARS_PER_ROW 的素材（如 T-002 的 6 列）本函数会算错，
## 必须靠 .tres 的 sprite_frame_w/h 或 _frame_size_by_texture 缓存兜底 ——
## 见 push_action_texture()。
func sync_frame_size_to_texture() -> void:
	if not _e.walk_texture:
		return
	var tex_w: int = int(_e.walk_texture.get_width())
	var tex_h: int = int(_e.walk_texture.get_height())
	if tex_w <= 0 or tex_h <= 0:
		return
	if _e.sprite_frame_w <= 0:
		_e.sprite_frame_w = guess_frame_dim(tex_w, true)
	if _e.sprite_frame_h <= 0:
		_e.sprite_frame_h = guess_frame_dim(tex_h, false)
	if _e.sprite_frame_w <= 0:
		_e.sprite_frame_w = FRAME_W
	if _e.sprite_frame_h <= 0:
		_e.sprite_frame_h = FRAME_H
	apply_sprite_anchor()


## 推断一维帧尺寸。`horizontal` = 是否宽度方向（宽度按 3 帧/格，高度按 4 方向/格）。
## 优先取"整表恰好 CHARS_PER_ROW 个角色格"的解；其次取最大的合法整除数。
func guess_frame_dim(total: int, horizontal: bool) -> int:
	var per_block: int = 3 if horizontal else DIRECTIONS
	var prefer_cols: int = CHARS_PER_ROW if horizontal else 2
	# 首选：整表 = prefer_cols 个角色格（标准布局）
	if total % (per_block * prefer_cols) == 0:
		var v: int = total / (per_block * prefer_cols)
		if v > 0:
			return v
	# 回退：找最大整除数（格数从多到少试），保证格宽 ≥ 8px 避免噪声解
	var best: int = 0
	for blocks in range(prefer_cols, 0, -1):
		if total % (per_block * blocks) == 0:
			var cand: int = total / (per_block * blocks)
			if cand >= 8:
				best = cand
				break
	return best


## 按当前帧高把精灵"脚底"对齐到节点原点上方 16px（与原有 48×64 素材的观感一致）。
## Sprite2D 默认居中绘制，故 position.y = -(half_h - 16)：
##   帧高 64 → -16（原值，保持既有敌人不变）；帧高 144 → -56。
func apply_sprite_anchor() -> void:
	if not _e.sprite:
		return
	var fh: int = _e.sprite_frame_h if _e.sprite_frame_h > 0 else FRAME_H
	_e.sprite.position = Vector2(0, -(fh * 0.5 - 16.0))
