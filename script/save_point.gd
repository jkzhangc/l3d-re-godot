@tool
class_name SavePoint extends Node2D

## ── 架构定位 ──
## 系统：关卡流程 ｜ 层：玩法（Node2D, @tool）
## 联机：★禁用 —— 联机会话里完全隐藏且不响应（存档是本机单人进度）
## 职责：手动存档点：用 VX Ace 行走图渲染（支持踏步动画），玩家靠近按**功能键**
##       打开存档点菜单（存档 / 选择难度）。
## 依赖：Global.key_hint、ui/save_point_menu（均运行时）
##
## @tool：编辑器里实时显示行走图（同 teleport_point / safe_door / holdout_machine 的预览做法），
## 摆点时即可确认贴图 / 角色索引 / 朝向 / 踏步帧。遵守项目 @tool 铁律：
##   ① @tool 必须第 1 行；② 编辑器分支绝不碰 autoload（编辑器进程没有 Global/Players）
##   与游戏逻辑；③ 预览子节点不设 owner → 不序列化进 .tscn。

# ═══════════════════════════════════════
# 精灵帧常量（VX Ace 行走图：4 方向 × 3 帧）
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

const SAVE_POINT_MENU := preload("res://script/ui/save_point_menu.gd")

const PLAYER_RESCAN_INTERVAL: float = 0.5  ## 玩家缺席时的降频重扫间隔（秒）

## ── 实体碰撞（2026-10-04 用户需求：跟医疗箱那样）──
## 存档点是"一台机器"，玩家不该能从它身上穿过去。与 `medical_box` / `holdout_machine`
## 完全同款：StaticBody2D + 32×32 方形，`collision_layer=33`（图块层 + 第 6 层）、`mask=0`
## —— 玩家 collision_mask=15 含图块层，因此会被挡下。
const COLLISION_NODE: String = "Collision"
const COLLISION_SHAPE_NODE: String = "Shape"
const COLLISION_LAYER: int = 33
const COLLISION_SIZE: Vector2 = Vector2(32, 32)

# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
## walk_* 三个导出带 setter：Inspector 里改贴图/索引/朝向即时刷预览，无需重开场景。
@export var walk_texture: Texture2D:
	set(v):
		walk_texture = v
		_refresh_sprite()
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

@export_group("交互")
@export var interact_label: String = "存档"         ## 交互提示文字
@export var interact_range: float = 48.0           ## 交互触发距离（像素）
@export var pause_on_open: bool = true             ## 打开菜单时暂停游戏（回归用例设 false）

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _can_interact: bool = false
var _step_index: int = 0
var _step_timer: float = 0.0
var _menu: Node = null
var _player_search_cd: float = 0.0


# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	if Engine.is_editor_hint():
		_editor_preview()
		return

	if step_frames.is_empty():
		step_frames = [1]

	## ★联机禁用：会话里直接隐藏 + 关掉处理，不干扰多人玩法。
	if _online():
		visible = false
		set_process(false)
		set_process_input(false)
		return

	_ensure_children()
	_ensure_collision()
	_refresh_sprite()
	if animated:
		_step_timer = step_duration


func _editor_preview() -> void:
	if step_frames.is_empty():
		step_frames = [1]
	_step_index = 0
	_ensure_children()
	_ensure_collision()
	_refresh_sprite()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if animated:
			_step_timer -= delta
			if _step_timer <= 0.0:
				_step_timer += maxf(step_duration, 0.02)
				_step_index = (_step_index + 1) % step_frames.size()
				_refresh_sprite()
		return

	if animated:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(step_duration, 0.02)
			_step_index = (_step_index + 1) % step_frames.size()
			_refresh_sprite()

	_check_player_proximity()

	## ★项目铁律：互动键走 `_process` **轮询**（`_unhandled_input` 会被别的节点 consume
	## → 静默失效；medical_box / holdout_machine 同款）。打开菜单即暂停 → 本函数随之停，
	## 天然防同帧双触发。
	if _can_interact and _menu == null and not get_tree().paused:
		if Input.is_action_just_pressed("功能键"):
			_open_menu()


# ═══════════════════════════════════════
# 子节点
# ═══════════════════════════════════════

