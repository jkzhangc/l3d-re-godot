extends CanvasLayer
## 战斗 HUD — HP 血条（左上）+ 5 槽位横排快捷栏（右下角）+ 队友血条。
##
## 在 scene/main.tscn 中作为子节点添加（layer=10）。
## 联机模式：从 Player 节点读取 current_hp（已通过 _sync_hp RPC 同步），不使用 Global.player_hp。
##
## 布局（1280×960）：
##   ┌──────────────────────────────────────┐
##   │ ♥ [████████░░░░] 150/200            │ ← HP 血条（左上）
##   │ 队友1 [████░░] 80/200               │ ← 队友血条（联机模式）
##   │ 队友2 [██████] 120/200              │
##   │                                      │
##   │           ┌────┬────┬────┬────┬────┐ │
##   │           │ 1  │ 2  │ 3  │ 4  │ 5  │ │ ← 槽位栏（右下角横排）
##   │           └────┴────┴────┴────┴────┘ │
##   └──────────────────────────────────────┘


# ═══════════════════════════════════════
# 常量
# ═══════════════════════════════════════

const HP_BAR_WIDTH: int = 160
const HP_BAR_HEIGHT: int = 20
const SLOT_W: int = 104    ## 单个槽位宽度（与 hud_slot.gd 一致）
const SLOT_H: int = 52     ## 单个槽位高度（与 hud_slot.gd 一致）
const SLOT_GAP: int = 3    ## 槽位间距
const SLOT_COUNT: int = 5
const LAYER_INDEX: int = 10

const VIEW_W: int = 1280
const VIEW_H: int = 960

const HP_FRAME_TEX := preload("res://art/Ui/ＨＰバー.png")
const HP_FILL_TEX  := preload("res://art/Ui/ＨＰメーター.png")
const SLOT_SCRIPT  := preload("res://script/ui/hud_slot.gd")

## 队友迷你血条尺寸
const TEAM_BAR_WIDTH: int = 130
const TEAM_BAR_HEIGHT: int = 12
const TEAM_BAR_GAP: int = 2
const MAX_TEAMMATE_BARS: int = 3


# ═══════════════════════════════════════
# 可见性控制
# ═══════════════════════════════════════

@export_group("Visibility")
@export var hud_visible: bool = true:
	set(v):
		hud_visible = v
		_apply_visibility()
@export var hp_bar_visible: bool = true:
	set(v):
		hp_bar_visible = v
		_apply_visibility()
@export var slot_bar_visible: bool = true:
	set(v):
		slot_bar_visible = v
		_apply_visibility()


@export_group("Layout")
## HP 血条位置（屏幕像素坐标，左上角）
@export var hp_bar_pos: Vector2 = Vector2(6, 6):
	set(v):
		hp_bar_pos = v
		if _hp_row:
			_hp_row.position = v
## HP 数值标签屏幕坐标（直接挂 CanvasLayer，不受布局容器限制）
@export var hp_label_offset: Vector2 = Vector2(168, 8):
	set(v):
		hp_label_offset = v
		if _hp_label:
			_hp_label.position = v
## HP 数值标签是否可见
@export var hp_label_visible: bool = true:
	set(v):
		hp_label_visible = v
		if _hp_label:
			_hp_label.visible = v
## 槽位栏位置（屏幕像素坐标，左上角）。设 (0,0) 则自动右下角
@export var slot_bar_pos: Vector2 = Vector2.ZERO:
	set(v):
		slot_bar_pos = v
		_reposition_slot_bar()


# ═══════════════════════════════════════
# 节点引用
# ═══════════════════════════════════════

var _hp_row: HBoxContainer = null
var _hp_bar_fill: TextureRect = null
var _hp_label: Label = null
var _team_label: Label = null
var _slot_bg: ColorRect = null
var _slot_hbox: HBoxContainer = null
var _slots: Array[Control] = []

var _player_ref: CharacterBody2D = null

## 队友血条节点（联机模式动态创建）
var _teammate_bar_container: Control = null
var _teammate_bars: Array[Dictionary] = []  ## [{name_label, bar_fill, frame, hp_label}]


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════

func _ready() -> void:
	layer = LAYER_INDEX
	_player_ref = _find_player()
	_build_hp_bar()
	_build_slot_bar()
	_apply_visibility()


