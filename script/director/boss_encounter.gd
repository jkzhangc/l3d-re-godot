@tool
class_name BossEncounter extends Node2D

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node2D, @tool）
## 联机：仅单机/Host 生成；结果由 NetworkWorld 快照同步给 Client
## 职责：地图里可摆放的 Boss 遭遇触发器：玩家进入区域（或按键）即生成指定特感（Tank 等）。
## 依赖：Director.spawn_special_enemy、DirectorConfig（tank_* 参数）

## Boss 遭遇点 — 放在地图上，玩家进入触发区域时生成指定 Boss（タイラント T-002 等）。
##
## 与既有系统的关系：
##   · `DirectorConfig` 的 tank_* 参数 = **全局编排**（冷却/门槛/同屏上限），负责"什么时候自动刷"；
##   · 本组件 = **定点编排**，负责"在这一处、这一刻、刷这一只"，用于脚本化的必战遭遇
##     （原作：フィナーレでは必ず戦う = 定点必战；ステージ中 = 导演编排的可选遭遇）。
##   两者互不冲突：本组件生成的 Boss 也计入 tank_enemies 组，被全局同屏上限统计。
##
## @tool：编辑器里显示触发区域与 Boss 行走图预览，方便摆位；
## 游戏逻辑（玩家检测 / 生成）在编辑器里全部跳过。
##
## 联机：生成是 Host 权威（Director.spawn_special_enemy 在 Client 上直接 return），
## 因此本组件只在单机/Host 生效。

# ═══════════════════════════════════════
# 信号
# ═══════════════════════════════════════
signal encounter_triggered(encounter_name: String)
signal boss_defeated(encounter_name: String)

# ═══════════════════════════════════════
# 配置 — Boss
# ═══════════════════════════════════════
@export_group("Boss")
## 要生成的 Boss 资源（.tres）。留空 = 用 DirectorConfig.tank_data（或内置默认 T-002）。
@export var boss_data: SpecialEnemyData = null
## 生成位置相对本节点的偏移。ZERO = 在节点当前位置生成。
@export var spawn_offset: Vector2 = Vector2.ZERO
## 生成时的朝向：-1 = 自动面朝玩家，0~3 = 强制指定（下/左/右/上）。
@export_range(-1, 3, 1) var spawn_facing: int = -1
## 是否把生成的 Boss 计入全局 Tank 同屏限制（tank_enemies 组）。
## 关闭 = 这只 Boss 不受 tank_max_alive 限制（用于必战演出型遭遇）。
@export var count_toward_global_limit: bool = true

# ═══════════════════════════════════════
# 配置 — 触发
# ═══════════════════════════════════════
@export_group("触发")
## 遭遇标识（留空 = 用节点名），用于日志与信号。
@export var encounter_name: String = ""
## 触发方式：0=玩家进入区域自动触发（Area2D 检测）, 1=玩家靠近后按功能键, 2=只由外部脚本触发
@export_enum("进入区域自动触发", "靠近按键触发", "仅外部调用") var trigger_mode: int = 0
## 触发半径（像素）。区域模式下为圆形检测半径；按键模式下为交互距离。
@export_range(16.0, 2000.0, 8.0) var trigger_radius: float = 200.0:
	set(v):
		trigger_radius = clampf(v, 16.0, 2000.0)
		# 运行时改半径 → 同步检测区形状（编辑器里 shape 由 _ready 建，此时可能还不存在）
		_sync_detect_area_shape()
## 是否只触发一次。
@export var one_shot: bool = true
## 按键/靠近时的提示文字（留空 = 不显示提示）。
@export var hint_message: String = ""

# ═══════════════════════════════════════
# 配置 — 触发外观（调试）
# ═══════════════════════════════════════
@export_group("触发区域外观（调试）")
@export var show_debug_rect: bool = true
@export var debug_rect_color: Color = Color(0.9, 0.1, 0.1, 0.22)

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _triggered: bool = false
var _boss: Node2D = null
var _player_near: bool = false
var _hint_label: Label = null

# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	if encounter_name.is_empty():
		encounter_name = name if not name.is_empty() else "BossEncounter"
	_ensure_hint_label()
	if Engine.is_editor_hint():
		return
	# 外部调用模式不需要任何自动检测
	if trigger_mode == 2:
		return
	_ensure_detect_area()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if show_debug_rect:
			queue_redraw()
		return
	if _triggered and one_shot:
		queue_redraw()
		return

	# 按键模式：检测玩家是否在范围内
	if trigger_mode == 1:
		_player_near = _is_player_in_range()
		_update_hint_visibility()
		if Global.debug_visuals:
			queue_redraw()

	# Boss 存活监测 → 击败信号
	if _boss != null:
		if not is_instance_valid(_boss):
			_boss = null
			boss_defeated.emit(encounter_name)
			print("[BossEncounter] %s: Boss 已清除" % encounter_name)
		elif _boss.get("_is_dead") == true or _boss.get("_is_dying") == true:
			_boss = null
			boss_defeated.emit(encounter_name)
			print("[BossEncounter] %s: Boss 被击败" % encounter_name)


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if trigger_mode != 1:
		return
	if _triggered and one_shot:
		return
	if not _player_near:
		return
	if event.is_action_pressed("功能键"):
		# 收敛输入，防止菜单/其它交互被同一次按键连带触发
		get_viewport().set_input_as_handled()
		trigger()


func _draw() -> void:
	if not show_debug_rect:
		return
	var r: float = trigger_radius
	draw_circle(Vector2.ZERO, r, debug_rect_color)
	var edge: Color = Color(debug_rect_color.r, debug_rect_color.g, debug_rect_color.b, 0.85)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, edge, 2.0)
	# 触发状态：已触发画灰、待触发画红
	if _triggered:
		draw_arc(Vector2.ZERO, r * 0.9, 0.0, TAU, 32, Color(0.6, 0.6, 0.6, 0.6), 1.0)


# ═══════════════════════════════════════
# 触发
# ═══════════════════════════════════════

## 手动触发遭遇（外部脚本可随时调用，不受 one_shot 之外的限制）。
func trigger() -> void:
	if _triggered and one_shot:
		return
	if _is_network_client():
		return  ## 生成是 Host 权威

	_triggered = true
	var boss: Node2D = _spawn_boss()
	if boss == null:
		# 生成失败（无 Director / 无装饰层 / 无点位）→ 允许之后重试
		_triggered = false
		return
	_boss = boss
	# Boss BGM（2026-09-14）：与 _spawn_tank 同源——Director 监视存活，全灭自动收
	var director: Node = get_node_or_null("/root/Director")
	if director and director.has_method("play_boss_music"):
		director.play_boss_music(boss)
	_update_hint_visibility()
	queue_redraw()
	encounter_triggered.emit(encounter_name)


func is_triggered() -> bool:
	return _triggered


# ═══════════════════════════════════════
# 内部 — 生成
# ═══════════════════════════════════════

func _spawn_boss() -> Node2D:
	var director: Node = get_node_or_null("/root/Director")
	if director == null:
		printerr("[BossEncounter] Director autoload 未找到")
		return null
	if not director.has_method("spawn_special_enemy"):
		printerr("[BossEncounter] Director 没有 spawn_special_enemy 方法")
		return null

	var data: SpecialEnemyData = boss_data
	if data == null:
		# 回退到关卡配置的 tank_data，再回退到内置默认 T-002
		data = director.get("_tank_data") as SpecialEnemyData
	if data == null:
		data = load("res://tres/specials/タイラントT002.tres") as SpecialEnemyData
	if data == null:
		printerr("[BossEncounter] 无可用 Boss 数据")
		return null

	var decor: Node = _find_decor_layer()
	if decor == null:
		printerr("[BossEncounter] 未找到 DecorLayer")
		return null

	var pos: Vector2 = global_position + spawn_offset
	var facing: int = spawn_facing
	if facing < 0:
		facing = _calc_facing_toward_player(pos)

	var boss: Node2D = director.spawn_special_enemy(pos, data, decor, facing)
	if boss == null:
		return null
	if count_toward_global_limit:
		boss.add_to_group("tank_enemies")
	print("[BossEncounter] %s: Boss 登场 %s at (%d, %d)"
		% [encounter_name, String(data.id), int(pos.x), int(pos.y)])
	return boss


