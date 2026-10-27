@tool
class_name TeleportPoint extends Node2D

## ── 架构定位 ──
## 系统：关卡流程 ｜ 层：玩法（Node2D, @tool）
## 联机：单机直达；联机走安全门协议
## 职责：传送点：靠近按交互键（或触碰，见 interaction_mode）切到目标场景/到达点，
##       隐藏状态下不触发；可选实体碰撞体（不挡 / 只挡敌人 / 挡双方）。
## 依赖：Global.set_pending_arrival、ArrivalResolver、Players（均运行时）
##
## @tool：编辑器里实时显示行走图（同 safe_door / holdout_machine 的预览做法），
## 摆点时即可确认贴图 / 角色索引 / 朝向。遵守项目 @tool 铁律：
##   ① @tool 必须第 1 行；② 编辑器分支绝不碰 autoload（编辑器进程没有
##   Global/Players）与游戏逻辑；③ 预览子节点不设 owner → 不序列化进 .tscn。

## 传送点 — 放在地图上，玩家靠近后按交互键传送到目标场景
## 使用 VX Ace 行走图渲染，支持踏步动画

# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

const PLAYER_RESCAN_INTERVAL: float = 0.5  ## 玩家缺席时的降频重扫间隔（秒）

## ── 互动方式（2026-10-22 用户需求）──
##   CLICK 点击互动：靠近显示提示，按「确定键」传送（原有行为，默认）
##   TOUCH 触碰互动：玩家走进触发区**立即**传送，不需要按键
enum InteractionMode { CLICK = 0, TOUCH = 1 }

## ── 碰撞体阻挡模式（2026-10-22 用户需求：碰撞体是否跟玩家 / 敌人碰撞）──
## ⚠ 引擎层约束（必须先看这里，否则会以为少了一个选项）：
##   玩家物理体 mask = {图块 1, 物体 2, 敌人 8}；敌人物理体 mask = {图块 1, 物体 2, 人物 4, 敌人 8}
##   —— 玩家**能撞的层敌人全都撞得到**，所以「只挡玩家、不挡敌人」在纯静态体上无法表达。
##   于是这里只提供三种真实可达的组合：
##     NONE            层 0   谁都穿过去（默认：只是块招牌）
##     ENEMY_ONLY      层 4   只挡敌人（人物层：敌人在 mask 里，玩家不在）
##     PLAYER_AND_ENEMY 层 2  玩家和敌人都被挡住（物体层：两者 mask 都含它，子弹不挡）
enum BodyBlockMode { NONE = 0, ENEMY_ONLY = 1, PLAYER_AND_ENEMY = 2 }

const TRIGGER_AREA_NODE: String = "TriggerArea"
const TRIGGER_SHAPE_NODE: String = "TriggerShape"
const BLOCKER_NODE: String = "Blocker"
const BLOCKER_SHAPE_NODE: String = "BlockerShape"
## 触发区只认玩家物理体（层 3 = 值 4）；敌人（层 4 = 值 8）不会误触发传送
const PLAYER_LAYER_BIT: int = 4
const BLOCK_LAYER_BOTH: int = 2        ## 物体层：玩家与敌人 mask 都含 → 双方都挡
const BLOCK_LAYER_ENEMY_ONLY: int = 4  ## 人物层：只有敌人 mask 含 → 只挡敌人

# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
@export var target_scene: String = ""              ## 目标场景路径，如 "res://scene/maps/街道.tscn"
@export var target_arrival_id: String = ""          ## 目标场景入口 ID；留空则使用默认 PlayerSpawn
@export var use_target_arrival_position: bool = false ## true 时优先使用下方的目标场景坐标
@export var target_arrival_position: Vector2 = Vector2.ZERO ## 目标场景中的全局坐标
## walk_* 三个导出带 setter：Inspector 里改贴图/索引/朝向即时刷预览，无需重开场景
## （同 GradientLabel font_path_override 的 2026-09-14 修法；加载期 sprite 未建时刷新自动早退）。
@export var walk_texture: Texture2D:                ## 精灵表
	set(v):
		walk_texture = v
		_refresh_sprite()
