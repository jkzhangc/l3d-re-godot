@tool
class_name HintMarker extends Node2D

## ── 架构定位 ──
## 系统：关卡表现 ｜ 层：玩法（Node2D，关卡作者标记）
## 联机：**纯本地表现**（各端按自己的玩家位置各自判定），零 RPC、零同步
## 职责：在关卡里摆一个「只显示行走图 + 靠近时显示提示文字」的标记。
##       提示样式与医疗箱 / 弹药补给 / 防守战机器的靠近提示**完全一致**
##       （Global.apply_hint_font(12) + 文字阴影 + 绿色），但**没有交互**：
##       不监听按键、不发请求、不改任何玩法状态。
## 依赖：Global.apply_hint_font / Global.apply_text_shadow、Players 查询

## 【和医疗箱的区别】
##   医疗箱 = 行走图 + 靠近提示「治疗自己 [功能键]」+ 按键结算。
##   本节点 = 行走图 + 靠近提示（纯文字），按不按键都没有反应。
##   适合：路牌、血迹、关着的门、远处的 NPC、剧情氛围提示等。
##
## 【只支持行走图】
##   外观固定按 VX Ace 行走图布局取帧（4 方向 × 3 帧 / 角色格），
##   不接任意单图 —— 这是用户 2026-10-19 的明确要求。
##
## 【碰撞（2026-10-27 用户需求）】
##   **默认关闭**（用户拍板）；勾上「碰撞 → 启用碰撞」后生成 32×32 实体碰撞盒，
##   与医疗箱 / 存档点 / 防守战机器同口径：StaticBody2D + `collision_layer=33`
##   （图块层 + 第 6 层「子弹阻挡」）+ `mask=0` —— 玩家 mask=11、敌人 mask=15
##   都含图块层，因此会被挡下。大小 / 位置用 collision_size / collision_offset。
##   ★节点不可见（自身或父级 visible=false）时一律不产生阻挡 ——
##     隐藏的提示纸不该变成隐形墙（例：第一关-结束安全屋的「提示纸」就是隐藏的）。
##
## 【怎么用】
##   ① 在场景里加一个 Node2D（或直接实例化 `object/hint_marker.tscn`）；
##   ② Inspector 里填 `hint_text`，把行走图拖进 `walk_texture`；
##   ③ 需要的话调 `walk_char_index` / `facing` / `stand_frame` / `trigger_range`；
##   ④ 「碰撞」组默认不挡人：路牌 / 告示牌 / 关着的门这类实体要挡人才勾上。
##   编辑器里能直接看到站位与（可选的）文字预览，运行时靠近才显示。

## 行走图规格：每角色格 = 4 方向 × 3 帧，一行 4 个角色格。
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4
## 行走图文件名特殊前缀（`$` = 单角色表）解析，见 script/vx_walk_sheet.gd
const WALK := preload("res://script/vx_walk_sheet.gd")
## 提示文字统一渲染层（不被角色/图块遮挡、不吃夜图暗度），见 script/ui/hint_text_layer.gd
const HINT_LAYER := preload("res://script/ui/hint_text_layer.gd")
const LABEL_WIDTH: float = 360.0
const LABEL_HEIGHT: float = 24.0
## 项目铁律：提示字号 12 的整倍（与医疗箱/补给/防守战机器同口径）。
const FONT_STEP: int = 12
const FONT_DEFAULT: int = 12

## ── 实体碰撞 ──
## 与 `medical_box` / `save_point` / `holdout_machine` 同款：StaticBody2D + 矩形，
## `collision_layer=33`（图块层 + 第 6 层「子弹阻挡」）、`mask=0`。
const COLLISION_NODE: String = "Collision"
const COLLISION_SHAPE_NODE: String = "Shape"
const COLLISION_LAYER: int = 33

