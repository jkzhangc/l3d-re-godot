extends Node2D

## ── 架构定位 ──
## 系统：联机 HUD ｜ 层：表现（Node2D）
## 联机：Host 与 Client 同套，数据源为宿主 HP
## 职责：联机玩家头顶名牌：座位编号 + 昵称 + 正式素材血条。
## 依赖：art/Ui 血条素材、Player.current_hp

## 联机玩家头顶名牌：座位编号（1P/2P…）+ 昵称 + 正式 HUD 血条。
##
## 血条使用 art/Ui 的正式素材（ＨＰバー=外框 / ＨＰメーター=黄色填充），
## 由 NetworkWorld 在联机玩家实体注册时挂载；Host 与 Client 都用同一套，
## 数据源都是宿主 Player 节点的 current_hp（Host 本地权威 / Client 来自快照）。
## 倒地/真死亡时宿主会切换躺地表现，血条随 HP 归零而清空，名牌保留方便寻找队友。

const BAR_TEXTURE := preload("res://art/Ui/ＨＰバー.png")
const METER_TEXTURE := preload("res://art/Ui/ＨＰメーター.png")

## 玩家精灵帧为 48×64、原点在脚底（Sprite2D 位于 y=-16），头顶约在 y=-48。
const BAR_OFFSET := Vector2(-32.0, -56.0)
const LABEL_OFFSET := Vector2(-48.0, -74.0)

var _label: Label
var _hp_bar: TextureProgressBar
## set_nameplate_info 可能在 _ready 前被调用（挂载同帧配置），先暂存再应用。
var _seat_index := 0
var _display_name := ""


func _ready() -> void:
	z_index = 30
	_hp_bar = TextureProgressBar.new()
	_hp_bar.texture_under = BAR_TEXTURE
	_hp_bar.texture_progress = METER_TEXTURE
	_hp_bar.min_value = 0.0
	_hp_bar.max_value = 100.0
	_hp_bar.value = 100.0
	_hp_bar.position = BAR_OFFSET
	_hp_bar.scale = Vector2(0.5, 0.5)
	_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hp_bar)

	_label = Label.new()
	_label.position = LABEL_OFFSET
	_label.size = Vector2(96.0, 16.0)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 9)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", 3)
	## 阴影统一走 Global（2026-09-15 全文字阴影审计：名牌原先只有描边）
	var g: Node = get_node_or_null("/root/Global")
	if g and g.has_method("apply_text_shadow"):
		g.apply_text_shadow(_label)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	_apply_label_text()


## 座位编号从 1 开始显示；昵称可空（单人调试挂载时只显示编号）。
func set_nameplate_info(seat_index: int, display_name: String) -> void:
	_seat_index = seat_index
	_display_name = display_name
	_apply_label_text()


func _apply_label_text() -> void:
	if not _label:
		return
	var seat_number := clampi(_seat_index + 1, 1, 9)
	_label.text = "%dP %s" % [seat_number, _display_name] if not _display_name.is_empty() else "%dP" % seat_number


func _process(_delta: float) -> void:
	if not _hp_bar:
		return
	var player := get_parent() as Node
	if player == null or not is_instance_valid(player):
		return
	var hp: Variant = player.get("current_hp")
	var max_hp: Variant = player.get("max_hp")
	if hp == null or max_hp == null:
		return
	var ratio := clampf(float(hp) / maxf(float(max_hp), 1.0), 0.0, 1.0)
	_hp_bar.value = ratio * 100.0
	# 躺地（倒地/真死亡共用表现）时隐藏血条，避免"0 血站着"的误导；名牌保留。
	var dying: Variant = player.get("_is_dying")
	_hp_bar.visible = not (dying is bool and dying)
