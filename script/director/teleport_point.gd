@tool
class_name TeleportPoint extends Node2D

## ── 架构定位 ──
## 系统：关卡流程 ｜ 层：玩法（Node2D, @tool）
## 联机：单机直达；联机走安全门协议
## 职责：传送点：靠近按交互键切到目标场景/到达点，隐藏状态下不触发。
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

@export_group("交互")
@export var interact_label: String = "前往"         ## 交互提示文字
@export var interact_range: float = 48.0           ## 交互触发距离（像素）

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
var _can_interact: bool = false
var _transitioning: bool = false   ## 传送已发起（防同帧/切图空窗期重复触发）
var _player_search_cd: float = 0.0 ## 玩家缺席时的降频重扫倒计时

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


## 编辑器预览（@tool）：只构建显示节点并刷出行走图，不碰任何游戏逻辑 / autoload。
## 子节点不设 owner → 不会被打进 .tscn。
func _editor_preview() -> void:
	if step_frames.is_empty():
		step_frames = [1]
	_step_index = 0
	_ensure_children()
	_refresh_sprite()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		## 编辑器里也播放踏步动画，摆点时即可确认动效
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

	# 静态行走图同样需要持续检测玩家是否在范围内。
	_check_player_proximity()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	# 隐藏中的传送点（如防守战结束前由 HoldoutMachine 生成并设为 start_hidden 的传送点）
	# 即便玩家在范围内按下确定键也不会传送，直到它被显式设为可见。
	if not is_visible_in_tree():
		return
	if _transitioning or not _can_interact:
		return
	if event.is_action_pressed("确定键"):
		## 与 safe_door 一致走 _unhandled_input 并标记已处理：
		## 菜单等 UI 先消费按键，不会隔着菜单误触发传送。
		get_viewport().set_input_as_handled()
		_do_teleport()


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
		var hg: Node = get_node_or_null("/root/Global")
		if hg:
			hg.apply_hint_font(label, 12)
		label.size = Vector2(100, 24)
		label.modulate = Color(1, 1, 1, 0.9)
		label.hide()
		add_child(label)

	## 阴影统一走全局参数；运行时路径（编辑器分支不执行，编辑器进程没有 autoload）
	var g: Node = get_node_or_null("/root/Global")
	if g:
		g.apply_text_shadow(label)


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
	var dir_row: int = walk_direction

	var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir_row * FRAME_H
	s.region_rect = Rect2(x, y, FRAME_W, FRAME_H)


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