@export var capture_checkpoint: bool = true        ## 传送前捕获 checkpoint（安全屋出口应为 true）
@export var walk_char_index: int = 0:              ## 精灵表中的角色索引
	set(v):
		walk_char_index = v
		_refresh_sprite()
@export var walk_direction: int = 0:               ## 朝向（0=下, 1=左, 2=右, 3=上）
	set(v):
		walk_direction = v
		_refresh_sprite()

@export_group("踏步动画")
@export var step_frames: Array[int] = [1, 0, 1, 2] ## 踏步帧序列
@export var step_duration: float = 0.25            ## 每帧持续秒数
@export var animated: bool = true                  ## 是否播放踏步动画

## ── 朝向动画（2026-10-27 用户需求）──
## 与踏步动画同款，只是循环的是**朝向**而不是踏步帧；两者**各自独立计时**，
## 同时开 = 一边踏步一边转朝向。默认关 → 固定用 `walk_direction`，老地图零变化。
@export_group("朝向动画")
## 朝向帧序列（0=下 1=左 2=右 3=上），按顺序循环。
@export var facing_frames: Array[int] = [0]
## 每档朝向持续秒数。
@export_range(0.02, 5.0, 0.01) var facing_duration: float = 0.25
## 是否播放朝向动画。关掉 = 固定用 `walk_direction`。
@export var facing_animated: bool = false

@export_group("交互")
@export var interact_label: String = "前往"         ## 交互提示文字
@export var interact_range: float = 48.0           ## 交互触发距离（像素）

@export_group("互动方式")
## CLICK = 靠近按确定键（原有行为）；TOUCH = 玩家走进触发区立刻传送。
## ⚠ 切到 TOUCH 后 `interact_range` 只影响提示文字是否显示，不再决定能否传送。
@export var interaction_mode: InteractionMode = InteractionMode.CLICK:
	set(v):
		interaction_mode = v
		_refresh_interaction_nodes()
## 触碰触发区尺寸（像素，居中于本节点）。是**检测区**不是实体：玩家走进来即触发。
@export var touch_trigger_size: Vector2 = Vector2(48.0, 48.0):
	set(v):
		touch_trigger_size = v
		_refresh_trigger_shape()
## 进图后的迟钝期（秒）：这段时间内不响应触碰。
## ★为什么必须有：触碰模式下若「到达点」恰好落在本传送点的触发区里（同图传送、
##   出口与入口重叠很常见），玩家一到达就会被立刻弹回去 → 无限循环。默认 0.6s 足够
##   让 body_entered 的那一次判定失效（进入事件不会在迟钝期结束后补发）。
@export_range(0.0, 3.0, 0.05) var touch_grace_seconds: float = 0.6

@export_group("碰撞体")
## 是否给传送点一个**实体**碰撞体（见 BodyBlockMode 注释：三种真实可达组合）。
## 与「互动方式」互相独立：点击模式下也可以挡路，触碰模式下也可以完全不挡。
@export var body_block_mode: BodyBlockMode = BodyBlockMode.NONE:
	set(v):
		body_block_mode = v
		_refresh_blocker()
@export var body_size: Vector2 = Vector2(32.0, 32.0):
	set(v):
		body_size = v
		_refresh_blocker()

@export_group("锁门条件")
## 需要持有某个剧情 flag 才能交互（如钥匙 "ch3_got_key"）；空 = 无锁。
## 门本体是图块不是物体的图（第三关矿洞）就用这个：锁的是这个传送点，不是门图块。
@export var required_flag: String = ""
@export var locked_hint: String = "锁住了。需要钥匙。"  ## 无钥匙时的提示文字
@export var show_locked_hint: bool = true          ## 无钥匙时 false=完全隐藏节点，true=显示锁定提示
@export var open_flag_to_set: String = ""          ## 开门成功后置的 flag（如 "ch3_door_opened"，联机自动广播）

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _player_nearby: bool = false
var _player_ref: CharacterBody2D = null
var _step_index: int = 0
var _step_timer: float = 0.0
var _facing_index: int = 0
var _facing_timer: float = 0.0
var _can_interact: bool = false
var _transitioning: bool = false   ## 传送已发起（防同帧/切图空窗期重复触发）
var _player_search_cd: float = 0.0 ## 玩家缺席时的降频重扫倒计时
var _touch_grace_left: float = 0.0 ## 触碰迟钝期剩余（秒）；>0 时不响应触碰

# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	if Engine.is_editor_hint():
		_editor_preview()
		return
	if target_scene.is_empty():
		printerr("[TeleportPoint] target_scene 未设置！")

	if step_frames.is_empty():
		step_frames = [1]

	_ensure_children()
	_refresh_sprite()
	if animated:
		_step_timer = step_duration
	if facing_animated:
		_facing_timer = facing_duration
	## 触碰迟钝期只在**运行时**起算（编辑器分支已提前 return，不会跑进来）
	_touch_grace_left = maxf(touch_grace_seconds, 0.0)

	## 配置自检：触碰模式 + 玩家也被挡住时，触发区必须**大于**阻挡体，否则玩家进不来。
	if interaction_mode == InteractionMode.TOUCH \
			and body_block_mode == BodyBlockMode.PLAYER_AND_ENEMY \
			and body_size.x >= touch_trigger_size.x and body_size.y >= touch_trigger_size.y:
		push_warning("[TeleportPoint] %s：阻挡体(%s)未小于触发区(%s)，玩家碰不到触发区 → 无法触碰传送"
			% [name, str(body_size), str(touch_trigger_size)])


## 编辑器预览（@tool）：只构建显示节点并刷出行走图，不碰任何游戏逻辑 / autoload。
## 子节点不设 owner → 不会被打进 .tscn。
func _editor_preview() -> void:
	if step_frames.is_empty():
		step_frames = [1]
	_step_index = 0
	_facing_index = 0
	_facing_timer = facing_duration
	_ensure_children()
	_refresh_sprite()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		## 编辑器里也播放踏步 / 朝向动画，摆点时即可确认动效
		if animated:
			_step_timer -= delta
			if _step_timer <= 0.0:
				_step_timer += maxf(step_duration, 0.02)
				_step_index = (_step_index + 1) % step_frames.size()
				_refresh_sprite()
		if facing_animated and facing_frames.size() > 1:
			_facing_timer -= delta
			if _facing_timer <= 0.0:
				_facing_timer += maxf(facing_duration, 0.02)
				_facing_index = (_facing_index + 1) % facing_frames.size()
				_refresh_sprite()
		return

	if animated:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(step_duration, 0.02)
			_step_index = (_step_index + 1) % step_frames.size()
			_refresh_sprite()

	# 朝向动画（与踏步**各自独立计时**）
	if facing_animated and facing_frames.size() > 1:
		_facing_timer -= delta
		if _facing_timer <= 0.0:
			_facing_timer += maxf(facing_duration, 0.02)
			_facing_index = (_facing_index + 1) % facing_frames.size()
			_refresh_sprite()

	if _touch_grace_left > 0.0:
		_touch_grace_left = maxf(_touch_grace_left - maxf(delta, 0.0), 0.0)

	# 静态行走图同样需要持续检测玩家是否在范围内。
	_check_player_proximity()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	## 两种互动方式互斥：TOUCH 模式不响应确定键（否则迟钝期内还能手动把自己弹回去）。
	if not should_click_teleport():
		return
	if event.is_action_pressed("确定键"):
		## 与 safe_door 一致走 _unhandled_input 并标记已处理：
		## 菜单等 UI 先消费按键，不会隔着菜单误触发传送。
		get_viewport().set_input_as_handled()
		_do_teleport()