func _find_player() -> CharacterBody2D:
	## 查找本地玩家节点（联机模式：匹配 authority；单机模式：第一个找到的）
	var tree := get_tree()
	if not tree:
		return null
	var all_players: Array[Node] = []
	_find_all_players(tree.root, all_players)

	if all_players.is_empty():
		return null

	# 联机模式：返回 authority 匹配的节点
	if Lobby.is_online():
		var my_id: int = multiplayer.get_unique_id()
		for p: Node in all_players:
			if p.get_multiplayer_authority() == my_id:
				return p as CharacterBody2D
		# 回退（Host 的本地玩家）
		return all_players[0] as CharacterBody2D

	# 单机模式：返回第一个
	return all_players[0] as CharacterBody2D


func _find_all_players(node: Node, result: Array[Node]) -> void:
	if node is CharacterBody2D and node.has_method("get_weapon_data"):
		result.append(node)
	for child: Node in node.get_children():
		_find_all_players(child, result)


# ═══════════════════════════════════════
# HP 血条（左上角）
# ═══════════════════════════════════════

func _build_hp_bar() -> void:
	_hp_row = HBoxContainer.new()
	_hp_row.name = "HPRow"
	_hp_row.position = hp_bar_pos
	_hp_row.add_theme_constant_override("separation", 3)
	add_child(_hp_row)

	#var heart := Label.new()
	#heart.text = "♥"
	#heart.add_theme_color_override("font_color", Color(1, 0.2, 0.2, 0.9))
	#heart.add_theme_font_size_override("font_size", 13)
	#heart.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	#_hp_row.add_child(heart)

	var bar_ctrl := Control.new()
	bar_ctrl.name = "HPBarContainer"
	bar_ctrl.custom_minimum_size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	bar_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_row.add_child(bar_ctrl)

	_hp_bar_fill = TextureRect.new()
	_hp_bar_fill.name = "HPFill"
	_hp_bar_fill.texture = HP_FILL_TEX
	_hp_bar_fill.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	_hp_bar_fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_hp_bar_fill.stretch_mode = TextureRect.STRETCH_KEEP
	bar_ctrl.add_child(_hp_bar_fill)

	var frame := TextureRect.new()
	frame.name = "HPFrame"
	frame.texture = HP_FRAME_TEX
	frame.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_ctrl.add_child(frame)

	_hp_label = Label.new()
	_hp_label.name = "HPLabel"
	_hp_label.position = hp_label_offset
	_hp_label.visible = hp_label_visible
	_hp_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_hp_label.add_theme_font_size_override("font_size", 14)
	_hp_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_hp_label.add_theme_constant_override("outline_size", 2)
	add_child(_hp_label)  ## 直接加到 CanvasLayer，不受 HBox 布局控制

	# 队伍标签（HP 条下方）
	_team_label = Label.new()
	_team_label.name = "TeamLabel"
	_team_label.position = Vector2(hp_bar_pos.x, hp_bar_pos.y + HP_BAR_HEIGHT + 4)
	_team_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.9, 0.8))
	_team_label.add_theme_font_size_override("font_size", 12)
	_team_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_team_label.add_theme_constant_override("outline_size", 1)
	add_child(_team_label)

	# 队友血条容器（联机模式动态填充）
	_teammate_bar_container = Control.new()
	_teammate_bar_container.name = "TeammateBars"
	_teammate_bar_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_teammate_bar_container)


# ═══════════════════════════════════════
# 槽位栏（右下角横排）
# ═══════════════════════════════════════

func _build_slot_bar() -> void:
	var bar_w: int = SLOT_COUNT * SLOT_W + (SLOT_COUNT - 1) * SLOT_GAP + 8
	var bar_h: int = SLOT_H + 8

	# 位置：用 slot_bar_pos，若为零则自动右下角
	var bar_x: int
	var bar_y: int
	if slot_bar_pos == Vector2.ZERO:
		bar_x = VIEW_W - bar_w - 4
		bar_y = VIEW_H - bar_h - 4  # 右下角
	else:
		bar_x = int(slot_bar_pos.x)
		bar_y = int(slot_bar_pos.y)

	_slot_bg = ColorRect.new()
	_slot_bg.name = "SlotBarBG"
	_slot_bg.color = Color(0.04, 0.04, 0.07, 0.7)
	_slot_bg.size = Vector2(bar_w, bar_h)
	_slot_bg.position = Vector2(bar_x, bar_y)
	add_child(_slot_bg)

	_slot_hbox = HBoxContainer.new()
	_slot_hbox.name = "SlotHBox"
	_slot_hbox.position = Vector2(bar_x + 4, bar_y + 4)
	_slot_hbox.add_theme_constant_override("separation", SLOT_GAP)
	add_child(_slot_hbox)

	var slot_configs := [
		{ "type": "weapon",   "key": "primary"   },
		{ "type": "weapon",   "key": "secondary" },
		{ "type": "heal",     "key": ""           },
		{ "type": "support",  "key": ""           },
		{ "type": "throwable","key": ""           },
	]

	for i: int in range(SLOT_COUNT):
		var slot := Panel.new()
		slot.name = "Slot%d" % (i + 1)
		slot.set_script(SLOT_SCRIPT)
		slot.slot_index = i
		slot.slot_type = slot_configs[i]["type"]
		slot.slot_key = slot_configs[i]["key"]
		_slot_hbox.add_child(slot)
		_slots.append(slot)


