@tool
class_name ItemPickupPoint extends Node2D

## ── 架构定位 ──
## 系统：剧情机关 ｜ 层：玩法（Node2D, @tool）
## 联机：Client 只提交请求；Host 校验后代为结算（NetworkWorld.request_quest_pickup）
## 职责：关键道具拾取点 —— 「获得提示 + 全局 flag」路线的入参节点：拾取后置 flag、
##       可选发放投掷物（炸药 ×N，同类自动叠加）、播获得提示。
## 依赖：Global（quest flag）、PlayerState.grant_throwable、NetworkWorld（联机）
##
## @tool：编辑器里实时显示行走图（同 teleport_point 预览做法）。遵守 @tool 铁律：
##   ① @tool 第 1 行；② 编辑器分支绝不碰 autoload 与游戏逻辑；③ 预览子节点不设 owner。

## 关键道具拾取点 — 炸药/钥匙等流程道具的地面拾取点
##
## 典型用法（突袭第三章）：
##   · 炸药补给点：grant_throwable=炸药, grant_count=15, pickup_flag="ch3_dynamite_taken_1"
##   · 保底补给点（防软锁）：同上 + activate_when_out_of_explosives=true +
##     activate_gate_flag="ch3_wall_mine_broken" —— 平时隐身；只有全队炸药手雷归零
##     且目标墙未炸开时才出现；墙炸开后永久消失。
##   · 钥匙：不用本节点 —— 钥匙走「开门 = 传送点 required_flag」链路时，
##     钥匙本身也用本节点发放（pickup_flag="ch3_got_key"），grant_throwable 留空。

# ═══════════════════════════════════════
# 精灵帧常量（VX Ace 行走图，同 teleport_point）
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
@export_group("拾取内容")
@export var pickup_flag: String = ""  ## 拾取后置的 flag 名（全图唯一，如 "ch3_dynamite_taken_1"）；空则不可持久化
@export var grant_throwable: ThrowableData:
	set(v):
		grant_throwable = v
		## 无行走图时预览回退显示道具图标，换道具也要即时刷（同 walk_texture setter）
		_refresh_sprite()  ## 要发放的投掷物（炸药等）；留空 = 只置 flag（钥匙类）
@export_range(1, 99, 1) var grant_count: int = 15  ## 发放数量（同类投掷物叠加；普通投掷物给 1）
@export var pickup_hint: String = "获得了炸药 ×15。"  ## 获得提示（HUD 文字，会标明数量）

@export_group("显示条件")
@export var activate_gate_flag: String = ""  ## 反向门条件：该 flag 为 true 时本点永久隐藏（如关联的 wall_flag）
@export var activate_when_out_of_explosives: bool = false  ## true = 平时隐藏，仅当全队无爆炸投掷物且 activate_gate_flag 未置时激活（保底补给点，投掷物方案）
@export var activate_when_missing_flag: String = ""  ## 该 flag 为 true 时隐藏、false 时显示（关键物品方案保底点：填关键道具 flag，放置消耗后保底点现身）

@export_group("交互")
@export var interact_label: String = "拾取"  ## 靠近提示（前缀，自动拼 [确定]）
@export_range(16.0, 512.0, 1.0) var interact_range: float = 48.0
@export var pickup_sound: AudioStream  ## 拾取音效（留空 = Global.default_pickup_sfx_path 全局默认音）
@export_range(0.0, 4.0, 0.1) var pickup_sound_pitch: float = 1.0  ## 拾取音效音调（<=0 = 原调）

@export_group("外观（VX 行走图）")
## walk_* 三个导出带 setter：Inspector 里改贴图/索引/朝向即时刷预览，无需重开场景
## （同 GradientLabel font_path_override 的 2026-09-14 修法；加载期 sprite 未建时刷新自动早退）。
@export var walk_texture: Texture2D:
	set(v):
		walk_texture = v
		_refresh_sprite()
@export_range(0, 31, 1) var walk_char_index: int = 0:
	set(v):
		walk_char_index = v
		_refresh_sprite()