## 点击互动是否可用：模式必须是 CLICK，且可见 / 未在切图 / 玩家在交互范围内。
## （隐藏中的传送点 —— 如防守战结束前生成的 start_hidden 点 —— 按确定键也不传送）
func should_click_teleport() -> bool:
	return interaction_mode == InteractionMode.CLICK \
		and is_visible_in_tree() \
		and not _transitioning \
		and _can_interact


# ═══════════════════════════════════════
# 子节点
# ═══════════════════════════════════════

func _ensure_children() -> void:
	# ── 确保 Sprite2D 子节点存在 ──
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not s:
		s = Sprite2D.new()
		s.name = "Sprite2D"
		s.centered = true
		add_child(s)

	# ── 确保 HintLabel 子节点存在 ──
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		label = Label.new()
		label.name = "HintLabel"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.position = Vector2(-50, -56)
		## 字体统一（2026-09-17）：fusion-pixel + 12 整倍；编辑器进程无 autoload，判空再套。
		## 2026-10-02 用户实测「前进」提示用 24 偏大 → 调回 12（与传送点自身的图标尺度匹配）。
		var hg: Node = get_node_or_null("/root/Global")
		if hg:
			hg.apply_hint_font(label, 12)
		label.size = Vector2(100, 18)
		label.modulate = Color(1, 1, 1, 0.9)
		label.hide()
		add_child(label)

	## 阴影统一走全局参数；运行时路径（编辑器分支不执行，编辑器进程没有 autoload）
	var g: Node = get_node_or_null("/root/Global")
	if g:
		g.apply_text_shadow(label)

	## ── 触碰触发区 + 实体阻挡体（2026-10-22 新增；都按参数自建，旧地图无需手工加节点）──
	_refresh_interaction_nodes()
	_refresh_blocker()


# ═══════════════════════════════════════
# 触碰触发区 / 阻挡体
# ═══════════════════════════════════════

func _ensure_trigger_area() -> Area2D:
	var area: Area2D = get_node_or_null(TRIGGER_AREA_NODE) as Area2D
	if area == null:
		area = Area2D.new()
		area.name = TRIGGER_AREA_NODE
		area.collision_layer = 0                 ## 自己不作为可检测目标
		area.collision_mask = PLAYER_LAYER_BIT   ## 只检测玩家物理体
		area.monitorable = false
		add_child(area)
	if not area.body_entered.is_connected(_on_trigger_body_entered):
		area.body_entered.connect(_on_trigger_body_entered)
	var shape: CollisionShape2D = area.get_node_or_null(TRIGGER_SHAPE_NODE) as CollisionShape2D
	if shape == null:
		shape = CollisionShape2D.new()
		shape.name = TRIGGER_SHAPE_NODE
		shape.shape = RectangleShape2D.new()
		## 编辑器里一眼看出触发区（青色）与原点的关系
		shape.debug_color = Color(0.2, 0.9, 1.0, 0.55)
		area.add_child(shape)
	return area


## 触发区只在触碰模式启用：点击模式下 `monitoring=false`，零额外物理开销。
func _refresh_interaction_nodes() -> void:
	if not is_inside_tree():
		return
	var area: Area2D = _ensure_trigger_area()
	if area == null:
		return
	area.monitoring = interaction_mode == InteractionMode.TOUCH
	_refresh_trigger_shape()


func _refresh_trigger_shape() -> void:
	if not is_inside_tree():
		return
	var area: Area2D = get_node_or_null(TRIGGER_AREA_NODE) as Area2D
	if area == null:
		return
	var shape: CollisionShape2D = area.get_node_or_null(TRIGGER_SHAPE_NODE) as CollisionShape2D
	if shape == null:
		return
	var rect: RectangleShape2D = shape.shape as RectangleShape2D
	if rect == null:
		rect = RectangleShape2D.new()
		shape.shape = rect
	rect.size = Vector2(maxf(touch_trigger_size.x, 4.0), maxf(touch_trigger_size.y, 4.0))


