extends CanvasLayer
## 战斗 HUD — HP 血条（左上）+ 5 槽位横排快捷栏（右下角）。
##
## 在 scene/main.tscn 中作为子节点添加（layer=10）。
## 每帧从 Global autoload 读取数据刷新显示。
##
## 布局（1280×960）：
##   ┌──────────────────────────────────────┐
##   │ ♥ [████████░░░░] 150/200            │ ← HP 血条（左上）
##   │                                      │
##   │                                      │
##   │           ┌────┬────┬────┬────┬────┐ │
##   │           │ 1  │ 2  │ 3  │ 4  │ 5  │ │ ← 槽位栏（右下角横排）
##   │           └────┴────┴────┴────┴────┘ │
##   └──────────────────────────────────────┘


# ═══════════════════════════════════════
# 常量
# ═══════════════════════════════════════

const HP_BAR_WIDTH: int = 100
const HP_BAR_HEIGHT: int = 14
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
@export var hp_label_offset: Vector2 = Vector2(108, 7):
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
	var tree := get_tree()
	if tree:
		for node: Node in tree.root.get_children():
			var found := _find_player_recursive(node)
			if found:
				return found
	return null


func _find_player_recursive(node: Node) -> CharacterBody2D:
	if node is CharacterBody2D and node.has_method("get_weapon_data"):
		return node as CharacterBody2D
	for child: Node in node.get_children():
		var found := _find_player_recursive(child)
		if found:
			return found
	return null


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
	_hp_label.add_theme_font_size_override("font_size", 10)
	_hp_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_hp_label.add_theme_constant_override("outline_size", 2)
	add_child(_hp_label)  ## 直接加到 CanvasLayer，不受 HBox 布局控制

	# 队伍标签（HP 条下方）
	_team_label = Label.new()
	_team_label.name = "TeamLabel"
	_team_label.position = Vector2(hp_bar_pos.x, hp_bar_pos.y + HP_BAR_HEIGHT + 4)
	_team_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.9, 0.8))
	_team_label.add_theme_font_size_override("font_size", 10)
	_team_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_team_label.add_theme_constant_override("outline_size", 1)
	add_child(_team_label)


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
	if slot_bar_visible:
		_update_slots()


func _apply_visibility() -> void:
	if _hp_row:
		_hp_row.visible = hud_visible and hp_bar_visible
	if _slot_bg:
		_slot_bg.visible = hud_visible and slot_bar_visible
	if _slot_hbox:
		_slot_hbox.visible = hud_visible and slot_bar_visible


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

	var hp: float = Global.player_hp
	var max_hp: float = 200.0
	if _player_ref and _player_ref.has_method("get_weapon_data"):
		max_hp = _player_ref.max_hp

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


func _update_slots() -> void:
	var active_idx: int = -1
	match Global.active_weapon_slot:
		"primary":   active_idx = 0
		"secondary": active_idx = 1

	for i: int in range(_slots.size()):
		var slot := _slots[i]
		if slot.has_method("refresh"):
			slot.refresh(i == active_idx)