@export_range(0, 3, 1) var walk_direction: int = 0:
	set(v):
		walk_direction = v
		_refresh_sprite()
@export_group("踏步动画")
@export var step_frames: Array[int] = [1, 0, 1, 2]
@export var step_duration: float = 0.25
@export var animated: bool = true

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _taken: bool = false          ## 已被拾取（本地视角；联机 Client 等 flag 回包确认）
var _committing: bool = false     ## 请求已提交（Client 防重复提交）
var _committing_timeout: float = 0.0  ## Client 提交锁超时（Host 拒绝时可重试）
var _toast_timer: float = 0.0     ## 获得提示残留显示时间
var _step_index: int = 0
var _step_timer: float = 0.0
var _can_interact: bool = false
var _player_ref: CharacterBody2D = null


func _ready() -> void:
	if Engine.is_editor_hint():
		_editor_preview()
		return
	if pickup_flag.is_empty():
		printerr("[ItemPickupPoint] %s 未配置 pickup_flag，拾取进度不会被记录！" % name)
	_ensure_children()
	_refresh_sprite()
	if animated:
		_step_timer = step_duration
	Global.quest_flag_changed.connect(_on_quest_flag_changed)
	# flag 已置（存档恢复 / 联机同步 / 死亡回安全屋）→ 启动即隐藏
	if not pickup_flag.is_empty() and Global.has_quest_flag(pickup_flag):
		_taken = true
		visible = false


func _exit_tree() -> void:
	## @tool 铁律：编辑器分支绝不碰 autoload（编辑器里 Global 不在树上，
	## 直接访问其成员会在切场景时报 Invalid access to 'quest_flag_changed'）
	if Engine.is_editor_hint():
		return
	var g: Node = get_node_or_null("/root/Global")
	if g and g.quest_flag_changed.is_connected(_on_quest_flag_changed):
		g.quest_flag_changed.disconnect(_on_quest_flag_changed)


## 编辑器预览（@tool）：只构建显示节点并刷出行走图，不碰 autoload / 游戏逻辑。
func _editor_preview() -> void:
	if step_frames.is_empty():
		step_frames = [1]
	_step_index = 0
	_ensure_children()
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

	if _taken:
		if _toast_timer > 0.0:
			## 拾取后：精灵已隐藏，获得提示残留显示一小段时间
			_toast_timer -= delta
			if _toast_timer <= 0.0:
				visible = false
		return

	# Client 提交锁超时复位（Host 拒绝/丢包时可重新提交）
	if _committing:
		_committing_timeout -= delta
		if _committing_timeout <= 0.0:
			_committing = false

	# 踏步动画
	if animated:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer += maxf(step_duration, 0.02)
			_step_index = (_step_index + 1) % step_frames.size()
			_refresh_sprite()

	_update_active_state()
	if not visible or not is_visible_in_tree():
		return

	# 玩家接近检测
	var players: Node = get_node_or_null("/root/Players")
	var player: CharacterBody2D = players.nearest_entity_to(global_position) if players and players.has_method("nearest_entity_to") else null
	_player_ref = player
	_can_interact = is_instance_valid(player) and global_position.distance_to(player.global_position) <= interact_range
	_update_label()


## 显示条件总判定：拿过 / 门条件关闭 / 保底点不需要补给 → 隐藏
func _update_active_state() -> void:
	if _taken:
		return
	var hidden: bool = false
	if not activate_gate_flag.is_empty() and Global.has_quest_flag(activate_gate_flag):
		hidden = true
	if not hidden and activate_when_out_of_explosives and Global.team_has_explosive_throwable():
		hidden = true
	visible = not hidden


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or _taken or _committing:
		return
	if not is_visible_in_tree() or not _can_interact:
		return
	if event.is_action_pressed("确定键"):
		## 与 safe_door/teleport_point 一致：UI 先消费按键，不隔着菜单误触发
		get_viewport().set_input_as_handled()
		_request_pickup()


# ═══════════════════════════════════════
# 拾取事务
# ═══════════════════════════════════════