func _ensure_blocker() -> StaticBody2D:
	var body: StaticBody2D = get_node_or_null(BLOCKER_NODE) as StaticBody2D
	if body == null:
		body = StaticBody2D.new()
		body.name = BLOCKER_NODE
		body.collision_mask = 0     ## 静态体不需要探测任何东西
		add_child(body)
	var shape: CollisionShape2D = body.get_node_or_null(BLOCKER_SHAPE_NODE) as CollisionShape2D
	if shape == null:
		shape = CollisionShape2D.new()
		shape.name = BLOCKER_SHAPE_NODE
		shape.shape = RectangleShape2D.new()
		shape.debug_color = Color(1.0, 0.35, 0.35, 0.5)
		body.add_child(shape)
	return body


## 阻挡层映射：见文件头 BodyBlockMode 注释（玩家 mask 是敌人 mask 的子集，故无「只挡玩家」）。
func _refresh_blocker() -> void:
	if not is_inside_tree():
		return
	var body: StaticBody2D = _ensure_blocker()
	if body == null:
		return
	var shape: CollisionShape2D = body.get_node_or_null(BLOCKER_SHAPE_NODE) as CollisionShape2D
	if shape != null:
		var rect: RectangleShape2D = shape.shape as RectangleShape2D
		if rect == null:
			rect = RectangleShape2D.new()
			shape.shape = rect
		rect.size = Vector2(maxf(body_size.x, 4.0), maxf(body_size.y, 4.0))
		shape.disabled = body_block_mode == BodyBlockMode.NONE
	match body_block_mode:
		BodyBlockMode.ENEMY_ONLY:
			body.collision_layer = BLOCK_LAYER_ENEMY_ONLY
		BodyBlockMode.PLAYER_AND_ENEMY:
			body.collision_layer = BLOCK_LAYER_BOTH
		_:
			body.collision_layer = 0


# ═══════════════════════════════════════
# 触碰传送
# ═══════════════════════════════════════

## 玩家物理体走进触发区 → 直接传送（无按键）。
## 与点击路径共用 `_do_teleport()`（锁门判定 / 切图协议 / 防重入都在那里）。
func _on_trigger_body_entered(body: Node2D) -> void:
	if Engine.is_editor_hint():
		return
	if not should_touch_teleport(body):
		return
	_do_teleport()


## 触碰是否应当触发传送（**纯判定**，不切图 —— 便于用例断言，也让上面的处理函数只留两行）。
func should_touch_teleport(body: Node) -> bool:
	if interaction_mode != InteractionMode.TOUCH:
		return false
	if _transitioning or _touch_grace_left > 0.0:
		return false
	if not is_visible_in_tree():
		return false
	if not _is_local_player(body):
		return false
	## 锁着时只显示提示，不传送（提示由 `_update_label` 负责）
	if _is_locked():
		return false
	return true


## 触碰只认**本机操控**的玩家：联机时远端队友走过传送点不应该把本机玩家带走。
func _is_local_player(body: Node) -> bool:
	if body == null or not (body is CharacterBody2D):
		return false
	if not body.has_method("get_weapon_data"):
		return false   ## 与 enemy.gd 同口径的玩家判据
	var players: Node = get_node_or_null("/root/Players")
	if players == null:
		return false
	if _is_online_session():
		if not players.has_method("get_local_entity"):
			return false
		return players.get_local_entity() == body
	return true


func _is_online_session() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and net.is_online_session()


# ═══════════════════════════════════════
# 精灵渲染
# ═══════════════════════════════════════

func _refresh_sprite() -> void:
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not s:
		return

	s.texture = walk_texture
	if not walk_texture:
		## 清空贴图时同步清预览（同 safe_door；否则编辑器里删图残留旧帧）
		s.region_enabled = false
		return
	s.region_enabled = true

	var frame: int = clampi(step_frames[_step_index], 0, 2) if _step_index < step_frames.size() else 0
	var char_col: int = walk_char_index % CHARS_PER_ROW
	var char_row: int = walk_char_index / CHARS_PER_ROW
	var dir_row: int = _current_facing()

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
	s.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


