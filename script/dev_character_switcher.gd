class_name DevCharacterSwitcher extends Node2D

## ── 架构定位 ──
## 系统：开发工具 ｜ 层：测试（Node2D）
## 联机：仅单机测试用（不入联机流程）
## 职责：测试图「角色切换点」—— 玩家靠近时按 1~N 直接换成角色目录第 N 个角色，
##       供实机测试不同角色持武器的子弹偏移（WeaponData.bullet_spawn_offsets）。
## 依赖：CharacterCatalog（角色清单，与角色选择界面同源）、Players、player.refresh_after_switch()
##
## 使用（2026-09-17 用户需求）：
##   1. 本节点放在测试地图 DecorLayer 下任意位置。
##   2. 玩家走进 trigger_radius 后按数字键 1~9 → 换成角色目录第 N 个角色。
##   3. 换人 = 直接改当前座位的 PlayerState.character + refresh_after_switch()，
##      装备/弹药/位置全部保留（只是换人，不是回出生点）。
##   4. 与 CharacterSwitchManager 的 Ctrl+1~3 不冲突：试验场单人 team=1，那套不启用。

const FONT_PATH := "res://art/System/fusion-pixel-12px-monospaced-zh_hans.ttf"

## 触发半径（px）：玩家距本点小于此值才能按键换人
@export var trigger_radius: float = 120.0
## 提示文字相对本点的 y 偏移
@export var hint_y_offset: float = -28.0

var _player: CharacterBody2D = null
var _near: bool = false
var _hint: Label = null
var _characters: Array[CharacterData] = []


func _ready() -> void:
	z_index = 10  # 世界内悬浮提示一律显式抬 z（单位(1)/UpperLayer(0) 之上，黑幕 90 之下）
	_characters = CharacterCatalog.load_available_characters()
	queue_redraw()


func _process(_delta: float) -> void:
	var near := _is_player_near()
	if near == _near:
		return
	_near = near
	if near:
		_ensure_hint()
	if _hint:
		_hint.visible = near
	queue_redraw()


func _is_player_near() -> bool:
	if not _player:
		_player = Players.get_local_entity() as CharacterBody2D
	if not _player:
		return false
	return _player.global_position.distance_to(global_position) <= trigger_radius


func _unhandled_input(event: InputEvent) -> void:
	if not _near:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	# 小键盘 KEY_KP_1~9 不接：测试场景默认走主键区数字
	var idx: int = -1
	match key.keycode:
		KEY_1: idx = 0
		KEY_2: idx = 1
		KEY_3: idx = 2
		KEY_4: idx = 3
		KEY_5: idx = 4
		KEY_6: idx = 5
		KEY_7: idx = 6
		KEY_8: idx = 7
		KEY_9: idx = 8
	if idx >= 0:
		_switch_to(idx)


func _switch_to(index: int) -> void:
	if index >= _characters.size():
		print("[DevSwitch] 角色目录只有 %d 个，没有第 %d 个" % [_characters.size(), index + 1])
		return
	var cd: CharacterData = _characters[index]
	var player := Players.get_local_entity()
	var st := Players.get_active_state()
	if player == null or st == null:
		print("[DevSwitch] 找不到本地玩家或座位状态，无法切换")
		return
	# 与 network_world 同一赋值约定：character + character_path 成对写
	st.character = cd
	st.character_path = cd.resource_path
	player.refresh_after_switch()
	print("[DevSwitch] 已切换 → %s（%s）" % [cd.character_name, cd.resource_path])


# ═══════════════════════════════════════
# 视觉：触发圈 + 提示文字
# ═══════════════════════════════════════

func _draw() -> void:
	var ring: Color = Color(0.45, 0.9, 1.0, 0.5) if _near else Color(0.45, 0.9, 1.0, 0.2)
	var dot: Color = Color(0.45, 0.9, 1.0, 0.95) if _near else Color(0.45, 0.9, 1.0, 0.55)
	draw_arc(Vector2.ZERO, trigger_radius, 0.0, TAU, 48, ring, 2.0)
	draw_circle(Vector2.ZERO, 5.0, dot)


func _ensure_hint() -> void:
	if _hint and is_instance_valid(_hint):
		_update_hint_text()
		return
	_hint = Label.new()
	var settings := LabelSettings.new()
	## 字体跟随「设置 → 界面字体」（2026-09-24，12px 基底，12 整倍）
	settings.font = Global.get_ui_font() if Global.has_method("get_ui_font") else load(FONT_PATH)
	settings.font_size = 12  # fusion-pixel 12 基底，12 整倍
	settings.font_color = Color(1, 1, 1, 0.95)
	settings.shadow_color = Color(0, 0, 0, 0.7)
	settings.shadow_offset = Vector2(1, 1)
	_hint.label_settings = settings
	_hint.z_index = 10
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 动态居中不用帧等待（GradientLabel 教训）：resized 信号回调重算
	_hint.resized.connect(_recenter_hint)
	add_child(_hint)
	_update_hint_text()


func _update_hint_text() -> void:
	var names: Array[String] = []
	for i: int in range(_characters.size()):
		names.append("%d:%s" % [i + 1, _characters[i].character_name])
	_hint.text = "角色切换点\n" + "  ".join(names)


func _recenter_hint() -> void:
	if _hint:
		_hint.position = Vector2(-_hint.size.x / 2.0, hint_y_offset)