func _request_pickup() -> void:
	var state := _state_of(_player_ref)
	if state == null:
		return
	var scene := get_tree().current_scene
	var world := scene.find_child("NetworkWorld", true, false) if scene else null
	if world and world.has_method("request_quest_pickup"):
		## 联机：Host 立即结算；Client 提交请求等 flag 回包（_on_quest_flag_changed 复位锁）
		_committing = true
		_committing_timeout = 2.0
		world.call("request_quest_pickup", scene.get_path_to(self))
		return
	# 单机（无 NetworkWorld）：直接结算
	host_commit_pickup(state)


## Host 权威提交点（单机直调 / NetworkWorld._try_host_quest_pickup 调用）。
## 结算：置 flag（广播）→ 发放投掷物 → 表现。
func host_commit_pickup(state: PlayerState) -> void:
	if _taken:
		return
	_taken = true
	if not pickup_flag.is_empty():
		Global.request_quest_flag(pickup_flag, true)
	if grant_throwable and state:
		state.grant_throwable(grant_throwable, grant_count)
		print("[拾取] %s 获得 %s ×%d" % [state.character.character_name if state.character else "?", grant_throwable.item_name, grant_count])
	# 表现：精灵消失，获得提示残留约 2.5 秒
	## 拾取音效：留空 = 全局默认音（Global.play_pickup_sfx 统一回退）；pitch <=0 = 原调
	Global.play_pickup_sfx(pickup_sound, pickup_sound_pitch)
	var sprite: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if sprite:
		sprite.visible = false
	_toast_timer = 2.5
	var label: Label = get_node_or_null("HintLabel") as Label
	if label:
		label.text = pickup_hint
		label.show()
	_can_interact = false


func _on_quest_flag_changed(flag_name: String, value: bool) -> void:
	## 联机 Client 收到 Host 广播 → 复位提交锁并隐藏
	if not pickup_flag.is_empty() and flag_name == pickup_flag and value:
		_committing = false
		if not _taken:
			host_commit_pickup(null)  # Client 本地无库存写入（库存随 Host 快照走），只做表现


# ═══════════════════════════════════════
# 子节点 / 显示
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
		## 字体统一（2026-09-17）：fusion-pixel + 12 整倍；编辑器进程无 autoload，判空再套。
		var hg: Node = get_node_or_null("/root/Global")
		if hg:
			hg.apply_hint_font(label, 12)
		label.position = Vector2(-80, -56)
		label.size = Vector2(160, 24)
		label.modulate = Color(1, 1, 1, 0.9)
		label.hide()
		add_child(label)
	## 阴影统一走全局参数；编辑器分支不执行（编辑器进程没有 autoload）
	var g: Node = get_node_or_null("/root/Global")
	if g:
		g.apply_text_shadow(label)


func _refresh_sprite() -> void:
	var s: Sprite2D = get_node_or_null("Sprite2D") as Sprite2D
	if not s:
		return
	# 没配行走图 → 回退显示道具图标整图（对齐 healing_pickup 的回退规则）
	if not walk_texture:
		s.region_enabled = false
		s.texture = grant_throwable.icon if grant_throwable else null
		return
	s.texture = walk_texture
	s.region_enabled = true
	var frame: int = clampi(step_frames[_step_index], 0, 2) if _step_index < step_frames.size() else 0
	var char_col: int = walk_char_index % CHARS_PER_ROW
	var char_row: int = walk_char_index / CHARS_PER_ROW
	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + walk_direction * FRAME_H
	s.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


func _update_label() -> void:
	var label: Label = get_node_or_null("HintLabel") as Label
	if not label:
		return
	if _can_interact:
		label.text = "%s [确定]" % interact_label
		label.show()
	else:
		label.hide()


func _state_of(player: CharacterBody2D) -> PlayerState:
	if not is_instance_valid(player):
		return null
	var players: Node = get_node_or_null("/root/Players")
	if players and players.has_method("get_state_for_entity"):
		return players.get_state_for_entity(player)
	return null