## 当前应显示的朝向：朝向动画开着取序列里的值，否则用 walk_direction。
func _current_facing() -> int:
	if not facing_animated or facing_frames.is_empty():
		return clampi(walk_direction, 0, 3)
	return clampi(facing_frames[_facing_index % facing_frames.size()], 0, 3)


# ═══════════════════════════════════════
# 玩家检测
# ═══════════════════════════════════════

func _check_player_proximity() -> void:
	## 玩家实体缺席（场景加载空窗 / 玩家死亡离场 / reparent 间隙）时降频重扫：
	## 期间保持不可交互，不再每帧扫 group —— 之前「一直找不到玩家节点」的
	## 报错刷屏就发生在这个空窗期。
	if _player_search_cd > 0.0:
		_player_search_cd -= maxf(get_process_delta_time(), 0.0)
		if _player_search_cd > 0.0:
			return

	var player: CharacterBody2D = _find_player()
	if player == null or not is_instance_valid(player):
		_player_nearby = false
		_player_ref = null
		_can_interact = false
		_update_label()
		_player_search_cd = PLAYER_RESCAN_INTERVAL
		return

	_player_search_cd = 0.0
	var dist: float = global_position.distance_to(player.global_position)
	var was_near: bool = _can_interact
	_can_interact = dist <= interact_range
	_player_ref = player
	_player_nearby = _can_interact

	if _can_interact != was_near:
		_update_label()


func _update_label() -> void:
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		return
	if _can_interact:
		if _is_locked():
			## 锁着：按配置显示锁定提示或完全隐藏（不可交互）
			if show_locked_hint:
				label.text = locked_hint
				label.show()
			else:
				label.hide()
		else:
			label.text = interact_label
			label.show()
	else:
		label.hide()


## 锁门判定：required_flag 非空且未置 → 锁定。运行时调用（Global 仅运行时存在）。
func _is_locked() -> bool:
	if required_flag.is_empty():
		return false
	var g: Node = get_node_or_null("/root/Global")
	return g == null or not g.has_quest_flag(required_flag)


# ═══════════════════════════════════════
# 传送
# ═══════════════════════════════════════

func _do_teleport() -> void:
	if _transitioning:
		return  ## 切图是异步的（call_deferred），空窗期内再按确定键不得重复传送
	if _is_locked():
		## 锁着：不传送（提示由 _update_label 负责）
		return
	if target_scene.is_empty():
		printerr("[TeleportPoint] target_scene 为空，无法传送")
		return
	_transitioning = true
	## 开门 flag：单机/Host 立即生效；联机 Client 经 NetworkWorld 转 Host 广播
	if not open_flag_to_set.is_empty():
		var g: Node = get_node_or_null("/root/Global")
		if g:
			g.request_quest_flag(open_flag_to_set, true)

	var net: Node = get_node_or_null("/root/Net")
	if net and net.has_method("is_online_session") and net.is_online_session():
		# 联机时场景由 Host 权威广播；客户端不能自行切图。
		if net.is_host and capture_checkpoint:
			Global.capture_checkpoint()
		if net.has_method("request_scene_change"):
			var arrival_position: Variant = target_arrival_position if use_target_arrival_position else null
			net.request_scene_change(target_scene, target_arrival_id, arrival_position)
		return

	print("[TeleportPoint] 传送至: %s" % target_scene)
	if capture_checkpoint:
		Global.capture_checkpoint()
	var arrival_position: Variant = target_arrival_position if use_target_arrival_position else null
	Global.set_pending_arrival(target_scene, target_arrival_id, arrival_position)
	var tree: SceneTree = get_tree()
	if tree:
		tree.change_scene_to_file.call_deferred(target_scene)


func _find_player() -> CharacterBody2D:
	## 判空兜底：@tool 脚本可能在编辑器里被实例化（不经过 _ready 的运行时分支），
	## 或极端时序下 autoload 查询失败 —— 都不能在这里抛错。
	var players: Node = get_node_or_null("/root/Players")
	if players == null or not players.has_method("nearest_entity_to"):
		return null
	return players.nearest_entity_to(global_position) as CharacterBody2D
