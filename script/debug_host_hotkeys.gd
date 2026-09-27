extends Node

## ── 架构定位 ──
## 系统：调试工具 ｜ 层：单例挂载（由 Global 在 _ready 里动态创建，不落场景文件）
## 联机：**仅 Host / 单机**触发；Client 按键只打印提示，不产生任何权威变更
## 职责：主机调试热键 —— Ctrl+R 把其他玩家瞬移到主机身边；Ctrl+H 全体满血 + 复活倒地/死亡玩家。
## 依赖：NetworkWorld（权威结算）、Players（单机兜底）、Net（会话状态）
##
## 【用法】游戏运行中（仅主机 / 单机）：
##   Ctrl+R → 其他玩家全部瞬移到我身边（绕我排开，自动避开物理层碰撞）
##   Ctrl+H → 全体玩家满血 + 复活倒地与真死亡的玩家
##
## 【为什么权威结算放在 NetworkWorld】玩家坐标与生死是 Host 权威数据，
## 调试键只是"触发口"。Client 侧不自己改 —— 位置与 HP 都由 Host 的常规快照回灌
## （玩家 60Hz），所以除了瞬移需要一次"硬吸附"外，不需要额外的表现广播。

const GATHER_KEY: int = KEY_R
const HEAL_KEY: int = KEY_H

## ── 调试用「跳转章节」按钮（2026-09-27 用户需求）──
## 多人模式下**仅主机**画面左下角出现一个按钮，点开可在战役关卡之间直接跳转
## （走 Net.request_scene_change → Host 的 start_game 握手把全部端一起带过去），
## 省掉"每次都从头跑到要测的那一关"。章节表来自 CampaignData.collect_chapter_entries()。
var _jump_layer: CanvasLayer = null
var _jump_btn: Button = null
var _jump_panel: PanelContainer = null


func _ready() -> void:
	set_process(true)
	print("[DebugHotkey] 就绪 —— Ctrl+R 集结队友 / Ctrl+H 全体满血+复活（仅主机 / 单机）")
	print("[DebugHotkey] 就绪 —— 多人主机左下角有「跳转章节」按钮（调试用）")


## 每帧只做两件廉价的事：判断该不该显示按钮、同步按钮可见性（UI 懒创建）。
func _process(_delta: float) -> void:
	var show_jump: bool = _can_jump()
	if show_jump:
		_ensure_jump_ui()
	if _jump_btn != null and is_instance_valid(_jump_btn):
		_jump_btn.visible = show_jump
		if not show_jump and _jump_panel != null and is_instance_valid(_jump_panel):
			_jump_panel.visible = false


## 只有「在游戏里 + 联机会话 + 我是主机」才给这个入口（用户要求：多人模式下主机）。
func _can_jump() -> bool:
	return _in_game() and _online() and _is_host()


func _ensure_jump_ui() -> void:
	if _jump_layer != null and is_instance_valid(_jump_layer):
		return
	_jump_layer = CanvasLayer.new()
	_jump_layer.name = "DebugChapterJump"
	## 层 85：在游戏世界之上、黑幕(90)/结算页(100) 之下 —— 过场时会被黑幕正常盖住。
	_jump_layer.layer = 85
	add_child(_jump_layer)

	var root: Control = Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 别挡住游戏输入
	_jump_layer.add_child(root)

	_jump_btn = Button.new()
	_jump_btn.name = "JumpBtn"
	_jump_btn.text = "跳转章节"
	_jump_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_jump_btn.offset_left = 12.0
	_jump_btn.offset_top = -44.0
	_jump_btn.offset_right = 132.0
	_jump_btn.offset_bottom = -12.0
	_apply_debug_font(_jump_btn)
	_jump_btn.pressed.connect(_toggle_jump_panel)
	root.add_child(_jump_btn)

	_jump_panel = PanelContainer.new()
	_jump_panel.name = "JumpPanel"
	_jump_panel.visible = false
	_jump_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_jump_panel.offset_left = 12.0
	_jump_panel.offset_top = -520.0
	_jump_panel.offset_right = 420.0
	_jump_panel.offset_bottom = -52.0
	root.add_child(_jump_panel)

	## 关卡列表可能很长（要能跳到全部地图）→ 套一层滚动容器。
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_jump_panel.add_child(scroll)

	var box: VBoxContainer = VBoxContainer.new()
	box.name = "List"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	scroll.add_child(box)

	var title: Label = Label.new()
	title.text = "跳转关卡（调试 · 仅主机）"
	_apply_debug_font(title)
	box.add_child(title)

	## ★用「全部可跳转关卡」而不是战役表：战役表 `level_scenes` 只登记了 5 关
	##（第一关 3 张 + 第二关 2 张），而 `scene/maps/` 下有 12 张 —— 矿洞 / 实验室走廊 /
	## 列车台 / 各安全屋 / 测试图都没登记。调试要的是"想跳哪张就跳哪张"。
	for entry: Dictionary in CampaignData.collect_all_level_entries():
		var btn: Button = Button.new()
		btn.text = str(entry.get("label", "?"))
		_apply_debug_font(btn)
		var scene_path: String = str(entry.get("scene", ""))
		btn.pressed.connect(func(): _jump_to_chapter(scene_path))
		box.add_child(btn)

	var close_btn: Button = Button.new()
	close_btn.text = "关闭"
	_apply_debug_font(close_btn)
	close_btn.pressed.connect(func(): _jump_panel.visible = false)
	box.add_child(close_btn)