# ═══════════════════════════════════════
# 每帧更新
# ═══════════════════════════════════════

func _process(_delta: float) -> void:
	if not hud_visible:
		return
	if hp_bar_visible:
		_update_hp_bar()
		_update_teammate_bars()
	if slot_bar_visible:
		_update_slots()


func _apply_visibility() -> void:
	if _hp_row:
		_hp_row.visible = hud_visible and hp_bar_visible
	if _slot_bg:
		_slot_bg.visible = hud_visible and slot_bar_visible
	if _slot_hbox:
		_slot_hbox.visible = hud_visible and slot_bar_visible
	if _teammate_bar_container:
		_teammate_bar_container.visible = hud_visible and hp_bar_visible


func _reposition_slot_bar() -> void:
	if not _slot_bg or not _slot_hbox:
		return

	var bar_x: int
	var bar_y: int
	if slot_bar_pos == Vector2.ZERO:
		var bar_w: int = SLOT_COUNT * SLOT_W + (SLOT_COUNT - 1) * SLOT_GAP + 8
		var bar_h: int = SLOT_H + 8
		bar_x = VIEW_W - bar_w - 4
		bar_y = VIEW_H - bar_h - 4  # 右下角
	else:
		bar_x = int(slot_bar_pos.x)
		bar_y = int(slot_bar_pos.y)

	_slot_bg.position = Vector2(bar_x, bar_y)
	_slot_hbox.position = Vector2(bar_x + 4, bar_y + 4)


func _update_hp_bar() -> void:
	if not _hp_bar_fill or not _hp_label:
		return

	# 优先从 Player 节点读取 current_hp（联机模式通过 _sync_hp RPC 同步）
	# 回退到 Global.player_hp（单机模式 / Host 本地）
	var hp: float = Global.player_hp
	var max_hp: float = 200.0
	if _player_ref and _player_ref.has_method("get_weapon_data"):
		max_hp = _player_ref.max_hp
		# 联机模式：从节点读取（已通过 RPC 同步），单机模式也是实时值
		hp = _player_ref.current_hp

	var ratio: float = clamp(hp / max_hp, 0.0, 1.0)
	_hp_bar_fill.size.x = floor(float(HP_BAR_WIDTH) * ratio)
	_hp_label.text = "%d/%d" % [int(hp), int(max_hp)]
	# 更新队伍标签
	if _team_label and Global.get_team_size() > 1:
		var cd: CharacterData = Global.player_character as CharacterData
		if cd:
			_team_label.text = "%s (%d/%d)" % [cd.character_name, Global.current_team_index + 1, Global.get_team_size()]
			_team_label.visible = true
		else:
			_team_label.visible = false
	elif _team_label:
		_team_label.visible = false

	if ratio < 0.3:
		_hp_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3, 0.9))
	else:
		_hp_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))