func _calc_facing_toward_player(from: Vector2) -> int:
	var p: Node2D = _find_player()
	if p == null:
		return 0
	var d: Vector2 = p.global_position - from
	if absf(d.x) > absf(d.y):
		return 2 if d.x > 0.0 else 1   # 右 / 左
	return 0 if d.y > 0.0 else 3       # 下 / 上


func _find_decor_layer() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	return _find_decor_recursive(tree.root)


func _find_decor_recursive(node: Node) -> Node:
	if not is_instance_valid(node):
		return null
	if "decor" in node.name.to_lower():
		return node
	for child: Node in node.get_children():
		var found: Node = _find_decor_recursive(child)
		if found:
			return found
	return null


func _find_player() -> Node2D:
	var players: Array[Node2D] = Players.all_entities()
	return players[0] if not players.is_empty() else null


func _is_player_in_range() -> bool:
	var p: Node2D = _find_player()
	if p == null:
		return false
	return p.global_position.distance_to(global_position) <= trigger_radius


func _is_network_client() -> bool:
	var net: Node = get_node_or_null("/root/Net")
	return net != null and net.get("is_client") == true


# ═══════════════════════════════════════
# 内部 — 子节点
# ═══════════════════════════════════════

## 进入区域模式：建一个圆形 Area2D 做体检测。
func _ensure_detect_area() -> void:
	var area: Area2D = get_node_or_null("DetectArea") as Area2D
	if area == null:
		area = Area2D.new()
		area.name = "DetectArea"
		add_child(area)
	var shape: CollisionShape2D = area.get_node_or_null("Shape") as CollisionShape2D
	if shape == null:
		shape = CollisionShape2D.new()
		shape.name = "Shape"
		area.add_child(shape)
	shape.shape = CircleShape2D.new()
	_sync_detect_area_shape()
	if not area.body_entered.is_connected(_on_body_entered):
		area.body_entered.connect(_on_body_entered)


## 把 trigger_radius 同步到检测区形状。半径的 setter 会在 _ready 之前被
## 资源注入调用，那时 Shape 还不存在 —— 所以这里必须容忍缺失并静默返回。
func _sync_detect_area_shape() -> void:
	var shape: CollisionShape2D = get_node_or_null("DetectArea/Shape") as CollisionShape2D
	if shape == null or not (shape.shape is CircleShape2D):
		return
	(shape.shape as CircleShape2D).radius = trigger_radius


func _on_body_entered(body: Node2D) -> void:
	if Engine.is_editor_hint():
		return
	if _triggered and one_shot:
		return
	if not body is CharacterBody2D:
		return
	if not body.has_method("get_weapon_data"):
		return  ## 只认玩家（与 EventTrigger 同一判据）
	trigger()


func _ensure_hint_label() -> void:
	if _hint_label != null and is_instance_valid(_hint_label):
		return
	_hint_label = get_node_or_null("HintLabel") as Label
	if _hint_label == null:
		_hint_label = Label.new()
		_hint_label.name = "HintLabel"
		_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hint_label.position = Vector2(-80, -40)
		_hint_label.size = Vector2(160, 20)
		_hint_label.modulate = Color(1, 1, 1, 0.85)
		add_child(_hint_label)
		var g: Node = get_node_or_null("/root/Global")
		if g:
			g.apply_hint_font(_hint_label, 12)  ## 字体统一（2026-09-17）：fusion-pixel + 12 整倍
			if g.has_method("apply_text_shadow"):
				g.apply_text_shadow(_hint_label)
	_hint_label.text = hint_message if not hint_message.is_empty() else encounter_name
	_hint_label.visible = trigger_mode != 2 and not hint_message.is_empty()


func _update_hint_visibility() -> void:
	if _hint_label == null or not is_instance_valid(_hint_label):
		return
	if hint_message.is_empty():
		_hint_label.visible = false
		return
	# 按键模式：只在玩家靠近且未触发时显示
	_hint_label.visible = _player_near and not (_triggered and one_shot)