@export_group("提示文字")
## 靠近时显示的文字；留空 = 本节点只显示行走图。
@export_multiline var hint_text: String = "提示文字"
## 触发距离（px）：玩家进入这个半径才显示文字。
@export_range(8.0, 240.0, 1.0) var trigger_range: float = 56.0
## 文字颜色（默认与医疗箱/补给同款浅绿）。
@export var hint_color: Color = Color(0.5, 1.0, 0.5, 1.0)
## 字号：自动向上取 12 的整倍（项目 UI 铁律）。
@export_range(12, 48, 12) var font_size: int = FONT_DEFAULT
## 文字块**中心**相对节点原点的偏移（默认在角色头顶）。
@export var hint_offset: Vector2 = Vector2(0, -62)

@export_group("外观 — 行走图")
## 行走图（VX Ace 布局：576×512 / 单帧 48×64 最常见）。留空 = 不画角色。
@export var walk_texture: Texture2D = null
## 角色格索引（0~7；同一张表里第几个角色）。
@export_range(0, 7, 1) var walk_char_index: int = 0
## 朝向：0=下 1=左 2=右 3=上（与 Player/Enemy 的 FaceDir 一致）。
@export_range(0, 3, 1) var facing: int = 0
## 站立帧：0=左踏步 1=中间（不迈步）2=右踏步。
@export_range(0, 2, 1) var stand_frame: int = 1
## 角色相对节点原点的偏移（脚底对齐/放大素材时用）。
@export var sprite_offset: Vector2 = Vector2.ZERO
## 单帧尺寸（px）。标准 48×64；放大素材（如 96×96）按实际填。
## ⚠ 文件名带 `$` 前缀（单角色表）时**本项被忽略**，帧尺寸由图本身推导（图/3×4）。
@export var frame_size: Vector2i = Vector2i(48, 64)
@export var sprite_modulate: Color = Color.WHITE

@export_group("碰撞")
## 是否生成实体碰撞盒。**默认关** = 纯提示（玩家 / 敌人可以从它身上走过去）；
## 路牌 / 告示牌 / 关着的门这类实体要挡人时勾上。
@export var collision_enabled: bool = false
## 碰撞盒尺寸（px）。默认 32×32 = 一格，与医疗箱 / 存档点 / 防守战机器同口径。
@export var collision_size: Vector2 = Vector2(32, 32)
## 碰撞盒相对节点原点的偏移（行走图脚底对齐 / 只挡下半身时用）。
@export var collision_offset: Vector2 = Vector2.ZERO

@export_group("编辑器")
## 编辑器里是否预览提示文字（默认关：防止提示挡住地图）。
@export var preview_in_editor: bool = false

var _sprite: Sprite2D = null
var _label: Label = null


func _ready() -> void:
	_ensure_children()
	_ensure_collision()
	_refresh_visuals()
	set_process(true)


func _process(_delta: float) -> void:
	_ensure_children()
	_ensure_collision()
	_refresh_visuals()
	if Engine.is_editor_hint():
		## 编辑器里只看作者开关，不做距离判定（没有玩家实体）。
		if _label:
			_label.visible = preview_in_editor and not hint_text.strip_edges().is_empty()
		return
	if _label:
		_label.visible = _should_show()


## 是否显示提示：有文字 + 玩家在触发半径内。
## 联机只看**本机操控的实体**（与医疗箱 multiplayer_mode 同口径），单机取最近玩家。
func _should_show() -> bool:
	if hint_text.strip_edges().is_empty():
		return false
	var player: Node2D = _local_player()
	if not is_instance_valid(player):
		return false
	return player.global_position.distance_to(global_position) <= trigger_range


func _local_player() -> Node2D:
	var net: Node = get_node_or_null("/root/Net")
	if net != null and net.has_method("is_online_session") and bool(net.is_online_session()):
		return Players.get_local_entity()
	return Players.nearest_entity_to(global_position)


