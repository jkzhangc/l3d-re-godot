extends CanvasLayer
## 战斗 HUD — 左上：HP 框 + HP 填充（横缩放）+ 医疗包数量；右上：主/副武器图标
##
## 每个 UI 图都是一个 TextureRect 子节点，可在编辑器里直接拖动改位置。

const MEDKIT_TEXTS: Array[Texture2D] = [
	preload("res://art/Ui/回復薬×０.png"),
	preload("res://art/Ui/回復薬×１.png"),
	preload("res://art/Ui/回復薬×２.png"),
	preload("res://art/Ui/回復薬×３.png"),
	preload("res://art/Ui/回復薬×４.png"),
	preload("res://art/Ui/回復薬×５.png"),
	preload("res://art/Ui/回復薬×６.png"),
	preload("res://art/Ui/回復薬×７.png"),
	preload("res://art/Ui/回復薬×８.png"),
	preload("res://art/Ui/回復薬×９.png"),
	preload("res://art/Ui/回復薬×１０.png"),
	preload("res://art/Ui/回復薬×１１.png"),
	preload("res://art/Ui/回復薬×１２.png"),
	preload("res://art/Ui/回復薬×１３.png"),
	preload("res://art/Ui/回復薬×１４.png"),
	preload("res://art/Ui/回復薬×１５.png"),
]

@onready var hp_frame: TextureRect = $HPFrame
@onready var hp_fill: TextureRect = $HPFill
@onready var medkit_count: TextureRect = $MedkitCount
@onready var primary_icon: TextureRect = $PrimaryWeaponIcon
@onready var secondary_icon: TextureRect = $SecondaryWeaponIcon
@onready var tp_label: GradientLabel = $TPLabel

var _player_ref: CharacterBody2D = null
var _last_tp: int = -1


func _ready() -> void:
	layer = 10
	_player_ref = _find_player()
	_configure_tp_label()
	# HP 填充用 scale.x 横向缩放（配合 HPFill expand_mode=IGNORE_SIZE 自动贴合纹理）
	refresh()


func _process(_delta: float) -> void:
	refresh()


func refresh() -> void:
	_update_hp()
	_update_tp()
	_update_medkit()
	_update_weapons()


func _find_player() -> CharacterBody2D:
	var nodes := get_tree().get_nodes_in_group("player")
	for n: Node in nodes:
		if n is CharacterBody2D:
			return n as CharacterBody2D
	return null


func _update_hp() -> void:
	var hp: float = Global.player_hp
	var max_hp: float = 200.0
	if _player_ref:
		hp = _player_ref.current_hp
		max_hp = _player_ref.max_hp
	var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
	if hp_fill:
		hp_fill.scale = Vector2(ratio, 1.0)


func _configure_tp_label() -> void:
	# TP 数值标签（场景节点 $TPLabel）—— 与伤害数字同款字体/着色器
	# 资源路径/字号/位置在场景里设置；这里只设效果属性（_ready 阶段覆盖 _enter_tree 的 Global 默认值）
	tp_label.use_gradient = true
	tp_label.color_index = 1
	tp_label.color_row = 0
	tp_label.bold = false
	tp_label.shadow = true
	tp_label.shadow_color = Color(0, 0, 0, 0.6)
	tp_label.shadow_offset = Vector2(2, 2)
	tp_label.outline = false


func _update_tp() -> void:
	var tp: int = Global.player_tp
	if tp != _last_tp:
		_last_tp = tp
		tp_label.text = "%d" % tp


func _update_medkit() -> void:
	var n: int = clampi(Global.healing_item_count, 0, MEDKIT_TEXTS.size() - 1)
	if medkit_count:
		medkit_count.texture = MEDKIT_TEXTS[n]
		medkit_count.size = MEDKIT_TEXTS[n].get_size()


func _update_weapons() -> void:
	var primary: WeaponData = Global.get_equipped_weapon("primary")
	var secondary: WeaponData = Global.get_equipped_weapon("secondary")
	if primary_icon:
		if primary and primary.icon:
			primary_icon.texture = primary.icon
			primary_icon.size = primary.icon.get_size()
			primary_icon.visible = true
		else:
			primary_icon.visible = false
	if secondary_icon:
		if secondary and secondary.icon:
			secondary_icon.texture = secondary.icon
			secondary_icon.size = secondary.icon.get_size()
			secondary_icon.visible = true
		else:
			secondary_icon.visible = false