## 调试 UI 字体也走全局唯一入口（项目铁律：禁硬编码 .ttf / 字号取 12 的整倍）。
func _apply_debug_font(ctrl: Control) -> void:
	var g: Node = get_node_or_null("/root/Global")
	var font: Font = null
	if g and g.has_method("get_ui_font"):
		font = g.get_ui_font()
	if font != null:
		ctrl.add_theme_font_override("font", font)
	ctrl.add_theme_font_size_override("font_size", 12)


func _toggle_jump_panel() -> void:
	if _jump_panel != null and is_instance_valid(_jump_panel):
		_jump_panel.visible = not _jump_panel.visible


func _jump_to_chapter(scene_path: String) -> void:
	if scene_path.is_empty() or not _can_jump():
		return
	var net: Node = _net()
	if net == null or not net.has_method("request_scene_change"):
		return
	net.call("request_scene_change", scene_path)
	print("[DebugHotkey] 跳转章节: %s" % scene_path)
	if _jump_panel != null and is_instance_valid(_jump_panel):
		_jump_panel.visible = false



func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo or not key.ctrl_pressed:
		return
	var code: int = key.physical_keycode
	if code == 0:
		code = key.keycode
	if code == GATHER_KEY:
		_gather()
	elif code == HEAL_KEY:
		_heal_all()


# ═══════════════════════════════════════
# 取环境
# ═══════════════════════════════════════

func _net() -> Node:
	return get_node_or_null("/root/Net")


func _world() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene.get_node_or_null("NetworkWorld")


## 只在地图里生效：标题/菜单/结算页没有玩家实体，直接忽略，避免误触。
func _in_game() -> bool:
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	for node: Node in tree.get_nodes_in_group("player"):
		if node is Node2D and (node as Node2D).is_inside_tree():
			return true
	return false


func _online() -> bool:
	var net: Node = _net()
	return net != null and bool(net.call("is_online_session"))


func _is_host() -> bool:
	var net: Node = _net()
	if net == null:
		return false
	return bool(net.get("is_host"))


## 非主机（联机客户端）一律不执行 —— 打印提示便于现场确认按键被收到了。
func _rejected_offline_host(tag: String) -> bool:
	if _online() and not _is_host():
		print("[DebugHotkey] %s 仅主机可用（客户端不改权威状态）" % tag)
		return true
	return false


# ═══════════════════════════════════════
# Ctrl+R：把其他玩家瞬移到主机身边
# ═══════════════════════════════════════

func _gather() -> void:
	if not _in_game() or _rejected_offline_host("Ctrl+R 集结"):
		return
	var world: Node = _world()
	if world == null:
		print("[DebugHotkey] Ctrl+R：单机模式没有其他玩家，忽略")
		return
	var moved: int = int(world.call("debug_gather_players_to_host"))
	if moved <= 0:
		print("[DebugHotkey] Ctrl+R：没有可瞬移的队友")


# ═══════════════════════════════════════
# Ctrl+H：全体满血 + 复活
# ═══════════════════════════════════════

func _heal_all() -> void:
	if not _in_game() or _rejected_offline_host("Ctrl+H 全体治疗"):
		return
	if _online():
		var world: Node = _world()
		if world != null:
			world.call("debug_heal_all_players")
			return
	_heal_all_solo()


## 单机：全队座位回满（与医疗箱单机口径一致）。
## 单机的"倒地/真死"走的是黑屏重载流程，这里**不介入**那条链（只把 HP 填满），
## 避免调试键与正式死亡流程互相打架。
func _heal_all_solo() -> void:
	var players: Node = get_node_or_null("/root/Players")
	if players == null:
		return
	for state: PlayerState in players.get("seats"):
		if state != null:
			state.current_hp = state.get_max_hp()
	var healed: int = 0
	for entity: Node2D in players.call("all_entities", false):
		if not is_instance_valid(entity):
			continue
		var state: PlayerState = players.call("get_state_for_entity", entity) as PlayerState
		if state != null and entity.get("_is_dying") != true:
			entity.set("current_hp", state.current_hp)
			healed += 1
	print("[DebugHotkey] Ctrl+H 单机：%d 名角色回满 HP" % healed)