func _ensure_children() -> void:
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not s:
		s = Sprite2D.new()
		s.name = "Sprite2D"
		s.centered = true
		add_child(s)

	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		label = Label.new()
		label.name = "HintLabel"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.position = Vector2(-60, -56)
		var hg: Node = get_node_or_null("/root/Global")
		if hg and hg.has_method("apply_hint_font"):
			hg.apply_hint_font(label, 12)
		label.size = Vector2(120, 18)
		label.modulate = Color(1, 1, 1, 0.9)
		label.hide()
		add_child(label)

	## ★阴影/字体套用**不能**写在「新建分支」里（项目第三次踩坑铁律）：
	## 无论 HintLabel 是预置还是新建，这里都要（幂等地）套一遍。
	var g: Node = get_node_or_null("/root/Global")
	if g:
		if g.has_method("apply_hint_font"):
			g.apply_hint_font(label, 12)
		if g.has_method("apply_text_shadow"):
			g.apply_text_shadow(label)


## 实体碰撞（与 medical_box / holdout_machine 同款）。幂等：`save_point.tscn` 已预置
## 同名节点时只是补全缺失的形状，不会重建（预置节点优先，改不动导出参数）。
func _ensure_collision() -> void:
	var body: StaticBody2D = get_node_or_null(COLLISION_NODE) as StaticBody2D
	if not body:
		body = StaticBody2D.new()
		body.name = COLLISION_NODE
		add_child(body)
	## ★层/掩码对「预置或新建」都要（幂等地）写死：预置节点若在 Inspector 里被改过，
	## 也必须回到与医疗箱一致的口径，否则会出现"这个存档点能穿、那个不能穿"。
	body.collision_layer = COLLISION_LAYER
	body.collision_mask = 0

	var shape_node: CollisionShape2D = body.get_node_or_null(COLLISION_SHAPE_NODE) as CollisionShape2D
	if not shape_node:
		shape_node = CollisionShape2D.new()
		shape_node.name = COLLISION_SHAPE_NODE
		body.add_child(shape_node)
	if not shape_node.shape:
		var rect := RectangleShape2D.new()
		rect.size = COLLISION_SIZE
		shape_node.shape = rect


# ═══════════════════════════════════════
# 精灵渲染
# ═══════════════════════════════════════

func _refresh_sprite() -> void:
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not s:
		return
	s.texture = walk_texture
	if not walk_texture:
		s.region_enabled = false
		return
	s.region_enabled = true

	var frame: int = clampi(step_frames[_step_index], 0, 2) if _step_index < step_frames.size() else 0
	var char_col: int = walk_char_index % CHARS_PER_ROW
	var char_row: int = walk_char_index / CHARS_PER_ROW
	var dir_row: int = walk_direction

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
	s.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


# ═══════════════════════════════════════
# 玩家检测
# ═══════════════════════════════════════

func _check_player_proximity() -> void:
	if _player_search_cd > 0.0:
		_player_search_cd -= maxf(get_process_delta_time(), 0.0)
		if _player_search_cd > 0.0:
			return

	var player: CharacterBody2D = _find_player()
	if player == null or not is_instance_valid(player):
		_can_interact = false
		_update_label()
		_player_search_cd = PLAYER_RESCAN_INTERVAL
		return

	_player_search_cd = 0.0
	var dist: float = global_position.distance_to(player.global_position)
	var was: bool = _can_interact
	_can_interact = dist <= interact_range
	if _can_interact != was:
		_update_label()


func _update_label() -> void:
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		return
	if _can_interact:
		label.text = "%s  [%s]" % [interact_label, Global.key_hint(&"功能键")]
		label.show()
	else:
		label.hide()


func _find_player() -> CharacterBody2D:
	var players: Node = get_node_or_null("/root/Players")
	if players == null or not players.has_method("nearest_entity_to"):
		return null
	return players.nearest_entity_to(global_position) as CharacterBody2D


# ═══════════════════════════════════════
# 菜单
# ═══════════════════════════════════════

func _open_menu() -> void:
	_menu = SAVE_POINT_MENU.new()
	_menu.save_position = global_position
	_menu.pause_game = pause_on_open
	_menu.connect("closed", _on_menu_closed)
	add_child(_menu)
	## 打开瞬间清提示（菜单会铺遮罩，提示不必再留）
	var label: Label = get_node_or_null("HintLabel") as Label
	if label:
		label.hide()


func _on_menu_closed() -> void:
	_menu = null
	## 关菜单后重新判定（玩家可能已走开）
	_player_search_cd = 0.0
	_can_interact = false


func _online() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.has_method("is_online_session") and bool(net.is_online_session())