## 建子节点（幂等）。@tool 下也会跑，但**不设 owner** → 不会被存进场景文件。
func _ensure_children() -> void:
	if _sprite == null or not is_instance_valid(_sprite):
		_sprite = get_node_or_null("Sprite2D") as Sprite2D
	if _sprite == null:
		_sprite = Sprite2D.new()
		_sprite.name = "Sprite2D"
		_sprite.region_enabled = true
		add_child(_sprite)
	if _label == null or not is_instance_valid(_label):
		_label = get_node_or_null("HintLabel") as Label
	if _label == null:
		_label = Label.new()
		_label.name = "HintLabel"
		_label.size = Vector2(LABEL_WIDTH, LABEL_HEIGHT)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label.hide()
		add_child(_label)


## 实体碰撞（可选）。幂等：节点已存在（预置或上一帧建的）时只改参数，不重建。
## 层 / 掩码**无条件**写死（同医疗箱）：作者在 Inspector 里改过也拉回统一口径，
## 否则会出现「这个标记能穿、那个不能穿」。
## ★`collision_enabled=false` 或节点不可见 → `collision_layer=0`（谁都检测不到它），
##   用改层而不是 free/disabled：@tool 下勾回去当帧即恢复，不留重建时机问题。
func _ensure_collision() -> void:
	var body: StaticBody2D = get_node_or_null(COLLISION_NODE) as StaticBody2D
	if body == null:
		body = StaticBody2D.new()
		body.name = COLLISION_NODE
		add_child(body)

	var active: bool = collision_enabled and is_visible_in_tree()
	body.collision_layer = COLLISION_LAYER if active else 0
	body.collision_mask = 0

	var shape_node: CollisionShape2D = body.get_node_or_null(COLLISION_SHAPE_NODE) as CollisionShape2D
	if shape_node == null:
		shape_node = CollisionShape2D.new()
		shape_node.name = COLLISION_SHAPE_NODE
		body.add_child(shape_node)

	## 形状由脚本创建 → 每个实例天然各持一份，两个标记用不同尺寸互不影响
	## （若改成在 .tscn 里预置 SubResource，必须带 `resource_local_to_scene = true`，
	##  否则同场景的多个实例共享同一个矩形，尺寸会互相覆盖）。
	var rect: RectangleShape2D = shape_node.shape as RectangleShape2D
	if rect == null:
		rect = RectangleShape2D.new()
		shape_node.shape = rect
	rect.size = Vector2(maxf(collision_size.x, 1.0), maxf(collision_size.y, 1.0))
	shape_node.position = collision_offset


func _refresh_visuals() -> void:
	if _sprite:
		_sprite.texture = walk_texture
		_sprite.position = sprite_offset
		_sprite.modulate = sprite_modulate
		_sprite.visible = walk_texture != null
		if walk_texture != null:
			_sprite.region_enabled = true
			## `frame_size` 只是**兜底**：文件名带 `$` 时帧尺寸由图本身推导（图/3×4）。
			_sprite.region_rect = WALK.region_rect(walk_texture, walk_char_index,
				facing, stand_frame, frame_size)
	if _label == null:
		return
	_label.text = hint_text
	## Label 的 position 是左上角 → 由「中心偏移」换算，保证文字以节点为中心。
	var label_pos: Vector2 = hint_offset - Vector2(LABEL_WIDTH, LABEL_HEIGHT) * 0.5
	_label.position = label_pos
	_label.add_theme_color_override("font_color", hint_color)
	## ★字体 / 阴影每次刷新都套（医疗箱 2026-10-03 踩过的坑：写在"新建节点"分支里
	## 会让预置节点拿不到样式；本节点虽然自己建子节点，但保持同一规则更稳）。
	var g: Node = get_node_or_null("/root/Global")
	if g:
		g.apply_hint_font(_label, _normalized_font_size())
		g.apply_text_shadow(_label)
	## ★提示文字层（2026-10-28）：搬到提示层（layer=89）这个独立 canvas —— 不被角色/上层图块遮挡，
	## 也不吃夜图 CanvasModulate 的暗度。编辑器里 attach 会自动跳过。
	HINT_LAYER.attach(_label, label_pos)


func _normalized_font_size() -> int:
	var steps: int = maxi(1, int(round(float(font_size) / float(FONT_STEP))))
	return steps * FONT_STEP