## 队友迷你血条（联机模式）
func _update_teammate_bars() -> void:
	if not Lobby.is_online():
		if _teammate_bar_container:
			_teammate_bar_container.visible = false
		return

	var tree := get_tree()
	if not tree:
		return

	# 收集所有 Player 节点
	var all_players: Array[Node] = tree.get_nodes_in_group("player")
	var my_id: int = multiplayer.get_unique_id()
	var teammates: Array[Node] = []
	for p: Node in all_players:
		if not is_instance_valid(p):
			continue
		var auth: int = p.get_multiplayer_authority()
		if auth != my_id:
			teammates.append(p)

	if teammates.is_empty():
		if _teammate_bar_container:
			_teammate_bar_container.visible = false
		return

	if _teammate_bar_container:
		_teammate_bar_container.visible = true

	# 确保队友血条节点足够
	while _teammate_bars.size() < teammates.size() and _teammate_bars.size() < MAX_TEAMMATE_BARS:
		_create_teammate_bar(_teammate_bars.size())

	# 更新每个队友血条
	var start_y: float = hp_bar_pos.y + HP_BAR_HEIGHT + 28  # 队伍标签之下
	for i: int in range(min(teammates.size(), _teammate_bars.size())):
		var p: Node = teammates[i]
		var bar_data: Dictionary = _teammate_bars[i]
		var y: float = start_y + i * (TEAM_BAR_HEIGHT + TEAM_BAR_GAP + 16)

		# 队友名字
		var name_str: String = p.name
		# 尝试从 Lobby.players 获取玩家名字
		var auth: int = p.get_multiplayer_authority()
		if Lobby.players.has(auth):
			var info: Dictionary = Lobby.players[auth]
			if info.has("name"):
				name_str = info["name"]
		bar_data["name_label"].text = name_str
		bar_data["name_label"].position = Vector2(hp_bar_pos.x, y)

		# HP 血条
		var hp: float = p.get("current_hp")
		var max_hp: float = p.get("max_hp") if p.get("max_hp") != null else 200.0
		var ratio: float = clamp(hp / max_hp, 0.0, 1.0)

		var bar_x: float = hp_bar_pos.x + 60  # 名字之后
		bar_data["bar_fill"].position = Vector2(bar_x, y + 2)
		bar_data["bar_fill"].size.x = floor(float(TEAM_BAR_WIDTH) * ratio)
		bar_data["bar_frame"].position = Vector2(bar_x, y + 2)

		# HP 数值
		bar_data["hp_label"].text = "%d" % int(hp)
		bar_data["hp_label"].position = Vector2(bar_x + TEAM_BAR_WIDTH + 4, y)
		if ratio < 0.3:
			bar_data["hp_label"].add_theme_color_override("font_color", Color(1, 0.3, 0.3, 0.9))
		else:
			bar_data["hp_label"].add_theme_color_override("font_color", Color(0.7, 1.0, 0.7, 0.8))


func _create_teammate_bar(index: int) -> void:
	## 创建一个队友迷你血条
	if not _teammate_bar_container:
		return

	var bar_data: Dictionary = {}

	# 名字标签
	var name_label := Label.new()
	name_label.name = "TeammateName%d" % index
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.9, 0.8))
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	name_label.add_theme_constant_override("outline_size", 1)
	_teammate_bar_container.add_child(name_label)
	bar_data["name_label"] = name_label

	# 血条填充
	var bar_fill := TextureRect.new()
	bar_fill.name = "TeammateFill%d" % index
	bar_fill.texture = HP_FILL_TEX
	bar_fill.size = Vector2(TEAM_BAR_WIDTH, TEAM_BAR_HEIGHT)
	bar_fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar_fill.stretch_mode = TextureRect.STRETCH_KEEP
	_teammate_bar_container.add_child(bar_fill)
	bar_data["bar_fill"] = bar_fill

	# 血条边框
	var bar_frame := TextureRect.new()
	bar_frame.name = "TeammateFrame%d" % index
	bar_frame.texture = HP_FRAME_TEX
	bar_frame.size = Vector2(TEAM_BAR_WIDTH, TEAM_BAR_HEIGHT)
	bar_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar_frame.stretch_mode = TextureRect.STRETCH_KEEP
	bar_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_teammate_bar_container.add_child(bar_frame)
	bar_data["bar_frame"] = bar_frame

	# HP 数值标签
	var hp_label := Label.new()
	hp_label.name = "TeammateHP%d" % index
	hp_label.add_theme_font_size_override("font_size", 11)
	hp_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7, 0.8))
	hp_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	hp_label.add_theme_constant_override("outline_size", 1)
	_teammate_bar_container.add_child(hp_label)
	bar_data["hp_label"] = hp_label

	_teammate_bars.append(bar_data)


func _update_slots() -> void:
	var active_idx: int = -1
	match Global.active_weapon_slot:
		"primary":   active_idx = 0
		"secondary": active_idx = 1

	for i: int in range(_slots.size()):
		var slot := _slots[i]
		if slot.has_method("refresh"):
			slot.refresh(i == active_idx)
